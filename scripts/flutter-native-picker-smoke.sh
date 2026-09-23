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
# Platform paths:
#   Linux  a private Xvfb display (no session needed) with xdotool, xwininfo,
#          xprop and ImageMagick.
#   macOS  the real session: the panel is an NSOpenPanel sheet, so the runner
#          needs Accessibility (to inspect and dismiss it) and Screen Recording
#          (to capture it). Both are preflighted and reported as UNAVAILABLE with
#          the owner action; the runner never grants permissions itself, and the
#          Screen Recording preflight takes no capture. Every capture is scoped
#          to this run's own window (`-l <CGWindowID> -o`), resolved from the
#          verified application pid; a window that cannot be resolved is
#          missing evidence, never a whole-screen capture.
#   other  UNAVAILABLE (exit 2), never an assumed pass.
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
# Environment overrides, for evidence and controls:
#   SHOSAI_SMOKE_REVISION    revision recorded in the report
#   SHOSAI_SMOKE_PLATFORM    force the platform branch (Linux or Darwin)
#   SHOSAI_SMOKE_PGID_SOURCE auto|proc|ps  force a group-lookup source
#   X_COMMAND_TIMEOUT        per X or capture command bound (default 10)
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
  start_gate_seconds="${SHOSAI_SMOKE_START_GATE_SECONDS:-30}"
  pgid_timeout="${SHOSAI_SMOKE_PGID_TIMEOUT:-10}"
  # A name only: creating it here would be setup IO before supervision. The
  # token makes the handshake belong to this invocation, so a file left behind
  # by an earlier run cannot release an unconfirmed child.
  gate_file="${SHOSAI_SMOKE_START_GATE_FILE:-${TMPDIR:-/tmp}/shosai-picker-smoke-gate.$$}"
  gate_token="$$-$RANDOM-$RANDOM"

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
    if [[ -n "$gate_file" ]]; then
      # Bounded like the profile removal above: the watchdog is already stopped
      # here, so an unlink that stalls must not hold the supervisor.
      timeout --foreground --kill-after=2 5 rm -f "$gate_file" 2>/dev/null || true
    fi
    exit "$status"
  }
  trap supervisor_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Job control gives the run its own process group whose id equals its pid.
  set -m
  SHOSAI_SMOKE_SUPERVISED=1 SHOSAI_SMOKE_PROFILE_DIR="$profile_dir" \
    SHOSAI_SMOKE_START_GATE_FILE="$gate_file" \
    SHOSAI_SMOKE_START_GATE_TOKEN="$gate_token" \
    SHOSAI_SMOKE_START_GATE_SECONDS="$start_gate_seconds" \
    bash "${BASH_SOURCE[0]}" "${original_args[@]}" &
  supervised_pgid=$!
  set +m

  # The run stays behind a start gate until its process group is confirmed, so
  # a run that cannot be supervised owns nothing. Both lookups are bounded and
  # spawn no descendants: a hung lookup cannot delay the watchdog that follows
  # it, and killing a lookup cannot orphan a grandchild.
  confirm_run_group() {
    local pid="$supervised_pgid"
    local source="${SHOSAI_SMOKE_PGID_SOURCE:-auto}"
    if [[ "$source" != ps ]]; then
      local proc_pgid=""
      # shellcheck disable=SC2016  # the child shell expands these itself
      proc_pgid="$(timeout --foreground --kill-after=2 "$pgid_timeout" bash -c '
        read -r line < "/proc/$1/stat" || exit 1
        rest="${line##*) }"
        # shellcheck disable=SC2086  # word splitting reads the stat fields
        set -- $rest
        printf "%s" "$3"
      ' _ "$pid" 2>/dev/null)" || proc_pgid=""
      if [[ -n "$proc_pgid" ]]; then
        printf '%s' "$proc_pgid"
        return 0
      fi
    fi
    [[ "$source" != proc ]] || return 1
    command -v ps >/dev/null 2>&1 || return 1
    local pgid=""
    pgid="$(timeout --foreground --kill-after=2 "$pgid_timeout" \
      ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" || return 1
    [[ -n "$pgid" ]] || return 1
    printf '%s' "$pgid"
  }

  stat_pgid="$(confirm_run_group)" || stat_pgid=""
  if [[ "$stat_pgid" != "$supervised_pgid" ]]; then
    group_supervision=0
    # The run is still behind its gate and owns nothing yet, so stopping it and
    # reaping it is enough.
    kill -TERM "$supervised_pgid" 2>/dev/null || true
    stat_waited=0
    while kill -0 "$supervised_pgid" 2>/dev/null; do
      (( stat_waited >= 20 )) && break
      sleep 0.1
      stat_waited=$((stat_waited + 1))
    done
    kill -KILL "$supervised_pgid" 2>/dev/null || true
    wait "$supervised_pgid" 2>/dev/null || true
    echo "UNAVAILABLE: the run's process group could not be confirmed" \
      "(${stat_pgid:-unknown} vs $supervised_pgid) within ${pgid_timeout}s, so" \
      "owned descendants cannot be guaranteed to stop with it. Refusing to run." >&2
    exit 2
  fi
  # Open the gate the run is waiting on, writing this invocation's token.
  # Bounded, so a stalled write cannot delay the invocation past the run's own
  # gate timeout.
  # shellcheck disable=SC2016  # the child shell expands these itself
  timeout --foreground --kill-after=2 5 bash -c 'printf "%s" "$2" > "$1"' _ \
    "$gate_file" "$gate_token" 2>/dev/null ||
    echo "the start gate could not be opened; the run will refuse to start" >&2

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

report=""
profile=""
xvfb_pid=""
test_pid=""
display=""
screenshots=()

# The supervisor confirms this run's process group before the run is allowed to
# start, so a run that could not be supervised owns nothing when it is refused.
start_gate_file="${SHOSAI_SMOKE_START_GATE_FILE:-}"
start_gate_token="${SHOSAI_SMOKE_START_GATE_TOKEN:-}"
if [[ -n "$start_gate_file" ]]; then
  gate_open=0
  gate_deadline=$((SECONDS + ${SHOSAI_SMOKE_START_GATE_SECONDS:-30}))
  while (( SECONDS < gate_deadline )); do
    # Only this invocation's token opens the gate: a file left behind by an
    # earlier run at the same path must not release an unconfirmed child.
    if [[ -s "$start_gate_file" ]]; then
      # A builtin read, not `cat`: nothing external may run before the
      # supervisor confirms ownership, or the refusal path would leave a
      # descendant it never owned.
      gate_content=""
      read -r gate_content < "$start_gate_file" || true
      if [[ "$gate_content" == "$start_gate_token" ]]; then
        gate_open=1
        break
      fi
    fi
    sleep 0.1
  done
  if (( gate_open != 1 )); then
    log "UNAVAILABLE: the supervisor did not confirm this run's process group"
    exit 2
  fi
  log "supervisor confirmed the run's process group"
fi

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
  # A failure before the platform capture path is defined has nothing to
  # capture; it must not turn into "command not found" and lose the report.
  if ! declare -F capture_screen >/dev/null; then
    log "screenshot $name skipped: no capture path is available yet"
    return
  fi
  if [[ -n "$xvfb_pid" ]] && ! kill -0 "$xvfb_pid" 2>/dev/null; then
    log "screenshot $name skipped: the owned Xvfb exited"
    return
  fi
  if (( left <= 0 )); then
    log "screenshot $name skipped: the teardown grace expired"
    return
  fi
  if (( $(remaining) > 0 )); then
    if capture_screen "$file"; then
      screenshots+=("$file")
      log "screenshot: $file"
      return
    fi
  elif capture_screen_forced "$left" "$file"; then
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

# The runner has one automation path per desktop the application ships on: a
# private Xvfb display on Linux, and the real session on macOS, where the native
# panel is a sheet that only System Events can dismiss. SHOSAI_SMOKE_PLATFORM
# overrides the detected platform so the other branch can be exercised on
# purpose.
platform="${SHOSAI_SMOKE_PLATFORM:-$(uname -s 2>/dev/null || echo unknown)}"
log "platform: $platform"

case "$platform" in
  Linux)
    test_device="linux"
    prerequisites=(flutter cargo ps Xvfb xdotool xwininfo xprop timeout mktemp import)
    ;;
  Darwin)
    test_device="macos"
    prerequisites=(flutter cargo ps screencapture osascript swiftc timeout mktemp)
    ;;
  *)
    log "UNAVAILABLE: no native picker automation path for platform $platform"
    exit 2
    ;;
esac

missing=()
for tool in "${prerequisites[@]}"; do
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
if [[ "$platform" == Linux ]]; then
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
fi

if [[ "$platform" == Darwin ]]; then
  # macOS has no private display: the panel opens in the real session, and
  # dismissing it and capturing it both need permissions the runner cannot
  # grant. Both are checked here so the run reports a limitation instead of a
  # native result it could not verify.
  # The application publishes its own pid next to the picker marker, so every
  # AppleScript call below addresses this run's process by unix id instead of
  # by name (another instance of the same application may be running).
  darwin_app_pid_file="$profile/app-pid"
  # Ownership state: `darwin_pid` is set once the run has verified that the
  # application it drives belongs to this run's process group. Capture
  # resolution refuses until then, so an early failure records missing evidence
  # instead of reaching for a window that was never established.
  darwin_pid=""
  if ! sw_vers -productVersion >/dev/null 2>&1; then
    log "UNAVAILABLE: sw_vers did not report a macOS version"
    exit 2
  fi
  log "macOS $(sw_vers -productVersion) on $(uname -m)"

  # ---------------------------------------------------------------------------
  # Capture scope probe
  # ---------------------------------------------------------------------------
  # macOS has no private display, so a capture can reach unrelated desktop
  # content. The probe below decides what may be captured without taking a
  # capture: it answers the Screen Recording authorization, and it resolves a
  # window id from CGWindowListCopyWindowInfo for a pid this run verified, so
  # every screencapture call is scoped to that window with -l.
  darwin_probe_dir="$profile/window-probe"
  darwin_probe_source="$darwin_probe_dir/shosai-window-probe.swift"
  darwin_probe="$darwin_probe_dir/shosai-window-probe"

  if ! mkdir -p "$darwin_probe_dir"; then
    log "UNAVAILABLE: the capture probe directory could not be created under the"
    log "disposable profile. Owner action: check that ${TMPDIR:-/tmp} is writable."
    exit 2
  fi
  cat >"$darwin_probe_source" <<'SWIFT'
import AppKit
import Carbon
import CoreGraphics
import Foundation

// Answers the two questions a capture decision needs, without capturing:
// whether Screen Recording is granted, and which window belongs to a pid this
// run verified. Window names are never read: they need Screen Recording, and
// nothing here may depend on that permission.
func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    fail("usage: probe <screen-recording|window-id|window-list> [options]", 2)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

switch mode {
case "screen-recording":
    // Reports the current authorization and never prompts or captures.
    exit(CGPreflightScreenCaptureAccess() ? 0 : 3)
case "system-events":
    // Apple Events access to System Events is the Automation service, which is
    // not the same grant as Accessibility, and asking for it raises a consent
    // prompt. `askUserIfNeeded: false` answers without prompting: 0 granted,
    // 3 denied, 4 consent would be required.
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
    let wildcard = AEEventClass(0x2A2A2A2A)
    var status = AEDeterminePermissionToAutomateTarget(
        target.aeDesc, wildcard, AEEventID(0x2A2A2A2A), false)
    if status == -600 {
        // procNotFound: System Events is launched on demand, and consent for a
        // target that is not running cannot be determined. It is a background
        // agent with no UI that this runner drives moments later, so it is
        // started here (inactively) and the question is asked again. Nothing
        // prompts.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let started = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"),
            configuration: configuration
        ) { _, _ in started.signal() }
        _ = started.wait(timeout: .now() + 5)
        var waited = 0.0
        while waited < 5.0, status == -600 {
            Thread.sleep(forTimeInterval: 0.25)
            waited += 0.25
            status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, wildcard, AEEventID(0x2A2A2A2A), false)
        }
    }
    switch status {
    case 0: exit(0)  // noErr
    case -1743: exit(3)  // errAEEventNotPermitted
    case -1744: exit(4)  // errAEEventWouldRequireUserConsent
    default: fail("the Apple Events preflight returned \(status)", 5)
    }
case "window-id", "window-list":
    guard let pidText = option("--pid"), let pid = Int(pidText) else {
        fail("--pid is required", 2)
    }
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    // `--records FILE` replaces the live window list with synthetic records
    // (`pid id x y width height` per line). It exists so the ownership filter
    // and the bounds match can be controlled without a window server, and it
    // never captures. Both sources produce the same records and pass through the
    // same ownership filter below, so a synthetic control protects the live
    // filter instead of a second implementation of it.
    var records: [(pid: Int, id: Int, rect: CGRect)] = []
    if let recordsPath = option("--records") {
        guard let text = try? String(contentsOfFile: recordsPath, encoding: .utf8) else {
            fail("the records file could not be read", 5)
        }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ").compactMap { Double($0) }
            guard fields.count == 6 else { continue }
            records.append(
                (Int(fields[0]), Int(fields[1]),
                 CGRect(x: fields[2], y: fields[3], width: fields[4], height: fields[5])))
        }
    } else {
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            fail("the window list is unavailable", 5)
        }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            records.append((owner, number, rect))
        }
    }
    let owned = records.filter { $0.pid == pid }.map { (id: $0.id, rect: $0.rect) }
    if mode == "window-list" {
        for window in owned {
            print("\(window.id) \(Int(window.rect.origin.x)) \(Int(window.rect.origin.y)) "
                + "\(Int(window.rect.width)) \(Int(window.rect.height))")
        }
        exit(owned.isEmpty ? 4 : 0)
    }
    guard let rectText = option("--rect") else { fail("--rect is required", 2) }
    let parts = rectText.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { fail("--rect needs x,y,width,height", 2) }
    let wanted = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    let tolerance = CGFloat(Double(option("--tolerance") ?? "2") ?? 2)
    let ranked = owned.compactMap { window -> (id: Int, distance: CGFloat)? in
        let distance = max(
            abs(window.rect.origin.x - wanted.origin.x),
            abs(window.rect.origin.y - wanted.origin.y),
            abs(window.rect.width - wanted.width),
            abs(window.rect.height - wanted.height))
        return distance <= tolerance ? (window.id, distance) : nil
    }.sorted { $0.distance < $1.distance }
    guard let best = ranked.first else { exit(4) }
    if ranked.count > 1, ranked[1].distance - best.distance <= 0.01 {
        // Two windows of this pid fit the reported geometry equally well, so the
        // capture target is ambiguous and is refused rather than guessed.
        fail("the reported rect matches more than one window of pid \(pid)", 4)
    }
    print(best.id)
default:
    fail("unknown mode \(mode)", 2)
}
SWIFT
  if ! bounded 60 swiftc -O -o "$darwin_probe" "$darwin_probe_source" \
      >"$artifacts/probe-build.log" 2>&1; then
    log "UNAVAILABLE: the capture probe did not compile, so no capture can be"
    log "scoped to this run's own window. Owner action: check the macOS toolchain"
    log "(swiftc) and $artifacts/probe-build.log, then re-run."
    exit 2
  fi

  # Apple Events consent for System Events is a separate TCC service from
  # Accessibility, and asking for it raises a consent prompt. It is checked
  # without prompting first, so a host that lacks it is told which setting to
  # change instead of leaving a prompt pending for the run's whole bound.
  system_events_status=0
  bounded 20 "$darwin_probe" system-events || system_events_status=$?
  if (( system_events_status != 0 )); then
    case "$system_events_status" in
      4)
        log "UNAVAILABLE: the automation host has not been granted Apple Events"
        log "access to System Events, so the native panel cannot be inspected or"
        log "dismissed, and asking would raise a consent prompt. Owner action:"
        log "System Settings -> Privacy & Security -> Automation, then allow the"
        log "process running this script to control System Events."
        ;;
      3)
        log "UNAVAILABLE: Apple Events access to System Events was denied for the"
        log "process running this script. Owner action: System Settings -> Privacy"
        log "& Security -> Automation, then enable System Events for it."
        ;;
      *)
        log "UNAVAILABLE: the Apple Events preflight did not answer (status"
        log "$system_events_status). Owner action: re-run, and if it repeats"
        log "check $artifacts/probe-build.log."
        ;;
    esac
    exit 2
  fi
  log "Apple Events preflight: System Events is reachable, without prompting"

  accessibility_status=0
  bounded "${X_COMMAND_TIMEOUT:-10}" osascript -e 'tell application "System Events" to get name of first process' \
    >/dev/null 2>&1 || accessibility_status=$?
  if (( accessibility_status != 0 )); then
    if (( accessibility_status == 124 || accessibility_status == 137 )); then
      log "UNAVAILABLE: the accessibility preflight did not finish within its"
      log "command or run time limit (status $accessibility_status), so the native"
      log "panel cannot be inspected or dismissed. Owner action: raise"
      log "X_COMMAND_TIMEOUT if the per-command limit expired, or re-run with a"
      log "larger --timeout if the run budget was exhausted; this outcome does not"
      log "indicate a missing permission."
    else
      log "UNAVAILABLE: System Events did not answer the accessibility preflight,"
      log "so the native panel cannot be dismissed or inspected. Owner action:"
      log "grant Accessibility to the process running this script (System Settings"
      log "-> Privacy & Security -> Accessibility), then re-run."
    fi
    exit 2
  fi
  log "Accessibility preflight: System Events is reachable"

  screen_recording_status=0
  bounded 20 "$darwin_probe" screen-recording || screen_recording_status=$?
  if (( screen_recording_status != 0 )); then
    if (( screen_recording_status == 3 )); then
      log "UNAVAILABLE: Screen Recording is not granted, so the picker cannot be"
      log "captured. Owner action: grant Screen Recording to the process running"
      log "this script (System Settings -> Privacy & Security -> Screen"
      log "Recording), then re-run."
    else
      log "UNAVAILABLE: the Screen Recording preflight did not answer (status"
      log "$screen_recording_status), so no capture can be scoped safely. Owner"
      log "action: re-run, and if it repeats check $artifacts/probe-build.log and"
      log "the macOS toolchain."
    fi
    exit 2
  fi
  log "Screen Recording preflight: allowed, and no capture was taken to ask"
fi

mkdir -p "$profile/xdg-data" "$profile/xdg-config" "$profile/xdg-state"

# ---------------------------------------------------------------------------
# Native panel interface
# ---------------------------------------------------------------------------
# Both platforms expose the same four operations, so the phases below are
# written once: is the panel there, where is it, capture it, dismiss it.
if [[ "$platform" == Linux ]]; then
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

  panel_present() {
    [[ -n "$(picker_window || true)" ]]
  }

  panel_description() {
    local id
    id="$(picker_window || true)"
    printf '%s %s\n' "$id" "$(window_geometry "$id")"
  }

  panel_geometry() {
    window_geometry "$(picker_window || true)"
  }

  capture_screen() {
    xcmd import -window root "$1" 2>/dev/null
  }

  # Teardown capture: the run budget is gone, so the shared grace applies.
  capture_screen_forced() {
    timeout --foreground --kill-after=5 "$1" env DISPLAY="$display" \
      import -window root "$2" 2>/dev/null
  }

  dismiss_panel() {
    local id
    id="$(picker_window || true)"
    xcmd xdotool windowfocus --sync "$id" 2>/dev/null || true
    xcmd xdotool key --clearmodifiers Escape 2>/dev/null || true
  }
else
  # macOS: the panel is a sheet of the application process, so the application's
  # window list is the panel signal, and Escape is sent through System Events.
  # Every call targets the pid this run started, never a process name.
  darwin_pgid_of() {
    local pid="$1" line rest pgid=""
    if [[ -r "/proc/$pid/stat" ]] && read -r line < "/proc/$pid/stat"; then
      rest="${line##*) }"
      # shellcheck disable=SC2086  # word splitting reads the stat fields
      set -- $rest
      pgid="$3"
    else
      pgid="$(bounded "${X_COMMAND_TIMEOUT:-10}" ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    fi
    [[ -n "$pgid" ]] || return 1
    printf '%s' "$pgid"
  }

  # This run's own group, so the application can be checked against it.
  darwin_run_pgid() {
    darwin_pgid_of "$$"
  }

  darwin_owned_pid() {
    local pid=""
    [[ -s "$darwin_app_pid_file" ]] || return 1
    # The application writes the pid without a trailing newline, so the value is
    # validated by shape rather than by read's end-of-file status.
    read -r pid < "$darwin_app_pid_file" || true
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$pid"
  }

  darwin_require_ownership() {
    local pid run_pgid app_pgid
    if ! pid="$(darwin_owned_pid)"; then
      log "UNAVAILABLE: the application did not publish its pid, so this run's"
      log "panel cannot be told apart from another instance. Refusing to drive it."
      exit 2
    fi
    if ! run_pgid="$(darwin_run_pgid)" || ! app_pgid="$(darwin_pgid_of "$pid")"; then
      log "UNAVAILABLE: the application pid $pid has no readable process group."
      exit 2
    fi
    if [[ "$app_pgid" != "$run_pgid" ]]; then
      log "UNAVAILABLE: application pid $pid is in group $app_pgid, not this run's"
      log "group $run_pgid. Refusing to drive another instance."
      exit 2
    fi
    darwin_pid="$pid"
    log "driving application pid $darwin_pid (group $app_pgid)"
  }

  # Runs one statement inside `tell targetProcess`, where targetProcess is
  # resolved by unix id inside the same System Events scope. Every application
  # query and every keystroke goes through here, so no operation can fall back
  # to a process name.
  darwin_osascript() {
    local fragment="$1"
    bounded "${X_COMMAND_TIMEOUT:-10}" osascript \
      -e 'tell application "System Events"' \
      -e "set targetProcess to first process whose unix id is $darwin_pid" \
      -e "tell targetProcess" \
      -e "  $fragment" \
      -e 'end tell' \
      -e 'end tell' 2>/dev/null || true
  }

  darwin_windows() {
    darwin_osascript 'return count of windows'
  }

  darwin_sheets() {
    darwin_osascript 'return count of sheets of window 1'
  }

  panel_present() {
    local sheets windows
    (( $(remaining) > 0 )) || return 1
    sheets="$(darwin_sheets)"
    windows="$(darwin_windows)"
    [[ "$sheets" == "1" ]] && return 0
    [[ -n "$windows" && "$windows" -ge 2 ]] && return 0
    return 1
  }

  panel_description() {
    printf 'pid=%s sheet=%s windows=%s\n' "${darwin_pid:-unknown}" \
      "$(darwin_sheets)" "$(darwin_windows)"
  }

  # The panel rect, in screen points, so the capture holds only this run's UI.
  # `position` and `size` are coordinate lists, which System Events prints as
  # `x, y, w, h`. Indexing them in place (`item 1 of (position of window 1)`)
  # is rejected with error -1700 on current macOS, so the lists are returned
  # whole; the parser below accepts exactly the printed form.
  panel_geometry() {
    local sheet_rect window_rect
    sheet_rect="$(darwin_osascript 'return {position of sheet 1 of window 1, size of sheet 1 of window 1}')"
    window_rect="$(darwin_osascript 'return {position of window 1, size of window 1}')"
    if [[ "$sheet_rect" == *","* ]]; then
      printf '%s\n' "$sheet_rect" | tr -d ' '
    else
      printf '%s\n' "$window_rect" | tr -d ' '
    fi
  }

  # The window id this run captures. It is established once from the rect
  # System Events reports for the verified pid and then reused, so the teardown
  # capture needs no further query. The id is left in `darwin_window_id` rather
  # than printed, because `log` writes to stdout and a command substitution
  # would swallow the missing-evidence messages.
  darwin_window_id=""

  darwin_establish_window_id() {
    [[ -n "$darwin_window_id" ]] && return 0
    if [[ -z "$darwin_pid" ]]; then
      log "no capture: this run has not established which application it owns"
      return 1
    fi
    local geometry id
    geometry="$(panel_geometry)"
    if [[ ! "$geometry" =~ ^([0-9-]+),([0-9-]+),([0-9]+),([0-9]+)$ ]]; then
      log "no capture: System Events reported no sheet or window rect for pid $darwin_pid"
      return 1
    fi
    id="$(bounded "${X_COMMAND_TIMEOUT:-10}" "$darwin_probe" window-id \
      --pid "$darwin_pid" \
      --rect "${BASH_REMATCH[1]},${BASH_REMATCH[2]},${BASH_REMATCH[3]},${BASH_REMATCH[4]}" \
      2>/dev/null)" || id=""
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
      log "no capture: no window owned by pid $darwin_pid matches the reported rect"
      return 1
    fi
    darwin_window_id="$id"
  }

  # Every capture is scoped to this run's own window: `-l` takes the window id
  # established from the verified pid, and `-o` omits the window shadow, which
  # would otherwise sample the desktop behind it. A target that cannot be
  # established is missing evidence, never an unscoped capture.
  capture_screen() {
    local target="$1"
    darwin_establish_window_id || return 1
    bounded "${X_COMMAND_TIMEOUT:-10}" screencapture -x -o -l "$darwin_window_id" "$target" 2>/dev/null
  }

  # Teardown capture: the run budget is gone, so the shared grace applies. The
  # window id is reused when the run established one earlier; a run that never
  # did has no scoped target and records missing evidence instead.
  capture_screen_forced() {
    local grace="$1" target="$2"
    if [[ -z "$darwin_window_id" ]]; then
      log "no capture: the run never established this window's id"
      return 1
    fi
    timeout --foreground --kill-after=5 "$grace" \
      screencapture -x -o -l "$darwin_window_id" "$target" 2>/dev/null
  }

  dismiss_panel() {
    darwin_osascript 'set frontmost to true'
    darwin_osascript 'key code 53'
  }
fi


test_args=(test "$test_target" -d "$test_device")
if (( skip_pub == 1 )); then
  test_args+=(--no-pub)
fi

(
  cd "$flutter_dir" || exit 1
  if [[ "$platform" == Linux ]]; then
    export DISPLAY="$display"
    # Force the X11 backend: without it GDK prefers the host's Wayland session
    # and the application never appears on this private display.
    export GDK_BACKEND=x11
    # Force the in-process GTK dialog instead of a desktop portal, which does
    # not exist in a bare Xvfb session.
    export GTK_USE_PORTAL=0
  fi
  export SHOSAI_SMOKE_DIR="$profile"
  export XDG_DATA_HOME="$profile/xdg-data"
  export XDG_CONFIG_HOME="$profile/xdg-config"
  export XDG_STATE_HOME="$profile/xdg-state"
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

if [[ "$platform" == Linux ]]; then
  # On macOS the count needs the application pid, which ownership establishes
  # later; the panel description records it there instead.
  app_windows="$(window_ids | wc -l)"
  log "application windows before the picker: ${app_windows:-unknown}"
fi

if [[ "$platform" == Darwin ]]; then
  # The pid is published by the application with its picker marker; wait for it
  # briefly, then refuse to drive anything that is not this run's process.
  for _ in $(seq 1 40); do
    [[ -s "$darwin_app_pid_file" ]] && break
    kill -0 "$test_pid" 2>/dev/null || break
    sleep 0.25
  done
  darwin_require_ownership
fi

panel_found=0
while (( SECONDS < deadline )); do
  if panel_present; then
    panel_found=1
    break
  fi
  kill -0 "$test_pid" 2>/dev/null || break
  sleep 0.5
done
(( panel_found == 1 )) ||
  fail "no native picker window appeared within ${timeout_seconds}s"
log "native picker panel: $(panel_description)"
if [[ "$platform" == Darwin ]]; then
  # Resolve the capture target once, while the run budget still allows the
  # System Events query, so both the normal and the teardown capture are scoped
  # to this run's own window.
  darwin_establish_window_id || true
fi
capture "picker-open"
if (( $(remaining) > 0 )); then
  if capture_screen "$artifacts/picker-dialog.png"; then
    log "screenshot: $artifacts/picker-dialog.png"
  else
    log "the dialog screenshot was not captured"
  fi
fi

dismiss_panel || log "the dismissal command reported a failure"
while (( SECONDS < deadline )); do
  panel_present || break
  sleep 0.5
done
if panel_present; then
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
