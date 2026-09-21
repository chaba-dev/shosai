#!/usr/bin/env bash
#
# Native add-books picker smoke runner (restoration package 2B).
#
# Launches the production Flutter application on a real desktop under a private
# X display and a disposable profile, drives it to the platform file picker
# through the real file-selector adapter, verifies that the native dialog
# actually appeared, dismisses it, and checks that the shell recovers. The
# widget tests stub the picker channel, so only this runner can prove the
# native path works.
#
# The run never writes to the user's library: XDG data, config and state
# directories point into an owned temporary profile, and the application
# database lives there too.
#
# Usage:
#   scripts/flutter-native-picker-smoke.sh [options]
#
# Options:
#   --artifacts DIR    where screenshots and the report are written
#                      (default: target/native-picker-smoke/<timestamp>)
#   --timeout SECONDS  bound for the whole run, build included (default 1200)
#   --no-pub           skip dependency resolution before the test run
#   --keep-profile     keep the disposable profile for debugging
#
# Bounds:
#   Inside the run, every phase shares the `--timeout` budget and teardown a
#   single grace, so cooperative steps stop at `--timeout` + grace. Setup and
#   teardown also perform synchronous IO (report redirection, logging, profile
#   creation and removal) that no cooperative budget can interrupt, so the
#   invocation itself is supervised: the script starts the run in its own
#   process group, whose identity is known before any setup IO, and an
#   independent watchdog terminates that whole group after
#   `--timeout` + grace + 5s. Expiry reads no file and runs no command, so a
#   stalled filesystem cannot hang the runner, and the supervising process
#   sweeps the group after the run so no owned process outlives it.
#
# Exit codes:
#   0  the native picker opened and the shell recovered
#   1  a verified phase failed (screenshots and logs are in the artifacts)
#   2  unavailable: prerequisites are missing, so no native claim is made
#   143/137  the run exceeded the bound and was terminated by the supervisor
#
# Run it through the repository dev shell so Xvfb, xdotool, xwininfo, xprop and
# ImageMagick are on PATH. From a secondary JJ workspace, invoke the common
# checkout's wrapper:
#   /path/to/common-checkout/.agents/dev scripts/flutter-native-picker-smoke.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_dir="$root/flutter"
test_target="integration_test/native_picker_smoke_test.dart"

artifacts=""
timeout_seconds=1200
skip_pub=0
keep_profile=0
original_args=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts)
      [[ -n "${2:-}" ]] || { echo "--artifacts needs a directory" >&2; exit 2; }
      artifacts="$2"
      shift 2
      ;;
    --timeout)
      [[ "${2:-}" =~ ^[0-9]+$ && "${2:-}" -gt 0 ]] || {
        echo "--timeout needs a positive number of seconds" >&2
        exit 2
      }
      timeout_seconds="$2"
      shift 2
      ;;
    --no-pub) skip_pub=1; shift ;;
    --keep-profile) keep_profile=1; shift ;;
    -h|--help)
      sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$artifacts" ]]; then
  # A shell builtin, so resolving the default path cannot block on a command or
  # a file before supervision is in place.
  printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
  artifacts="$root/target/native-picker-smoke/$stamp"
fi
if [[ "$artifacts" != /* ]]; then
  artifacts="$root/$artifacts"
fi

cleanup_grace=30
watchdog_bound=$((timeout_seconds + cleanup_grace + 5))

# ---------------------------------------------------------------------------
# Supervision
# ---------------------------------------------------------------------------
# This process only supervises. It starts the run in its own process group
# before any setup IO, enforces the whole-run bound with a watchdog that reads
# no file and spawns no command, and sweeps the group after the run, so a run
# that blocks on a file cannot hang the invocation and cannot leave owned
# processes behind. Everything the run starts (Xvfb, the test driver and the
# application) inherits the run's group.
if [[ "${SHOSAI_SMOKE_SUPERVISED:-0}" != 1 ]]; then
  supervised_pgid=""
  watchdog_pid=""
  group_supervision=1
  child_status=0
  # A name, not a directory: creating it here would be setup IO outside
  # supervision. The run creates and uses it, and the supervisor removes it.
  profile_dir="${TMPDIR:-/tmp}/shosai-picker-smoke.$$"

  stop_watchdog() {
    [[ -n "$watchdog_pid" ]] || return 0
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  }

  # Only processes this run started are in the group, and the group is swept
  # only after the run's own teardown had its chance.
  sweep_run_group() {
    (( group_supervision == 1 )) || return 0
    [[ -n "$supervised_pgid" ]] || return 0
    kill -TERM "-$supervised_pgid" 2>/dev/null || return 0
    local waited=0
    while kill -0 "-$supervised_pgid" 2>/dev/null; do
      (( waited >= 20 )) && break
      sleep 0.1
      waited=$((waited + 1))
    done
    kill -KILL "-$supervised_pgid" 2>/dev/null || true
  }

  supervisor_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_watchdog
    sweep_run_group
    # The supervisor owns the disposable profile: the run removes it in its own
    # teardown, and this backstop covers a run that could not (its teardown
    # grace expired, or it was terminated at the bound). The name was chosen
    # here, so no file is read to find it, and the removal is bounded.
    if (( keep_profile == 0 )) && [[ -n "$profile_dir" ]]; then
      timeout --foreground --kill-after=5 20 rm -rf "$profile_dir" || true
    fi
    exit "$status"
  }
  trap supervisor_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Job control gives the run its own process group whose id equals its pid.
  set -m
  SHOSAI_SMOKE_SUPERVISED=1 SHOSAI_SMOKE_PROFILE_DIR="$profile_dir" \
    bash "${BASH_SOURCE[0]}" "${original_args[@]}" &
  supervised_pgid=$!
  set +m

  # Confirm the group before relying on it; otherwise fall back to killing the
  # run's leader alone.
  stat_line=""
  if read -r stat_line < "/proc/$supervised_pgid/stat" 2>/dev/null; then
    stat_rest="${stat_line##*) }"
    IFS=' ' read -r _state _ppid stat_pgid _session _ <<<"$stat_rest"
    [[ "$stat_pgid" == "$supervised_pgid" ]] || group_supervision=0
  else
    group_supervision=0
  fi

  (
    watchdog_started=$SECONDS
    while (( SECONDS - watchdog_started < watchdog_bound )); do
      sleep 0.5
    done
    # Escalate against the run group. Polling keeps the watchdog's own sleeps
    # short, so stopping it cannot orphan a long one, and the supervisor sweeps
    # the group again after the run in case this escalation is cut short.
    if (( group_supervision == 1 )); then
      kill -TERM "-$supervised_pgid" 2>/dev/null || true
      watchdog_waited=0
      while kill -0 "-$supervised_pgid" 2>/dev/null; do
        (( watchdog_waited >= 20 )) && break
        sleep 0.1
        watchdog_waited=$((watchdog_waited + 1))
      done
      kill -KILL "-$supervised_pgid" 2>/dev/null || true
    else
      kill -TERM "$supervised_pgid" 2>/dev/null || true
      watchdog_waited=0
      while kill -0 "$supervised_pgid" 2>/dev/null; do
        (( watchdog_waited >= 20 )) && break
        sleep 0.1
        watchdog_waited=$((watchdog_waited + 1))
      done
      kill -KILL "$supervised_pgid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  wait "$supervised_pgid"
  child_status=$?
  stop_watchdog
  exit "$child_status"
fi

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------
# One budget bounds every phase of the run: setup, build, launch, picker
# discovery, dismissal and test completion all stop at `deadline`. A single
# shared teardown grace then covers failure capture, process escalation and
# profile removal, so every cooperative step is bounded by
# `--timeout` + `cleanup_grace`.
deadline=$((SECONDS + timeout_seconds))
teardown_deadline=$((deadline + cleanup_grace))

log() {
  local stamp
  # A builtin, so logging never waits on a command.
  TZ=UTC printf -v stamp '%(%H:%M:%S)T' -1
  if [[ -n "$report" ]]; then
    printf '%s %s\n' "$stamp" "$*" | tee -a "$report"
  else
    printf '%s %s\n' "$stamp" "$*"
  fi
}

remaining() {
  local left=$((deadline - SECONDS))
  (( left < 0 )) && left=0
  printf '%s' "$left"
}

teardown_remaining() {
  local left=$((teardown_deadline - SECONDS))
  (( left < 0 )) && left=0
  printf '%s' "$left"
}

# Runs a command with the smaller of its own cap and the remaining budget, with
# forced-kill escalation so a command that ignores TERM cannot hang the runner.
bounded() {
  local cap="$1"
  shift
  local left
  left="$(remaining)"
  if (( left <= 0 )); then
    log "the run budget expired before: $*"
    return 124
  fi
  local budget="$cap"
  (( left < budget )) && budget="$left"
  # `--foreground` keeps the command in this run's process group instead of
  # timeout's own group, so the run's supervisor can always sweep it.
  timeout --foreground --kill-after=5 "$budget" "$@"
}

# Runs an X command against the owned display. The owned Xvfb must still be
# alive, otherwise a reused display number could belong to another server.
xcmd() {
  if [[ -n "$xvfb_pid" ]] && ! kill -0 "$xvfb_pid" 2>/dev/null; then
    log "the owned Xvfb exited; refusing further X commands"
    return 125
  fi
  bounded "${X_COMMAND_TIMEOUT:-10}" env DISPLAY="$display" "$@"
}

report=""
profile=""
xvfb_pid=""
test_pid=""
display=""
screenshots=()

# Installed before the first resource is acquired, so an early exit still tears
# down whatever exists. The run's own process group is swept by the supervisor.
cleanup() {
  local status=$?
  # Teardown shares one budget: escalation polls and profile removal all stop at
  # `teardown_deadline` instead of taking a fresh allowance each.
  if [[ -n "$test_pid" ]]; then
    # The test driver is signalled by pid; its descendants stay in this run's
    # group, which the supervisor sweeps.
    kill -TERM "$test_pid" 2>/dev/null || true
    while (( $(teardown_remaining) > 0 )); do
      kill -0 "$test_pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "$test_pid" 2>/dev/null || true
  fi
  if [[ -n "$xvfb_pid" ]] && kill -0 "$xvfb_pid" 2>/dev/null; then
    kill -TERM "$xvfb_pid" 2>/dev/null || true
    while (( $(teardown_remaining) > 0 )); do
      kill -0 "$xvfb_pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$xvfb_pid" 2>/dev/null || true
  fi
  if [[ -n "$profile" ]]; then
    if (( keep_profile == 1 )); then
      log "kept disposable profile: $profile"
    else
      local left
      left="$(teardown_remaining)"
      if (( left > 0 )); then
        timeout --foreground --kill-after=5 "$left" rm -rf "$profile" || true
      else
        log "profile removal skipped: the teardown grace expired"
      fi
    fi
  fi
  exit "$status"
}
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

mkdir -p "$artifacts" || exit 2
report="$artifacts/report.txt"
: >"$report"

# Captures the display. Within the run budget this is a normal bounded,
# liveness-checked command; after it, the shared teardown grace applies.
capture() {
  local name="$1"
  local file="$artifacts/$name.png"
  local left
  left="$(teardown_remaining)"
  if [[ -n "$xvfb_pid" ]] && ! kill -0 "$xvfb_pid" 2>/dev/null; then
    log "screenshot $name skipped: the owned Xvfb exited"
    return
  fi
  if (( left <= 0 )); then
    log "screenshot $name skipped: the teardown grace expired"
    return
  fi
  if (( $(remaining) > 0 )); then
    if xcmd import -window root "$file" 2>/dev/null; then
      screenshots+=("$file")
      log "screenshot: $file"
      return
    fi
  elif timeout --foreground --kill-after=5 "$left" env DISPLAY="$display" \
      import -window root "$file" 2>/dev/null; then
    screenshots+=("$file")
    log "screenshot: $file"
    return
  fi
  log "screenshot $name was not captured"
}

fail() {
  log "FAIL: $*"
  capture "failure-$(( ${#screenshots[@]} + 1 ))"
  log "test log tail:"
  tail -40 "$artifacts/test.log" 2>/dev/null >>"$report"
  exit 1
}

revision="${SHOSAI_SMOKE_REVISION:-}"
if [[ -z "$revision" ]] && command -v jj >/dev/null 2>&1; then
  revision="$(bounded 10 jj log -r @ --no-graph -T commit_id 2>/dev/null || true)"
fi
if [[ -z "$revision" ]] && command -v git >/dev/null 2>&1; then
  revision="$(bounded 10 git -C "$root" rev-parse HEAD 2>/dev/null || true)"
fi
[[ -n "$revision" ]] || revision="unknown"

log "native picker smoke: revision $revision"
log "artifacts: $artifacts"

missing=()
for tool in flutter cargo Xvfb xdotool xwininfo xprop timeout mktemp import; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
  log "UNAVAILABLE: missing prerequisites: ${missing[*]}"
  log "run this script through the repository dev shell, for example:"
  log "  /path/to/common-checkout/.agents/dev scripts/flutter-native-picker-smoke.sh"
  exit 2
fi

# The supervisor normally supplies the profile path so it can remove a profile
# the run could not; a direct invocation still gets a fresh directory.
profile="${SHOSAI_SMOKE_PROFILE_DIR:-}"
if [[ -n "$profile" ]]; then
  # A reused name (pid reuse after a leaked profile) must not carry stale state
  # such as an old picker marker, so the directory is recreated empty.
  rm -rf "$profile" || true
  mkdir -p "$profile" || {
    log "FAIL: could not create the disposable profile directory"
    exit 1
  }
else
  profile="$(mktemp -d "${TMPDIR:-/tmp}/shosai-picker-smoke.XXXXXX")" || {
    log "FAIL: could not create the disposable profile directory"
    exit 1
  }
fi

# Xvfb allocates a free display itself, so two runners can never share one.
display_file="$profile/display"
Xvfb -displayfd 3 -screen 0 1600x1200x24 3>"$display_file" \
  >"$artifacts/xvfb.log" 2>&1 &
xvfb_pid=$!
for _ in $(seq 1 100); do
  if [[ -s "$display_file" ]]; then
    display=":$(head -1 "$display_file")"
    break
  fi
  kill -0 "$xvfb_pid" 2>/dev/null || break
  (( SECONDS < deadline )) || break
  sleep 0.1
done
if [[ -z "$display" ]] || ! kill -0 "$xvfb_pid" 2>/dev/null; then
  fail "Xvfb did not start"
fi
if ! xcmd xdotool getdisplaygeometry >/dev/null 2>&1; then
  fail "the private display $display did not become ready"
fi
log "Xvfb owns display $display"

mkdir -p "$profile/xdg-data" "$profile/xdg-config" "$profile/xdg-state"

test_args=(test "$test_target" -d linux)
if (( skip_pub == 1 )); then
  test_args+=(--no-pub)
fi

(
  cd "$flutter_dir" || exit 1
  export DISPLAY="$display"
  # Force the X11 backend: without it GDK prefers the host's Wayland session and
  # the application never appears on this private display.
  export GDK_BACKEND=x11
  export SHOSAI_SMOKE_DIR="$profile"
  export XDG_DATA_HOME="$profile/xdg-data"
  export XDG_CONFIG_HOME="$profile/xdg-config"
  export XDG_STATE_HOME="$profile/xdg-state"
  # Force the in-process GTK dialog instead of a desktop portal, which does not
  # exist in a bare Xvfb session.
  export GTK_USE_PORTAL=0
  exec flutter "${test_args[@]}"
) >"$artifacts/test.log" 2>&1 &
test_pid=$!
log "started: flutter ${test_args[*]} (pid $test_pid, in the run's process group)"

while (( SECONDS < deadline )); do
  [[ -f "$profile/picker-requested" ]] && break
  kill -0 "$test_pid" 2>/dev/null || fail "the test exited before it requested the native picker"
  sleep 1
done
[[ -f "$profile/picker-requested" ]] ||
  fail "the test did not request the native picker within ${timeout_seconds}s"
log "the application requested the native picker"

root_window="$(xcmd xwininfo -root 2>/dev/null | awk '/Window id:/{print $4}')"
[[ -n "$root_window" ]] || fail "the private display did not report a root window"
root_window=$((root_window))

# Every window on this private display belongs to this run; the root window is
# the only one that is not.
window_ids() {
  xcmd xdotool search --name '.*' 2>/dev/null \
    | grep -v "^${root_window}$" || true
}

window_geometry() {
  xcmd xdotool getwindowgeometry --shell "$1" 2>/dev/null \
    | awk -F= '/^WIDTH=/{w=$2} /^HEIGHT=/{h=$2} END{print w" "h}'
}

window_type() {
  xcmd xprop -id "$1" _NET_WM_WINDOW_TYPE 2>/dev/null | head -1
}

# The native file chooser is the application's dialog window; helper windows
# are tiny, and the main window is a normal window.
picker_window() {
  local id width height
  for id in $(window_ids); do
    # Enumeration is bounded too: every window costs two X round trips.
    (( $(remaining) > 0 )) || return 1
    read -r width height < <(window_geometry "$id")
    if [[ -z "${width:-}" || -z "${height:-}" ]]; then
      continue
    fi
    (( width * height >= 200 * 100 )) || continue
    if [[ "$(window_type "$id")" == *"_NET_WM_WINDOW_TYPE_DIALOG"* ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

app_windows="$(window_ids | wc -l)"
log "application windows before the picker: $app_windows"

dialog_id=""
while (( SECONDS < deadline )); do
  dialog_id="$(picker_window || true)"
  [[ -n "$dialog_id" ]] && break
  kill -0 "$test_pid" 2>/dev/null || break
  sleep 0.5
done
[[ -n "$dialog_id" ]] ||
  fail "no native picker window appeared within ${timeout_seconds}s"
log "native picker window: $dialog_id ($(window_geometry "$dialog_id"))"
capture "picker-open"
dialog_left="$(remaining)"
if [[ -n "$xvfb_pid" ]] && kill -0 "$xvfb_pid" 2>/dev/null; then
  if (( dialog_left > 0 )); then
    xcmd import -window "$dialog_id" "$artifacts/picker-dialog.png" 2>/dev/null ||
      log "the dialog screenshot was not captured"
  else
    dialog_left="$(teardown_remaining)"
    if (( dialog_left > 0 )) && timeout --foreground --kill-after=5 "$dialog_left" \
        env DISPLAY="$display" import -window "$dialog_id" \
        "$artifacts/picker-dialog.png" 2>/dev/null; then
      log "screenshot: $artifacts/picker-dialog.png"
    fi
  fi
  [[ -f "$artifacts/picker-dialog.png" ]] &&
    log "screenshot: $artifacts/picker-dialog.png"
fi

xcmd xdotool windowfocus --sync "$dialog_id" 2>/dev/null || true
xcmd xdotool key --clearmodifiers Escape 2>/dev/null || true
while (( SECONDS < deadline )); do
  window_ids | grep -q "^${dialog_id}$" || break
  sleep 0.5
done
if window_ids | grep -q "^${dialog_id}$"; then
  fail "the native picker did not close after Escape"
fi
log "the native picker closed"

while (( SECONDS < deadline )); do
  kill -0 "$test_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$test_pid" 2>/dev/null; then
  fail "the test did not finish within ${timeout_seconds}s"
fi
wait "$test_pid"
test_status=$?
if (( test_status != 0 )); then
  fail "the integration test failed with status $test_status"
fi

result="$profile/smoke-result.json"
if [[ ! -f "$result" ]]; then
  fail "the integration test did not write $result"
fi
cp "$result" "$artifacts/smoke-result.json"
log "result: $(tr -d '\n' <"$artifacts/smoke-result.json")"

log "PASS: the native picker opened and the shell recovered"
{
  echo "revision: $revision"
  echo "command: flutter ${test_args[*]}"
  echo "display: $display"
  echo "screenshots:"
  for file in "${screenshots[@]}"; do echo "  $file"; done
} >>"$report"
exit 0
