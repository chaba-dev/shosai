#!/usr/bin/env bash
#
# Verifies the committed gen-l10n output matches the ARB catalogs.
#
# The generated `AppLocalizations` sources are committed (see `flutter/l10n.yaml`)
# so `flutter analyze` and `flutter test` work without a generation step. This
# check regenerates them and fails if the committed files would change, which is
# the localization counterpart of `check-frb-codegen.sh` and
# `check-flutter-codegen.sh`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/flutter"

hash_generated() {
  find lib/l10n -name 'app_localizations*.dart' -print0 \
    | sort -z \
    | xargs -0 sha256sum
}

before="$(hash_generated)"
flutter gen-l10n > /dev/null
after="$(hash_generated)"

if [ "$before" != "$after" ]; then
  echo "gen-l10n output is stale: run 'flutter gen-l10n' in flutter/ and commit the result" >&2
  diff <(echo "$before") <(echo "$after") || true
  exit 1
fi

echo "l10n codegen: generated files match the catalogs"
