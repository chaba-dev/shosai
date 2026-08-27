# Shōsai

Shōsai (書斎, "study") is a native desktop ebook reader for PDF and EPUB files. It is written in Rust and uses a GPU-accelerated native interface.

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

The repository includes a Nix development environment:

```sh
nix develop
cargo run --package shosai-app
```

Alternatively, install Rust 1.94 or newer and the native dependencies required by Iced and PDFium for your platform, then run the same Cargo command.

## Development

```sh
nix develop
make lint
make test
make check-rfds
```

Development builds use an isolated `shosai-dev` application data directory;
packaged releases use `shosai`. `make dev` also sets this profile explicitly for
release-mode development runs. With the development app closed, `make reset`
recursively deletes only development state. Production data and books referenced
from their current location are preserved. An external development managed-library
folder is removed only when it contains `.shosai-storage-profile` with the exact
value `shosai-development-v1`; reset fails safely if that ownership marker is
absent or does not match.

The project is a Cargo workspace:

- `crates/shosai-core` contains document formats, library storage, and reader logic.
- `crates/shosai-app` contains the native Iced application.
- `website` contains the Hugo source for the project website.

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
