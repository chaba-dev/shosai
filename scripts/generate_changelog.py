#!/usr/bin/env python3
"""Render git-cliff history with a permanent, v0.1.0-only display baseline."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


# The Rust core was removed here. Earlier work remains in Git and version
# calculation, but is not part of the first Flutter release's changelog.
BASELINE = "4613c6abbebdf93770776eceaaf039c2a5c217e1"


def main():
    if len(sys.argv) > 1:
        releases = json.loads(Path(sys.argv[1]).read_text())
    else:
        releases = json.loads(subprocess.check_output(["git-cliff", "--context"], text=True))
    for release in releases:
        if release["version"] == "v0.1.0":
            earlier = set(subprocess.check_output(["git", "rev-list", BASELINE], text=True).splitlines())
            release["commits"] = [commit for commit in release["commits"] if commit["id"] not in earlier]
    with tempfile.TemporaryDirectory() as temporary:
        context = Path(temporary) / "context.json"
        context.write_text(json.dumps(releases))
        subprocess.run(["git-cliff", "--from-context", str(context), "--output", "CHANGELOG.md"], check=True)


if __name__ == "__main__":
    main()
