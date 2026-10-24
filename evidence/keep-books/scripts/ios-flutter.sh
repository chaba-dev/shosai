#!/usr/bin/env bash
# Run the repo's pinned iOS Flutter SDK outside the Nix shell (as scripts/build-flutter-ios.sh does).
flutter_root=/Users/darwin/workspace/shosai/target/flutter-ios-sdk/3.41.5/flutter
export FLUTTER_ROOT="$flutter_root"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$flutter_root/bin:/opt/homebrew/bin:$PATH"
exec env -u SDKROOT -u CC -u CXX -u LD -u CFLAGS -u LDFLAGS -u NIX_CFLAGS_COMPILE -u NIX_LDFLAGS \
  "$flutter_root/bin/flutter" "$@"
