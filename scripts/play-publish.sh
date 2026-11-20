#!/usr/bin/env bash
set -euo pipefail

track=${1:?Specify internal or production}
code=${2:?Specify the Play version code}
if ! [[ "$code" =~ ^[1-9][0-9]{0,9}$ ]] || (( code > 2100000000 )); then
  echo 'Invalid Play version code.' >&2
  exit 1
fi
case "$track" in
  internal|production) test -s "${3:?Specify the signed AAB}" ;;
  *) exit 1 ;;
esac
: "${PLAY_ACCESS_TOKEN:?Missing Play access token}"

play() {
  printf 'Authorization: Bearer %s\n' "$PLAY_ACCESS_TOKEN" |
    curl --silent --show-error --fail-with-body --max-time 600 --header @- "$@"
}
publisher=https://androidpublisher.googleapis.com
api=/androidpublisher/v3/applications/dev.shosai.reader/edits
edit=$(play -H 'Content-Type: application/json' -d '{}' "$publisher$api" | jq -er '.id | select(test("^[a-zA-Z0-9_-]+$"))')
edit_url="$publisher$api/$edit"
target=$(play "$edit_url/tracks/$track")
jq -e --arg code "$code" '
  all(.releases[]?; .status == "completed" and all(.versionCodes[]?; tonumber < ($code | tonumber)))
' <<< "$target" > /dev/null || {
  echo "Refusing to replace a newer, equal, or unfinished $track release." >&2
  exit 1
}

uploaded=$(play -H 'Content-Type: application/octet-stream' --data-binary "@$3" \
  "$publisher/upload$api/$edit/bundles?uploadType=media" | jq -er '.versionCode')
if [[ "$uploaded" != "$code" ]]; then
  echo "Play returned version code $uploaded, expected $code; not committing the edit." >&2
  exit 1
fi

release=$(jq -nc --arg track "$track" --arg code "$code" \
  '{track:$track,releases:[{versionCodes:[$code],status:"completed"}]}')
play -X PUT -H 'Content-Type: application/json' -d "$release" "$edit_url/tracks/$track"
play -X POST "$edit_url:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW"
