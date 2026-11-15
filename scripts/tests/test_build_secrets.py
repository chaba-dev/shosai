import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "with-build-secrets.sh"


class BuildSecretsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository with spaces"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "secrets").mkdir()
        shutil.copy2(HELPER, self.root / "scripts" / HELPER.name)
        self.config = self.root / "user config"
        self.keys = self.config / "sops" / "age" / "shosai"
        self.keys.mkdir(parents=True)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("SOPS_")}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.config))
        for environment in ("development", "release"):
            key = self.keys / f"{environment}.txt"
            subprocess.run(["age-keygen", "-o", str(key)], check=True,
                           capture_output=True)
            recipient = subprocess.check_output(
                ["age-keygen", "-y", str(key)], text=True).strip()
            payload = {"audience": environment,
                       "desktop_companion": f"synthetic-{environment}-companion"}
            encrypted = subprocess.check_output(
                ["sops", "encrypt", "--age", recipient, "--input-type", "json",
                 "--output-type", "json", "--filename-override", f"{environment}.json"],
                input=json.dumps(payload),
                text=True, env=self.env, cwd=self.root)
            (self.root / "secrets" / f"{environment}.enc.json").write_text(encrypted)

    def run_helper(self, environment, code, env=None, input=None):
        command = f"python3 -c {shlex.quote(code)} \"{{}}\""
        return subprocess.run(
            ["bash", str(self.root / "scripts" / HELPER.name), environment, command],
            cwd=self.root.parent, env=env or self.env,
            input=input, text=True, capture_output=True)

    def test_local_keys_decrypt_private_temporary_file_and_remove_it(self):
        for environment in ("development", "release"):
            with self.subTest(environment=environment):
                result = self.run_helper(environment, """
import json, os, pathlib, stat, sys
p = pathlib.Path(sys.argv[1])
assert p.is_file()
assert stat.S_IMODE(p.stat().st_mode) == 0o600
assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700
print(json.dumps({'path': str(p), 'cwd': os.getcwd(), 'payload': json.loads(p.read_text())}))
""")
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                self.assertEqual(Path(output["cwd"]).resolve(), self.root.resolve())
                self.assertEqual(output["payload"], {
                    "audience": environment,
                    "desktop_companion": f"synthetic-{environment}-companion",
                })
                self.assertFalse(Path(output["path"]).exists())

    def test_automation_identity_cannot_decrypt_other_environment(self):
        for environment, other in (("development", "release"),
                                   ("release", "development")):
            with self.subTest(environment=environment):
                env = dict(self.env, SOPS_AGE_KEY=(self.keys / f"{environment}.txt").read_text())
                result = self.run_helper(other, "print('command ran')", env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn(f"synthetic-{other}-companion", result.stderr)

    def test_failed_command_removes_temporary_file(self):
        result = self.run_helper("development", """
import sys
print(sys.argv[1], flush=True)
raise SystemExit(23)
""")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.strip())
        self.assertFalse(Path(result.stdout.strip()).exists())

    def assert_cancelled_cleanup(self, signum, scenario="running"):
        for target in ("helper", "process group"):
            with self.subTest(target=target, scenario=scenario):
                marker = self.root / "command ready.json"
                marker.unlink(missing_ok=True)
                code = """
import json, os, pathlib, sys, time
marker = pathlib.Path(sys.argv[2])
pending = marker.with_suffix('.pending')
pending.write_text(json.dumps({'path': sys.argv[1], 'pid': os.getpid(), 'group': os.getpgrp()}))
pending.rename(marker)
while True:
    time.sleep(60)
"""
                command = (f"python3 -c {shlex.quote(code)} \"{{}}\" "
                           f"{shlex.quote(str(marker))}")
                env = dict(self.env)
                if scenario == "startup":
                    # Schedule cancellation after spawn, before PID registration.
                    # DEBUG only controls timing; the helper and SOPS are real.
                    scheduler = self.root / "startup scheduler.sh"
                    scheduler.write_text(r"""
trap 'if [[ $BASH_COMMAND == '\''child=$!'\'' ]]; then
  trap - DEBUG
  while [[ ! -e $READY_MARKER ]]; do sleep 0.02; done
  if [[ $CANCEL_TARGET == helper ]]; then kill -"$CANCEL_SIGNAL" "$$";
  else kill -"$CANCEL_SIGNAL" -- -"$$"; fi
fi' DEBUG
""")
                    env.update(BASH_ENV=str(scheduler), READY_MARKER=str(marker),
                               CANCEL_SIGNAL=str(signum), CANCEL_TARGET=target)
                process = subprocess.Popen(
                    ["bash", str(self.root / "scripts" / HELPER.name),
                     "development", command],
                    cwd=self.root.parent, env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                temporary = None
                command_pid = None
                command_group = None
                try:
                    deadline = time.monotonic() + 5
                    while not marker.exists() and time.monotonic() < deadline:
                        self.assertIsNone(process.poll(), "command did not start")
                        time.sleep(0.02)
                    self.assertTrue(marker.exists(), "command did not become ready")
                    ready = json.loads(marker.read_text())
                    temporary = Path(ready["path"])
                    command_pid = ready["pid"]
                    command_group = ready["group"]
                    if scenario != "startup":
                        self.assertTrue(temporary.is_file())
                        if scenario == "suspended":
                            os.kill(command_group, signal.SIGSTOP)
                        if target == "helper":
                            process.send_signal(signum)
                        else:
                            os.killpg(process.pid, signum)
                    try:
                        stdout, stderr = process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.fail("cancellation did not finish within five seconds")
                    self.assertFalse(temporary.exists(), "cancelled build left plaintext")
                    self.assertFalse(temporary.parent.exists())
                    self.assertEqual(process.returncode, 128 + signum, stderr)
                    self.assertEqual(stdout, "")
                    state = subprocess.run(
                        ["ps", "-o", "stat=", "-p", str(command_pid)],
                        text=True, capture_output=True).stdout.strip()
                    self.assertTrue(not state or state.startswith("Z"),
                                    "cancelled build is still running")
                finally:
                    # Also clean the synthetic plaintext/children when checking
                    # an implementation that fails the cancellation contract.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    if command_group is not None:
                        try:
                            os.killpg(command_group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if command_pid is not None:
                        try:
                            os.kill(command_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.communicate(timeout=5)
                    if temporary is not None:
                        shutil.rmtree(temporary.parent, ignore_errors=True)

    def test_interrupt_removes_temporary_file(self):
        self.assert_cancelled_cleanup(signal.SIGINT)

    def test_termination_removes_temporary_file(self):
        self.assert_cancelled_cleanup(signal.SIGTERM)

    def test_startup_cancellation_stops_build_and_removes_plaintext(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                self.assert_cancelled_cleanup(signum, scenario="startup")

    def test_suspended_sops_cancellation_stops_build_and_removes_plaintext(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                self.assert_cancelled_cleanup(signum, scenario="suspended")

    def test_command_keeps_standard_input(self):
        payload = "first input\nsecond line with spaces\n"
        result = self.run_helper(
            "development", "import sys; sys.stdout.write(sys.stdin.read())", input=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)

    def test_missing_local_identity_does_not_run_command(self):
        (self.keys / "development.txt").unlink()
        result = self.run_helper("development", "print('command ran')")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("provision a development age identity", result.stderr)


if __name__ == "__main__":
    unittest.main()
