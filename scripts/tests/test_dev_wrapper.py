import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


WRAPPER = Path(__file__).resolve().parents[2] / ".agents" / "dev"


class DevWrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.main = self.root / "main checkout"
        self.workspace = self.root / "secondary workspace"
        self.home = self.root / "home"
        self.nix = self.home / ".nix-profile" / "bin" / "nix"
        self.nix.parent.mkdir(parents=True)
        self.nix.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "print(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd()}))\n"
        )
        self.nix.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home))
        for checkout in (self.main, self.workspace):
            (checkout / ".agents").mkdir(parents=True)
            shutil.copy2(WRAPPER, checkout / ".agents" / "dev")
            for name in ("flake.nix", "flake.lock", "Cargo.toml"):
                (checkout / name).write_text(name)
        (self.main / ".git").mkdir()
        (self.main / ".jj" / "repo").mkdir(parents=True)
        (self.workspace / ".jj").mkdir()
        (self.workspace / ".jj" / "repo").write_text(
            "../../main checkout/.jj/repo"
        )

    def run_wrapper(self, checkout):
        return subprocess.run(
            ["bash", str(checkout / ".agents" / "dev"), "printf", "%s", "a b"],
            cwd=self.workspace,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def assert_safe_invocation(self, checkout):
        result = self.run_wrapper(checkout)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["cwd"], str(self.workspace))
        self.assertEqual(
            data["args"],
            ["--extra-experimental-features", "nix-command flakes", "develop",
             f"git+file://{self.main}", "--command", "printf", "%s", "a b"],
        )

    def test_main_uses_explicit_git_input_and_preserves_cwd_arguments(self):
        self.assert_safe_invocation(self.main)

    def test_secondary_uses_main_not_build_output_tree(self):
        (self.workspace / "target").mkdir()
        (self.workspace / "target" / "must-not-be-a-flake-input").touch()
        self.assert_safe_invocation(self.workspace)

    def test_absolute_jj_repo_pointer(self):
        (self.workspace / ".jj" / "repo").write_text(str(self.main / ".jj" / "repo"))
        self.assert_safe_invocation(self.workspace)

    def test_input_drift_fails_before_nix(self):
        for name in ("flake.nix", "flake.lock", "Cargo.toml"):
            with self.subTest(name=name):
                path = self.workspace / name
                path.write_text("different")
                result = self.run_wrapper(self.workspace)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn(f"{name} differs", result.stderr)
                path.write_text(name)

    def test_plain_directory_fails_before_nix(self):
        (self.workspace / ".jj" / "repo").unlink()
        result = self.run_wrapper(self.workspace)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Refusing an unfiltered", result.stderr)

    def test_system_nix_fallback(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.nix.rename(bin_dir / "nix")
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        self.assert_safe_invocation(self.workspace)
