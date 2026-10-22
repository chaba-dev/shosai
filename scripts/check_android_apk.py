#!/usr/bin/env python3
"""Verify that an Android APK carries the host's native libraries for every ABI.

The host filters no ABI, and SQLite and PDFium come from their packages' build
hooks, so a universal APK must carry Flutter's engine, the AOT snapshot,
`libpdfium.so` and `libsqlite3.so` under every ABI Flutter builds for release.
A device run exercises only its own ABI, so this checks the archive itself.

Usage:

    python3 scripts/check_android_apk.py <apk>...

Exit codes: 0 when every APK validates, 1 otherwise.
"""

from __future__ import annotations

import argparse
import sys
import zipfile

# Flutter's release ABIs (it builds no 32-bit x86 in release mode).
ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")

LIBRARIES = ("libflutter.so", "libapp.so", "libpdfium.so", "libsqlite3.so")


def check(apk: str) -> list[str]:
    try:
        with zipfile.ZipFile(apk) as archive:
            sizes = {info.filename: info.file_size for info in archive.infolist()}
    except (OSError, zipfile.BadZipFile) as error:
        return [f"{apk}: unreadable: {error}"]
    return [
        f"{apk}: lib/{abi}/{library} is missing or empty"
        for abi in ABIS
        for library in LIBRARIES
        if not sizes.get(f"lib/{abi}/{library}")
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("apks", nargs="+", help="APK files to check")
    apks = parser.parse_args().apks
    failures = [failure for apk in apks for failure in check(apk)]
    if failures:
        for failure in failures:
            print(f"android-apk-check: {failure}", file=sys.stderr)
        return 1
    print(f"android-apk-check: {len(apks)} APK(s) validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
