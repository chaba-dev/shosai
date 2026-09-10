import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILDER = ROOT / "scripts/build-flutter-ios.sh"
ARCHIVE_SHA256 = "90d8e7d7e6c2c27ce8634a6c99eb8a218ea63ba29781b61eb9db72c62d027546"


class FlutterIosBuildTest(unittest.TestCase):
    SCRUBBED_VARIABLES = (
        "SDKROOT",
        "MACOSX_DEPLOYMENT_TARGET",
        "IPHONEOS_DEPLOYMENT_TARGET",
        "TVOS_DEPLOYMENT_TARGET",
        "WATCHOS_DEPLOYMENT_TARGET",
        "XROS_DEPLOYMENT_TARGET",
        "DRIVERKIT_DEPLOYMENT_TARGET",
        "CC",
        "CXX",
        "CC_FOR_BUILD",
        "CXX_FOR_BUILD",
        "AR",
        "AS",
        "LD",
        "LD_FOR_BUILD",
        "NM",
        "RANLIB",
        "STRIP",
        "OBJCOPY",
        "OBJDUMP",
        "READELF",
        "CFLAGS",
        "CXXFLAGS",
        "CPPFLAGS",
        "LDFLAGS",
        "NIX_CFLAGS_COMPILE",
        "NIX_CFLAGS_COMPILE_FOR_BUILD",
        "NIX_LDFLAGS",
        "NIX_LDFLAGS_FOR_BUILD",
    )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = pathlib.Path(self.temporary.name).resolve() / "repository"
        self.scripts = self.repository / "scripts"
        self.flutter_project = self.repository / "flutter"
        self.sdk_cache = self.repository / "sdk"
        self.flutter_sdk = self.sdk_cache / "flutter"
        self.scripts.mkdir(parents=True)
        self.flutter_project.mkdir()
        (self.flutter_sdk / "bin").mkdir(parents=True)
        shutil.copy2(BUILDER, self.scripts / BUILDER.name)
        self.tools = self.repository / "tools"
        self.tools.mkdir()
        self._write_executable(
            self.tools / "uname",
            "if [ \"$1\" = -s ]; then printf 'Darwin\\n'; "
            "else printf '%s\\n' \"${TEST_UNAME_MACHINE:-arm64}\"; fi",
        )
        (self.flutter_sdk / ".shosai-archive-sha256").write_text(
            f"{ARCHIVE_SHA256}\n"
        )
        self.capture = self.repository / "capture"
        scrubbed = " ".join(
            f'"${{{variable}-unset}}"' for variable in self.SCRUBBED_VARIABLES
        )
        self._write_executable(
            self.flutter_sdk / "bin/flutter",
            f'printf \'%s\\n\' "$PWD" "$FLUTTER_ROOT" {scrubbed} "$@" > "$CAPTURE"',
        )
        self.fetch_capture = self.repository / "fetch-capture"
        self._write_executable(
            self.scripts / "fetch-ios-pdfium.sh", 'printf fetched > "$FETCH_CAPTURE"'
        )

    def tearDown(self):
        self.temporary.cleanup()

    def _write_executable(self, path, body):
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _run(self, *arguments):
        environment = os.environ.copy()
        environment.update(
            {variable: f"polluted-{variable}" for variable in self.SCRUBBED_VARIABLES}
        )
        environment.update(
            {
                "SHOSAI_FLUTTER_IOS_SDK": str(self.sdk_cache),
                "CAPTURE": str(self.capture),
                "FETCH_CAPTURE": str(self.fetch_capture),
                "PATH": f"{self.tools}:{environment['PATH']}",
            }
        )
        return subprocess.run(
            [self.scripts / BUILDER.name, *arguments],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_simulator_build_scrubs_environment_and_fetches_pdfium(self):
        result = self._run("simulator", "debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.capture.read_text().splitlines()
        self.assertEqual(values[0], str(self.flutter_project))
        self.assertEqual(values[1], str(self.flutter_sdk))
        scrubbed_end = 2 + len(self.SCRUBBED_VARIABLES)
        self.assertEqual(values[2:scrubbed_end], ["unset"] * len(self.SCRUBBED_VARIABLES))
        self.assertEqual(
            values[scrubbed_end:], ["build", "ios", "--simulator", "--debug"]
        )
        self.assertEqual(self.fetch_capture.read_text(), "fetched")

    def test_device_release_is_an_unsigned_build(self):
        result = self._run("device", "release")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.capture.read_text().splitlines()[-4:],
            ["build", "ios", "--no-codesign", "--release"],
        )

    def test_rejects_profile_simulator_build(self):
        result = self._run("simulator", "profile")

        self.assertEqual(result.returncode, 2)
        self.assertIn("debug mode only", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_rejects_intel_macos_before_downloading_arm64_sdk(self):
        os.environ["TEST_UNAME_MACHINE"] = "x86_64"
        try:
            result = self._run("simulator", "debug")
        finally:
            os.environ.pop("TEST_UNAME_MACHINE")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Apple Silicon", result.stderr)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
