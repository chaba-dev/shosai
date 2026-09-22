"""Capture-scope controls for scripts/flutter-native-picker-smoke.sh.

On macOS there is no private display, so a capture can reach unrelated desktop
content. These controls drive the real runner with stubbed tools and assert that

* the Screen Recording preflight takes no capture at all,
* every capture is scoped to this run's own window (``-l <CGWindowID> -o``),
* a window that cannot be resolved produces missing evidence, never a capture,
* the forced teardown capture follows the same rule, and
* nothing is captured before the Accessibility preflight passes.

The stubs mean no real capture is taken and no permission prompt is raised,
whatever the host's TCC state is.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
RUNNER = REPOSITORY / "scripts" / "flutter-native-picker-smoke.sh"


def probe_source_from_runner():
    """Returns the Swift capture probe the runner embeds and compiles."""
    text = RUNNER.read_text()
    marker = "<<'SWIFT'\n"
    start = text.index(marker) + len(marker)
    end = text.index("\nSWIFT\n", start)
    return text[start:end] + "\n"


class NativePickerCaptureScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

        # The runner derives its repository root from its own path, so the
        # control runs a copy whose Flutter package is a stub directory.
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.runner = scripts / RUNNER.name
        shutil.copy2(RUNNER, self.runner)
        (self.root / "flutter").mkdir()

        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.artifacts = self.root / "artifacts"
        self.captures = self.root / "captures.log"
        self.probe_calls = self.root / "probe.log"
        self.swiftc_calls = self.root / "swiftc.log"
        self.osascript_calls = self.root / "osascript.log"
        self.dismissed = self.root / "dismissed"
        self.probe_template = self.root / "probe-template"
        for path in (
            self.captures,
            self.probe_calls,
            self.swiftc_calls,
            self.osascript_calls,
        ):
            path.write_text("")

        self._write_stubs()

    # ------------------------------------------------------------------
    # Stubs
    # ------------------------------------------------------------------
    def _write_tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -u\n" + body)
        path.chmod(path.stat().st_mode | 0o111)

    def _write_stubs(self):
        real_ps = shutil.which("ps") or "/bin/ps"
        self.probe_template.write_text(
            "#!/usr/bin/env bash\n"
            "set -u\n"
            'printf \'%s\\n\' "$*" >> "$SHOSAI_TEST_PROBE_CALLS"\n'
            'case "${1:-}" in\n'
            '  screen-recording) exit "${SHOSAI_TEST_SCREEN_RECORDING:-0}" ;;\n'
            '  system-events) exit "${SHOSAI_TEST_SYSTEM_EVENTS:-0}" ;;\n'
            "  window-id)\n"
            '    if [[ "${SHOSAI_TEST_WINDOW_ID_STALL:-no}" == yes ]]; then exec sleep 30; fi\n'
            '    if [[ "${SHOSAI_TEST_WINDOW_ID:-4242}" == none ]]; then exit 4; fi\n'
            '    printf \'%s\' "${SHOSAI_TEST_WINDOW_ID:-4242}"\n'
            "    exit 0 ;;\n"
            "  window-list)\n"
            '    printf \'%s\\n\' "${SHOSAI_TEST_WINDOW_ID:-4242} 100 200 792 404"\n'
            "    exit 0 ;;\n"
            "esac\n"
            "exit 2\n"
        )
        self.probe_template.chmod(self.probe_template.stat().st_mode | 0o111)

        # `swiftc -O -o <binary> <source>`: install the probe the control
        # configured, so the runner's capture decisions are observable. The
        # invocation is logged, because a control that asserts "not built" has to
        # observe the compile step rather than the probe's execution.
        self._write_tool(
            "swiftc",
            'printf \'%s\\n\' "$*" >> "$SHOSAI_TEST_SWIFTC_CALLS"\n'
            'out=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  case "$1" in\n'
            '    -o) out="$2"; shift 2 ;;\n'
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            '[[ -n "$out" ]] || exit 1\n'
            'cp "$SHOSAI_TEST_PROBE_TEMPLATE" "$out"\n'
            'chmod +x "$out"\n',
        )

        # The runner asks for the macOS version before either permission
        # preflight, so the control answers it on every host.
        self._write_tool("sw_vers", "printf '14.0\\n'\n")

        # Every capture is recorded before the file is written, so a control can
        # assert on the arguments even when a capture is not expected.
        self._write_tool(
            "screencapture",
            'printf \'%s\\n\' "$*" >> "$SHOSAI_TEST_CAPTURES"\n'
            'last=""\n'
            'for argument in "$@"; do last="$argument"; done\n'
            '[[ -n "$last" ]] && printf \'stub-capture\' > "$last"\n'
            "exit 0\n",
        )

        # The application under test: publishes its pid and, unless the control
        # asks it not to, the picker marker and result. It stays alive until the
        # run's own bound stops it.
        self._write_tool(
            "flutter",
            'profile="${SHOSAI_SMOKE_DIR:?}"\n'
            'mkdir -p "$profile"\n'
            'printf \'%s\' "$$" > "$profile/app-pid"\n'
            'if [[ "${SHOSAI_TEST_EXIT_BEFORE_MARKER:-no}" == yes ]]; then exit 1; fi\n'
            'if [[ "${SHOSAI_TEST_PICKER_MARKER:-yes}" == yes ]]; then\n'
            '  printf \'stub\\n\' > "$profile/picker-requested"\n'
            "  printf '%s' '{\"libraryLoaded\": true, \"dialogShown\": true, "
            "\"pickerRequested\": true, \"recovered\": true, \"exception\": null}' "
            '> "$profile/smoke-result.json"\n'
            "fi\n"
            'sleep "${SHOSAI_TEST_APP_LIFETIME:-3}"\n'
            "exit 0\n",
        )

        # System Events, answered per unix id as the runner requires. The sheet
        # and the extra window disappear when the run dismisses the panel, so the
        # runner's close check is answered realistically; a control can also keep
        # the panel open to reach the teardown path with a resolved window.
        self._write_tool(
            "osascript",
            'joined="$*"\n'
            'printf \'%s\\n\' "$joined" >> "$SHOSAI_TEST_OSASCRIPT_CALLS"\n'
            'case "$joined" in\n'
            "  *'key code 53'*)\n"
            '    [[ "${SHOSAI_TEST_DISMISSAL:-works}" == works ]] && '
            ': >"$SHOSAI_TEST_DISMISSED"\n'
            "    exit 0 ;;\n"
            "  *'count of sheets'*)\n"
            '    if [[ -f "$SHOSAI_TEST_DISMISSED" ]]; then printf \'0\\n\'; '
            "else printf '1\\n'; fi\n"
            "    exit 0 ;;\n"
            "  *'count of windows'*)\n"
            '    if [[ -f "$SHOSAI_TEST_DISMISSED" ]]; then printf \'1\\n\'; '
            "else printf '2\\n'; fi\n"
            "    exit 0 ;;\n"
            "  *'position of sheet 1'*) printf '100, 200, 792, 404\\n'; exit 0 ;;\n"
            "  *'position of window 1'*) printf '100, 200, 720, 570\\n'; exit 0 ;;\n"
            "  *'name of first process'*)\n"
            '    [[ "${SHOSAI_TEST_ACCESSIBILITY:-allowed}" == hang ]] && sleep 30\n'
            '    [[ "${SHOSAI_TEST_ACCESSIBILITY:-allowed}" == allowed ]] || exit 1\n'
            "    printf 'Finder\\n'\n"
            "    exit 0 ;;\n"
            "esac\n"
            "exit 0\n",
        )

        self._write_tool("ps", f'exec {real_ps} "$@"\n')
        self._write_tool("cargo", "exit 0\n")
        # The runner bounds every external command with GNU timeout. The real one
        # is preferred, so the controls exercise the same escalation the runner
        # relies on rather than an emulation.
        real_timeout = shutil.which("timeout")
        if real_timeout:
            self._write_tool("timeout", f'exec "{real_timeout}" "$@"\n')
        else:
            # Fallback for a host without GNU timeout: a narrow stand-in that
            # bounds a command and reports 124 the way GNU timeout does. It does
            # not reproduce GNU's escalation or its 137 after a KILL, so no
            # control claims those.
            self._write_tool(
                "timeout",
                'while [[ $# -gt 0 ]]; do\n'
                '  case "$1" in\n'
                '    --foreground) shift ;;\n'
                '    --kill-after=*) shift ;;\n'
                '    *) break ;;\n'
                '  esac\n'
                'done\n'
                'seconds="$1"; shift\n'
                '"$@" &\n'
                'child=$!\n'
                'deadline=$(( SECONDS + seconds ))\n'
                'while kill -0 "$child" 2>/dev/null && (( SECONDS < deadline )); do\n'
                '  sleep 0.1\n'
                'done\n'
                'if kill -0 "$child" 2>/dev/null; then\n'
                '  kill -TERM "$child" 2>/dev/null\n'
                '  waited=0\n'
                '  while kill -0 "$child" 2>/dev/null && (( waited < 20 )); do\n'
                '    sleep 0.1\n'
                '    waited=$((waited + 1))\n'
                '  done\n'
                '  kill -KILL "$child" 2>/dev/null\n'
                '  wait "$child" 2>/dev/null\n'
                '  exit 124\n'
                'fi\n'
                'wait "$child"\n'
                'exit $?\n',
            )

    # ------------------------------------------------------------------
    # Runner
    # ------------------------------------------------------------------
    def run_runner(self, *arguments, env=None, timeout=90):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{environment['PATH']}",
                "SHOSAI_SMOKE_PLATFORM": "Darwin",
                "SHOSAI_TEST_CAPTURES": str(self.captures),
                "SHOSAI_TEST_PROBE_CALLS": str(self.probe_calls),
                "SHOSAI_TEST_SWIFTC_CALLS": str(self.swiftc_calls),
                "SHOSAI_TEST_OSASCRIPT_CALLS": str(self.osascript_calls),
                "SHOSAI_TEST_PROBE_TEMPLATE": str(self.probe_template),
                "SHOSAI_TEST_DISMISSED": str(self.dismissed),
                "SHOSAI_TEST_ACCESSIBILITY": "allowed",
                "SHOSAI_TEST_SYSTEM_EVENTS": "0",
                "SHOSAI_TEST_SCREEN_RECORDING": "0",
                "SHOSAI_TEST_WINDOW_ID": "4242",
                "SHOSAI_TEST_APP_LIFETIME": "3",
            }
        )
        if env:
            environment.update(env)
        command = [
            str(self.runner),
            "--artifacts",
            str(self.artifacts),
            *arguments,
        ]
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
            env=environment,
        )

    def captures_taken(self):
        return [
            line
            for line in self.captures.read_text().splitlines()
            if line.strip()
        ]

    def assert_capture_is_window_scoped(self, line, expected_id="4242"):
        tokens = line.split()
        self.assertIn("-l", tokens, f"no window id in: {line}")
        window = tokens[tokens.index("-l") + 1]
        self.assertRegex(window, r"^\d+$", f"window id is not numeric in: {line}")
        self.assertEqual(
            window, expected_id, f"the capture targets another window in: {line}"
        )
        self.assertIn("-o", tokens, f"the window shadow is kept in: {line}")
        # `-S` captures the screen instead of the window even with `-l`.
        self.assertNotIn("-S", tokens, f"screen capture mode in: {line}")
        self.assertNotIn("-R", tokens, f"region capture in: {line}")

    # ------------------------------------------------------------------
    # Controls
    # ------------------------------------------------------------------
    def test_screen_recording_preflight_takes_no_capture_when_denied(self):
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_SCREEN_RECORDING": "3"},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("UNAVAILABLE: Screen Recording is not granted", result.stdout)
        self.assertEqual(
            self.captures_taken(),
            [],
            "the permission preflight must not capture anything",
        )
        self.assertTrue(
            self.probe_calls.read_text().strip(),
            "the probe answers the permission question",
        )

    def test_missing_apple_events_consent_refuses_without_prompting(self):
        # Apple Events consent for System Events is the Automation service, not
        # Accessibility. When it is missing the runner must refuse with that
        # owner action and must not run the AppleScript that would raise a
        # consent prompt.
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_SYSTEM_EVENTS": "4"},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("has not been granted Apple Events", result.stdout)
        self.assertIn("Privacy & Security -> Automation", result.stdout)
        self.assertEqual(self.captures_taken(), [])
        self.assertEqual(
            self.osascript_calls.read_text().strip(),
            "",
            "no AppleScript runs when consent is missing, so nothing prompts",
        )

    def test_nothing_is_captured_before_accessibility_passes(self):
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_ACCESSIBILITY": "denied"},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "grant Accessibility to the process running this script", result.stdout
        )
        self.assertEqual(self.captures_taken(), [])
        probe_calls = self.probe_calls.read_text()
        self.assertIn(
            "system-events",
            probe_calls,
            "the non-prompting Apple Events preflight runs before Accessibility",
        )
        self.assertNotIn(
            "window-id",
            probe_calls,
            "no capture target is resolved before Accessibility passes",
        )
        self.assertNotIn(
            "screen-recording",
            probe_calls,
            "the Screen Recording preflight waits for Accessibility",
        )

    def test_every_capture_is_scoped_to_the_run_window(self):
        result = self.run_runner("--timeout", "60")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS:", result.stdout)
        captured = self.captures_taken()
        self.assertTrue(captured, "the run captures its own picker window")
        for line in captured:
            self.assert_capture_is_window_scoped(line)

    def test_stalled_window_probe_is_bounded_and_missing_evidence(self):
        # The probe is an external process, so a stall must return through the
        # runner's own bound and missing-evidence handling instead of waiting for
        # the stall or for the supervisor to sweep the run.
        started = time.monotonic()
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_WINDOW_ID_STALL": "yes", "X_COMMAND_TIMEOUT": "2"},
            timeout=150,
        )
        elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no capture: no window owned by pid", result.stdout)
        self.assertEqual(self.captures_taken(), [])
        self.assertLess(
            elapsed,
            20.0,
            "the stalled probe must return through the runner's own bound: the "
            f"fixture stalls for 30s and the run took {elapsed:.1f}s",
        )

    def test_accessibility_timeout_does_not_prescribe_a_grant(self):
        # A command or budget expiry is not evidence of a missing permission, so
        # the runner must not tell the owner to change Accessibility.
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_ACCESSIBILITY": "hang", "X_COMMAND_TIMEOUT": "2"},
            timeout=150,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "the accessibility preflight did not finish within its", result.stdout
        )
        self.assertIn("X_COMMAND_TIMEOUT", result.stdout)
        self.assertIn("does not", result.stdout)
        self.assertIn("indicate a missing permission", result.stdout)
        self.assertNotIn("grant Accessibility", result.stdout)
        self.assertEqual(self.captures_taken(), [])

    def test_early_failure_before_ownership_records_missing_evidence(self):
        # The application exits before it publishes its picker marker, so the run
        # fails while the budget still allows a normal capture. Ownership was
        # never established, and the capture path must report that instead of
        # reaching for a window.
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_EXIT_BEFORE_MARKER": "yes"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the test exited before it requested the native picker", result.stdout)
        self.assertIn(
            "no capture: this run has not established which application it owns",
            result.stdout,
        )
        self.assertNotIn("unbound variable", result.stdout + result.stderr)
        self.assertEqual(self.captures_taken(), [])

    def test_forced_teardown_with_established_window_is_scoped(self):
        # The panel is detected and its window resolved, the application then
        # outlives the run budget, so the failure capture happens in teardown:
        # that capture must reuse the resolved window rather than the screen.
        result = self.run_runner(
            "--timeout",
            "15",
            env={"SHOSAI_TEST_APP_LIFETIME": "40"},
            timeout=180,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the test did not finish within", result.stdout)
        failure_lines = [
            line
            for line in result.stdout.splitlines()
            if "screenshot:" in line and "failure-" in line
        ]
        self.assertEqual(len(failure_lines), 1, result.stdout)
        self.assertLess(
            result.stdout.index("the test did not finish within"),
            result.stdout.index(failure_lines[0]),
            "the failure capture is taken after the run's budget expired",
        )
        teardown = [
            line for line in self.captures_taken() if "failure-" in line
        ]
        self.assertEqual(len(teardown), 1, result.stdout)
        self.assert_capture_is_window_scoped(teardown[0])

    def test_unresolved_window_is_missing_evidence_not_a_capture(self):
        result = self.run_runner(
            "--timeout",
            "60",
            env={"SHOSAI_TEST_WINDOW_ID": "none"},
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no capture: no window owned by pid", result.stdout)
        self.assertEqual(
            self.captures_taken(),
            [],
            "an unresolved window must not fall back to an unscoped capture",
        )

    def test_forced_teardown_capture_is_scoped_or_missing(self):
        # The application never requests the picker and outlives the run budget,
        # so no window id is established and the failure capture runs in
        # teardown: it must record missing evidence instead of capturing the
        # screen.
        result = self.run_runner(
            "--timeout",
            "12",
            env={
                "SHOSAI_TEST_PICKER_MARKER": "no",
                "SHOSAI_TEST_APP_LIFETIME": "30",
            },
            timeout=120,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "no capture: the run never established this window's id", result.stdout
        )
        self.assertEqual(self.captures_taken(), [])

    def test_no_unscoped_screencapture_invocation_remains(self):
        # Static guard over the whole script, so a future capture path cannot be
        # added unscoped without failing this control.
        for number, line in enumerate(RUNNER.read_text().splitlines(), start=1):
            if "screencapture" not in line:
                continue
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("prerequisites="):
                continue
            self.assertIn("-l", line, f"line {number} is not window-scoped: {stripped}")
            self.assertIn("-o", line, f"line {number} keeps the window shadow: {stripped}")
            self.assertNotIn("-S", line, f"line {number} captures the screen: {stripped}")
            self.assertNotIn("-R", line, f"line {number} captures a screen region: {stripped}")


@unittest.skipUnless(
    sys.platform == "darwin" and shutil.which("swiftc"),
    "the window match control compiles and runs the macOS capture probe",
)
class NativePickerWindowMatchTests(unittest.TestCase):
    """Controls for the probe's ownership filter and bounds match.

    The probe source the runner embeds is compiled and run against synthetic
    window records, so the matching rules are controlled without a window server
    and without capturing anything. The fully stubbed controls above install a
    probe stub, so they cannot see a missing ownership filter or a loose bounds
    check; these controls can.
    """

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.probe = self.root / "shosai-window-probe"
        source = self.root / "shosai-window-probe.swift"
        source.write_text(probe_source_from_runner())
        compiled = subprocess.run(
            ["swiftc", "-O", "-o", str(self.probe), str(source)],
            capture_output=True,
            text=True,
            check=False,
            timeout=300,
        )
        if compiled.returncode != 0:
            self.fail(f"the capture probe did not compile: {compiled.stderr}")

    def run_probe(self, *arguments):
        return subprocess.run(
            [str(self.probe), *arguments],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )

    def records(self, *lines):
        path = self.root / "records.txt"
        path.write_text("\n".join(lines) + "\n")
        return str(path)

    def test_foreign_pid_with_matching_bounds_is_ignored(self):
        records = self.records("999 41 100 200 792 404")

        result = self.run_probe(
            "window-id", "--pid", "42", "--rect", "100,200,792,404", "--records", records
        )

        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)

    def test_owned_window_matching_the_rect_is_selected(self):
        records = self.records("999 41 0 0 10 10", "42 4242 100 200 792 404")

        result = self.run_probe(
            "window-id", "--pid", "42", "--rect", "100,200,792,404", "--records", records
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "4242")

    def test_owned_window_outside_the_tolerance_is_refused(self):
        records = self.records("42 4242 100 200 792 404")

        result = self.run_probe(
            "window-id", "--pid", "42", "--rect", "110,200,792,404", "--records", records
        )

        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)

    def test_owned_window_wins_over_a_foreign_window_with_identical_bounds(self):
        # Both sources of window records pass through one ownership filter, so a
        # foreign window that matches the geometry exactly must not win.
        records = self.records("999 41 100 200 792 404", "42 4242 100 200 792 404")

        result = self.run_probe(
            "window-id", "--pid", "42", "--rect", "100,200,792,404", "--records", records
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "4242")

    def test_ambiguous_match_is_refused(self):
        records = self.records("42 4242 100 200 792 404", "42 4243 100 200 792 404")

        result = self.run_probe(
            "window-id", "--pid", "42", "--rect", "100,200,792,404", "--records", records
        )

        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("more than one window", result.stderr)

    def test_screen_recording_preflight_takes_no_capture(self):
        # The authorization answer depends on the host, so the control asserts the
        # probe's contract: an answer (allowed or denied), never a capture.
        result = self.run_probe("screen-recording")

        self.assertIn(result.returncode, (0, 3), result.stderr)


if __name__ == "__main__":
    unittest.main()
