#!/usr/bin/env bash
set -euo pipefail

python3 website/catalog.py validate website/static/catalog
hugo --source website --minify --cleanDestinationDir
python3 website/catalog.py validate website/public/catalog
