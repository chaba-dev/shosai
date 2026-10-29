#!/usr/bin/env python3
"""Resize the supplied development icon for Android, iOS and macOS.

Run with `.agents/dev python3 scripts/resize-dev-icons.py`. The supplied
assets/shosai-dev-icon.png and existing light release icons are never changed.
macOS retains the release icon's transparent margins and rounded silhouette.
"""

import json
import pathlib
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/shosai-dev-icon.png"


def resize(source, destination, size):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if size == 1024:
        shutil.copyfile(source, destination)
    else:
        subprocess.run([
            "magick", str(source), "-resize", f"{size}x{size}",
            "-strip", str(destination),
        ], check=True)


def main():
    with tempfile.TemporaryDirectory() as temporary:
        mac_icon = pathlib.Path(temporary) / "mac-icon.png"
        subprocess.run([
            "magick", str(SOURCE), "-resize", "824x824", "-background", "none",
            "-gravity", "center", "-extent", "1024x1024", "(",
            str(ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"),
            "-alpha", "extract", ")", "-compose", "CopyOpacity", "-composite",
            "-strip", str(mac_icon),
        ], check=True)
        for platform, source in (("ios", SOURCE), ("macos", mac_icon)):
            catalog = ROOT / platform / "Runner/Assets.xcassets"
            contents = catalog / "AppIcon.appiconset/Contents.json"
            development = catalog / "AppIconDev.appiconset"
            development.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(contents, development / "Contents.json")
            for image in json.loads(contents.read_text())["images"]:
                size = round(float(image["size"].split("x")[0]) * float(image["scale"][:-1]))
                resize(source, development / image["filename"], size)
        for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                              ("xxhdpi", 144), ("xxxhdpi", 192)):
            resize(SOURCE, ROOT / f"android/app/src/dev/res/mipmap-{density}/ic_launcher.png", size)


if __name__ == "__main__":
    main()
