#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <development|release> '<command using \"{}\" for the Dart defines file>'" >&2
  exit 2
fi
case "$1" in
  development|release) environment=$1 ;;
  *) echo "error: choose development or release" >&2; exit 2 ;;
esac

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

# Never silently use the developer's unrelated default gcloud project.
: "${SHOSAI_SECRETS_PROJECT:?Set SHOSAI_SECRETS_PROJECT to the Secret Manager project ID}"

# Keep a supervising shell alive during authentication, fetching and the build
# so cancellation stops the whole process group before removing plaintext.
temporary=
child=
cancelled=
cancel() {
  cancelled=$1
  # A signal can arrive after spawn but before child=$!. Defer exiting until
  # that PID is registered so cleanup cannot leave the new build behind.
  if [[ -n "$child" ]]; then
    exit "$cancelled"
  fi
}
cleanup() {
  trap '' INT TERM
  if [[ -n "$child" ]]; then
    kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
    # Do not wait indefinitely for a stopped or TERM-resistant group leader.
    for _ in {1..10}; do
      if ! kill -0 "$child" 2>/dev/null; then break; fi
      sleep 0.1
    done
    kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  if [[ -n "$temporary" ]]; then
    rm -rf -- "$temporary"
  fi
}
trap cleanup EXIT
trap 'cancel 130' INT
trap 'cancel 143' TERM
umask 077
temporary="$(mktemp -d "${TMPDIR:-/tmp}/shosai-build.XXXXXXXX")"

# A separate session lets cancellation stop descendants without signalling the
# caller. Preserve stdin and reset the SIGINT disposition of background jobs.
# The defines-path variable expands in the child Bash, not in this shell.
# shellcheck disable=SC2016
python3 -c '
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

os.setsid()
signal.signal(signal.SIGINT, signal.SIG_DFL)
temporary, environment, command = sys.argv[1:]
provider = os.environ.get("SHOSAI_AMP_WORKLOAD_IDENTITY_PROVIDER")
try:
    if provider:
        if environment != "development":
            sys.exit("error: Amp federation is for development only")
        credentials = str(Path(temporary) / "federation.json")
        # google-auth splits this command on whitespace without shell quoting.
        # Resolve the fixed helper name through our trusted, possibly spaced PATH.
        os.environ["PATH"] = str(Path.cwd() / "scripts") + os.pathsep + os.environ["PATH"]
        executable = "amp-gcp-identity.py"
        subprocess.run([
            "gcloud", "iam", "workload-identity-pools", "create-cred-config", provider,
            "--subject-token-type=urn:ietf:params:oauth:token-type:id_token",
            f"--executable-command={executable}", f"--output-file={credentials}",
            "--quiet",
        ], check=True, stdout=subprocess.DEVNULL)
        os.environ.update(
            CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=credentials,
            GOOGLE_APPLICATION_CREDENTIALS=credentials,
            GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES="1",
        )
    defines = str(Path(temporary) / "defines.json")
    project = os.environ["SHOSAI_SECRETS_PROJECT"]
    subprocess.run([
        "gcloud", "secrets", "versions", "access",
        os.environ.get("SHOSAI_BUILD_SECRET_VERSION", "latest"),
        f"--project={project}",
        f"--secret=shosai-{environment}-build-defines", f"--out-file={defines}",
        "--quiet",
    ], check=True, stdout=subprocess.DEVNULL)
    with open(defines) as source:
        payload = json.load(source)
    if not isinstance(payload, dict) or not payload or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in payload.items()
    ):
        sys.exit("error: build defines must be a nonempty JSON object of strings")
except (subprocess.CalledProcessError, OSError, ValueError):
    sys.exit("error: could not fetch valid build defines from Secret Manager")
# Expand a variable rather than interpolating a pathname into shell source.
# Callers still quote \"{}\" so paths containing spaces remain a single argument.
os.environ["SHOSAI_BUILD_DEFINES_FILE"] = defines
os.execvp("bash", ["bash", "-c", command.replace("{}", "${SHOSAI_BUILD_DEFINES_FILE}")])
' "$temporary" "$environment" "$2" <&0 &
child=$!
if [[ -n "$cancelled" ]]; then
  exit "$cancelled"
fi
wait "$child"
child=
