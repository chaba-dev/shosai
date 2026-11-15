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

# Orbs/Actions receive their own identity through SOPS_AGE_KEY. Local runners
# select a per-environment file. SOPS may also load its default age keyring.
if [[ -z "${SOPS_AGE_KEY:-}" && -z "${SOPS_AGE_KEY_FILE:-}" && -z "${SOPS_AGE_KEY_CMD:-}" ]]; then
  export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/shosai/$environment.txt"
  if [[ ! -r "$SOPS_AGE_KEY_FILE" ]]; then
    echo "error: provision a $environment age identity or set SOPS_AGE_KEY_FILE" >&2
    exit 1
  fi
fi

# Own SOPS's temporary directory too: SOPS alone leaves plaintext behind when
# interrupted. Keep a supervising shell alive to stop the build and clean up.
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
    # Do not wait indefinitely for a stopped or TERM-resistant SOPS leader.
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
TMPDIR="$temporary" python3 -c '
import os, signal, sys
os.setsid()
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
' sops exec-file --no-fifo --output-type json --filename defines.json \
  "secrets/$environment.enc.yaml" "$2" <&0 &
child=$!
if [[ -n "$cancelled" ]]; then
  exit "$cancelled"
fi
wait "$child"
child=
