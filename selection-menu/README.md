# Selection capsule: Apple device evidence

Not for merge. These are screenshots and a screen recording of the text-selection capsule. The build is
`claude/project-thread-v4f525-device` at `f29ad36`: main plus #268 (swatch capsule), #269 (Search
action) and #270 (one selection band per line).

| Device | OS | Build | Book | Result |
| --- | --- | --- | --- | --- |
| iPhone 15 Pro Max (physical) | iOS 27.2 | profile | Alice (EPUB) | pass |
| iPad Air 5th gen (physical) | iPadOS 27.2 | profile | Alice (EPUB) | pass |
| iPhone 18 Pro simulator | iOS 27.0 | debug | Quiet Places (PDF) | pass, recorded |

Toolchain: Xcode 27.1 and Flutter 3.41.5 (the official SDK that `scripts/build-flutter-ios.sh` uses).
The drive ran outside the nix compiler environment, as that script does.

## Files

- `iphone-sim.mp4`: the simulator recording (72 s, 1206×2622, H.264).
- `<device>-capsule-*`: a line selected, with the capsule open.
- `<device>-green-*`: after tapping the green swatch.
- `<device>-capsule2-*`: a second line selected.
- `<device>-note-*`: the note editor after tapping Note.
- `<device>-note-closed-*`: after Cancel in the note editor.
- `<device>-dismissed-*`: after a tap near the bottom of the page.
- `selection_capsule_demo_test.dart`: the demo-only driver. It imports the books into a throwaway temp
  library, so the devices' own libraries were not touched.

## Local, uncommitted build tweaks needed for these runs

- Xcode 27.1 treats an `IPHONEOS_DEPLOYMENT_TARGET` below 15.0 as an error. The Runner project and
  the Pods were raised from 13.0 (and lower) to 15.0 for this build only.
- The demo test keeps turning pages until a selection opens. On the iPhone, page 3 of Alice is still
  the contents table.
- Simulator builds must be single-architecture (`flutter drive -d <sim>`). Xcode 27's `lipo` rejects
  Flutter 3.41's two-architecture `-verify_arch arm64 x86_64` check, so
  `flutter build ios --simulator` fails.
