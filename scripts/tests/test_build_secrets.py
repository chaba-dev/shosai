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
        shutil.copy2(HELPER, self.root / "scripts" / HELPER.name)
        shutil.copy2(HELPER.with_name("amp-gcp-identity.py"), self.root / "scripts")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("SHOSAI_", "CLOUDSDK_", "GOOGLE_", "BASH_ENV"))}
        self.env.update(
            HOME=str(self.root), PATH=f"{self.bin}{os.pathsep}{self.env['PATH']}",
            SHOSAI_SECRETS_PROJECT="shosai-synthetic-project",
            FAKE_ACCESS="development,release",
        )
        # Model the external CLI boundary, not Google's IAM. Live IAM acceptance
        # and cross-environment denial must also be verified during provisioning.
        gcloud = self.bin / "gcloud"
        gcloud.write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
options = dict(arg[2:].split('=', 1) for arg in args if arg.startswith('--') and '=' in arg)
if args[:3] == ['iam', 'workload-identity-pools', 'create-cred-config']:
    p = pathlib.Path(options['output-file'])
    p.write_text(json.dumps({'credential_source': {'executable': {'command': options['executable-command']}}}))
    sys.exit(0)
assert args[:3] == ['secrets', 'versions', 'access']
assert options['project'] == 'shosai-synthetic-project'
secret = options['secret']
assert secret in ('shosai-development-build-defines', 'shosai-release-build-defines')
environment = secret.removeprefix('shosai-').removesuffix('-build-defines')
if environment not in os.environ['FAKE_ACCESS'].split(','):
    sys.exit('Permission denied')
credentials = os.environ.get('CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE')
if credentials:
    config = json.loads(pathlib.Path(credentials).read_text())
    if 'credential_source' in config:
        subprocess.run(config['credential_source']['executable']['command'].split(),
                       check=True, stdout=subprocess.DEVNULL)
    elif config['environment'] != environment:
        sys.exit('Permission denied')
p = pathlib.Path(options['out-file'])
payload = {'audience': environment, 'desktop_companion': f'synthetic-{environment}-companion'}
if args[3] != 'latest':
    payload['version'] = args[3]
p.write_text(os.environ.get('FAKE_PAYLOAD', json.dumps(payload)))
if 'FETCH_MARKER' in os.environ:
    pathlib.Path(os.environ['FETCH_MARKER']).write_text(json.dumps({'path': str(p), 'pid': os.getpid()}))
if os.environ.get('FETCH_BLOCKED'):
    while True: time.sleep(60)
sys.exit(int(os.environ.get('FETCH_EXIT', '0')))
''')
        gcloud.chmod(0o755)

    def run_helper(self, environment, code, env=None, input=None):
        command = f"python3 -c {shlex.quote(code)} \"{{}}\""
        return subprocess.run(
            ["bash", str(self.root / "scripts" / HELPER.name), environment, command],
            cwd=self.root.parent, env=env or self.env,
            input=input, text=True, capture_output=True)

    def test_fetches_selected_environment_into_private_temporary_file_and_removes_it(self):
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

    def test_denied_environment_never_runs_command(self):
        for environment, other in (("development", "release"),
                                   ("release", "development")):
            with self.subTest(environment=environment):
                env = dict(self.env, FAKE_ACCESS=environment)
                result = self.run_helper(other, "print('command ran')", env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn(f"synthetic-{other}-companion", result.stderr)

    def test_failed_or_invalid_fetch_removes_partial_plaintext_without_running_command(self):
        marker = self.root / "fetch.json"
        for overrides in ({"FETCH_EXIT": "1"}, {"FAKE_PAYLOAD": "not-json-private"},
                          {"FAKE_PAYLOAD": '["private", "array"]'}):
            with self.subTest(overrides=overrides):
                env = dict(self.env, FETCH_MARKER=str(marker), **overrides)
                result = self.run_helper("development", "print('command ran')", env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("not-json-private", result.stderr)
                temporary = Path(json.loads(marker.read_text())["path"])
                self.assertFalse(temporary.parent.exists())

    def test_pinned_version_and_path_with_shell_metacharacters(self):
        tmp = self.root / 'temp with spaces $HOME $(false) "quotes"'
        tmp.mkdir()
        result = self.run_helper(
            "release", "import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())",
            dict(self.env, TMPDIR=str(tmp), SHOSAI_BUILD_SECRET_VERSION="17"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "audience": "release", "desktop_companion": "synthetic-release-companion",
            "version": "17",
        })
        self.assertEqual(list(tmp.iterdir()), [])

    def test_github_credential_file_is_used_without_local_login(self):
        credentials = self.root / "github credentials.json"
        credentials.write_text(json.dumps({"environment": "release"}))
        env = dict(self.env, CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=str(credentials))
        result = self.run_helper("release", "print('release command ran')", env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "release command ran\n")
        result = self.run_helper("development", "print('command ran')", env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def install_amp(self, fail=False):
        import base64
        expiry = int(time.time()) + 600
        payload = base64.urlsafe_b64encode(json.dumps({"exp": expiry}).encode()).decode().rstrip("=")
        token = f"synthetic-header.{payload}.synthetic-signature"
        amp = self.bin / "amp"
        amp.write_text("#!/usr/bin/env python3\n" + (
            "import sys; sys.exit('private-synthetic-token')\n" if fail else
            f"print({token!r})\n"))
        amp.chmod(0o755)
        return token, expiry

    def test_amp_federation_is_temporary_and_development_only(self):
        token, _ = self.install_amp()
        env = dict(self.env, SHOSAI_AMP_WORKLOAD_IDENTITY_PROVIDER="projects/123/locations/global/workloadIdentityPools/shosai-development/providers/amp-orbs",
                   SHOSAI_AMP_OIDC_AUDIENCE="urn:shosai:development")
        result = self.run_helper("development", """
import json, os, pathlib, stat, sys
p = pathlib.Path(os.environ['CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE'])
assert p.is_file()
assert stat.S_IMODE(p.stat().st_mode) == 0o600
assert os.environ['GOOGLE_APPLICATION_CREDENTIALS'] == str(p)
print(json.dumps({'credentials': str(p), 'payload': json.loads(pathlib.Path(sys.argv[1]).read_text())}))
""", env)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["payload"]["audience"], "development")
        self.assertFalse(Path(output["credentials"]).parent.exists())
        self.assertNotIn(token, result.stdout + result.stderr)
        result = self.run_helper("release", "print('command ran')", env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_amp_executable_protocol_and_failure_do_not_leak_tokens(self):
        token, expiry = self.install_amp()
        env = dict(self.env, SHOSAI_AMP_OIDC_AUDIENCE="urn:shosai:development")
        command = ["python3", str(self.root / "scripts/amp-gcp-identity.py")]
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "version": 1, "success": True,
            "token_type": "urn:ietf:params:oauth:token-type:id_token",
            "id_token": token, "expiration_time": expiry,
        })
        self.install_amp(fail=True)
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["success"])
        self.assertNotIn("private-synthetic-token", result.stdout + result.stderr)

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
                    # DEBUG controls timing; the helper/process supervision is real.
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

    def test_suspended_leader_cancellation_stops_build_and_removes_plaintext(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                self.assert_cancelled_cleanup(signum, scenario="suspended")

    def test_command_keeps_standard_input(self):
        payload = "first input\nsecond line with spaces\n"
        result = self.run_helper(
            "development", "import sys; sys.stdout.write(sys.stdin.read())", input=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)

    def test_missing_project_does_not_use_gcloud_default_or_run_command(self):
        env = dict(self.env)
        env.pop("SHOSAI_SECRETS_PROJECT")
        result = self.run_helper("development", "print('command ran')", env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("SHOSAI_SECRETS_PROJECT", result.stderr)

    def test_cancellation_during_fetch_stops_fetcher_and_removes_partial_plaintext(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                marker = self.root / "fetch-ready.json"
                marker.unlink(missing_ok=True)
                env = dict(self.env, FETCH_MARKER=str(marker), FETCH_BLOCKED="1")
                process = subprocess.Popen([
                    "bash", str(self.root / "scripts" / HELPER.name), "development",
                    "echo command-ran",
                ], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, start_new_session=True)
                ready = None
                try:
                    deadline = time.monotonic() + 5
                    while not marker.exists() and time.monotonic() < deadline:
                        self.assertIsNone(process.poll())
                        time.sleep(0.02)
                    self.assertTrue(marker.exists())
                    ready = json.loads(marker.read_text())
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 128 + signum, stderr)
                    self.assertEqual(stdout, "")
                    self.assertFalse(Path(ready["path"]).parent.exists())
                    state = subprocess.run(
                        ["ps", "-o", "stat=", "-p", str(ready["pid"])],
                        text=True, capture_output=True).stdout.strip()
                    self.assertTrue(not state or state.startswith("Z"))
                finally:
                    if process.poll() is None:
                        process.kill()
                    if ready is not None:
                        try:
                            os.kill(ready["pid"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        shutil.rmtree(Path(ready["path"]).parent, ignore_errors=True)
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
