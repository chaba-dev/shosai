import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SETUP = Path(__file__).resolve().parents[2] / ".agents/setup"
BEGIN = "# BEGIN shosai Nix development shell"
END = "# END shosai Nix development shell"


class OrbSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.repo = self.root / "repo"
        self.tools = self.root / "tools"
        for directory in (self.home, self.repo / ".agents", self.tools,
                          self.repo / ".jj"):
            directory.mkdir(parents=True)
        shutil.copy2(SETUP, self.repo / ".agents/setup")
        self.profile = self.home / ".bash_profile"
        nix_profile = self.home / ".nix-profile"
        (nix_profile / "etc/profile.d").mkdir(parents=True)
        (nix_profile / "etc/profile.d/nix.sh").write_text("")
        self.executable(nix_profile / "bin/nix", "exit 0")
        self.executable(self.tools / "tailscale", "echo 1.102.2")
        # Do not touch host services or network configuration in this test.
        self.executable(self.tools / "sudo", "cat >/dev/null")
        self.executable(self.repo / ".agents/tailscale-connect", "exit 0")
        self.executable(self.repo / ".agents/dev", '''
printf '%s\\n' "$*" >> "$HOME/setup-calls"
case "$*" in
  'jj git colocation status') echo 'currently colocated' ;;
  'jj config get user.name') echo 'Test User' ;;
  'jj config get user.email') echo 'test@example.invalid' ;;
esac
''')
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.tools}{os.pathsep}{os.environ['PATH']}")

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/bash\nset -eu\n{body}\n")
        path.chmod(0o755)

    def run_setup(self):
        return subprocess.run(
            ["bash", str(self.repo / ".agents/setup")], cwd=self.repo,
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def assert_setup_succeeds(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("flutter pub get --enforce-lockfile",
                      (self.home / "setup-calls").read_text())
        text = self.profile.read_text()
        self.assertEqual(text.count(BEGIN), 1)
        self.assertEqual(text.count(END), 1)
        self.assertIn(str(self.repo), text)
        self.assertEqual(subprocess.run(
            ["bash", "-n", str(self.profile)], capture_output=True,
        ).returncode, 0)

    def test_missing_profile_is_created_and_repeat_setup_succeeds(self):
        self.assertFalse(self.profile.exists())
        self.assert_setup_succeeds()
        self.assert_setup_succeeds()

    def test_existing_profile_content_survives_block_replacement(self):
        self.profile.write_text(
            f"export BEFORE=keep\n{BEGIN}\nstale configuration\n{END}\n"
            "export AFTER=keep\n"
        )
        self.assert_setup_succeeds()
        self.assert_setup_succeeds()
        text = self.profile.read_text()
        self.assertIn("export BEFORE=keep\n", text)
        self.assertIn("export AFTER=keep\n", text)
        self.assertNotIn("stale configuration", text)

    def test_legacy_block_is_refused_without_modifying_profile(self):
        original = "# shosai Nix development shell\nlegacy content\n"
        self.profile.write_text(original)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Remove the legacy", result.stderr)
        self.assertEqual(self.profile.read_text(), original)
