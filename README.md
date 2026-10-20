# Shōsai

Shōsai (書斎, "study") is an ebook reader for PDF and EPUB files. Its document engine and library are written in Rust; the application is a Flutter host for desktop and mobile.

## Features

- Read PDF and EPUB files
- Organize a searchable local library
- Resume reading, manage bookmarks and notes, and export bookmarks as Markdown
- Customize font size, line spacing, and light, dark, or sepia reading themes
- Search within documents and use continuous or paginated reading modes

CBZ comic support is planned for a post-launch release.

## Installation

Shōsai is currently a work in progress and has not been released yet. Follow development on [GitHub](https://github.com/chaba-dev/shosai) or watch the [Releases page](https://github.com/chaba-dev/shosai/releases) for its first release.

### Build from source

The repository includes a Nix development environment with the Rust toolchain,
Flutter, PDFium and the bridge code generator:

```sh
nix develop
make flutter-dev            # generate the bridge bindings and run the Linux host
```

`make flutter-linux-debug` builds the Linux host without running it, and
`make flutter-macos-debug`, `make flutter-android-profile` and the
`flutter-ios-*` targets build the other hosts. Without Nix, install Rust 1.94
or newer, Flutter 3.41 or newer, `flutter_rust_bridge_codegen` 2.11.1 and the
native dependencies PDFium and the Flutter host need on your platform, then run
the same Make targets. See `docs/flutter-architecture.md` for how the Flutter
host and the Rust core divide the work.

## Development

```sh
nix develop
make lint
make test
make check-rfds
```

Debug builds of the host keep their database, preferences and managed book
copies in the platform application-support directory under the development
profile (`shosai-dev`), separate from the `shosai` directory that release builds
use.

The project is a Cargo workspace with a Flutter application:

- `crates/shosai-core` contains document formats, library storage, and reader logic.
- `crates/shosai-flutter-bridge` exposes the core to Flutter through `flutter_rust_bridge`.
- `flutter` contains the cross-platform Flutter host.
- `website` contains the Hugo source for the project website.

On Apple Silicon macOS, build the Flutter iOS host with
`make flutter-ios-simulator-debug`, `make flutter-ios-device-profile`, or
`make flutter-ios-device-release`. These targets download checksum-pinned,
writable Flutter and PDFium artifacts under `target`, package PDFium
redistribution notices, and remove Nix compiler and SDK variables before Xcode
runs. Physical device builds are intentionally unsigned; local development
signing must be configured in Xcode before installing them.

Architecture and product proposals follow the
[Requests for Discussion process](rfd/README.md). The
[project roadmap](docs/roadmap.org) links to the corresponding RFDs.

## Website

The public site is a dependency-free Hugo site in [`website`](website). Run it locally with:

```sh
hugo server --source website
```

See [`website/README.md`](website/README.md) for the Cloudflare Pages build configuration.

## License

Shōsai is licensed under the [Apache License 2.0](LICENSE).
