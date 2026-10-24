# Shōsai

Shōsai (書斎, "study") is an ebook reader for PDF and EPUB files. It is one Dart and Flutter application for desktop and mobile: Dart document engines and a Dart application core under a Flutter interface.

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

The repository includes a Nix development environment with Flutter and the
platform build dependencies:

```sh
nix develop
make dev                    # run the Linux host
```

`make linux-debug` builds the Linux host without running it, and
`make macos-debug`, `make android-profile` and the `ios-*` targets build the
other hosts. Without Nix, install Flutter
3.41 or newer and the native dependencies the Flutter host needs on your
platform, then run the same Make targets; the PDFium and SQLite libraries are
fetched by the Dart bindings' build hooks. `make test` also needs a PDFium
shared library named by `SHOSAI_PDFIUM_LIBRARY`, because `flutter test` does
not link native assets. See `docs/flutter-architecture.md` for how the
application is divided.

## Development

```sh
nix develop
make check
```

Debug builds of the host keep their database, preferences and managed book
copies in the platform application-support directory under the development
profile (`shosai-dev`), separate from the `shosai` directory that release builds
use.

The project is a Flutter application:

- `flutter/lib` contains the Flutter interface, the reader controllers and the PDF engine.
- `flutter/packages/shosai_epub` is the EPUB engine.
- `flutter/packages/shosai_core` is the application core: library, storage, reading state, bookmarks, annotations and search.
- `fixtures` holds the test documents the packages and the app share.
- `website` contains the Hugo source for the project website.

On Apple Silicon macOS, build the Flutter iOS host with
`make ios-simulator-debug`, `make ios-device-profile`, or
`make ios-device-release`. These targets download a checksum-pinned,
writable Flutter SDK under `target` and remove Nix compiler and SDK variables
before Xcode runs. Physical device builds are intentionally unsigned; local development
signing must be configured in Xcode before installing them.

Architecture and product proposals follow the
[Requests for Discussion process](https://chaba-rfds.pages.dev/process/);
the RFDs live in [chaba-dev/rfds](https://github.com/chaba-dev/rfds) and are
published at https://chaba-rfds.pages.dev. The
[project roadmap](docs/roadmap.org) links to the corresponding RFDs.

## Website

The public site is a dependency-free Hugo site in [`website`](website). Run it locally with:

```sh
hugo server --source website
```

See [`website/README.md`](website/README.md) for the Cloudflare Pages build configuration.

## License

Shōsai is licensed under the [Apache License 2.0](LICENSE).
