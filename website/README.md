# Shōsai website

This directory contains the Hugo source for the Shōsai project website. It uses custom templates and CSS only—there is no theme or JavaScript dependency to install.

## Local development

From the repository root:

```sh
hugo server --source website
```

Build the production site with:

```sh
bash website/build.sh
```

The build validates the catalog before Hugo runs and again in the built site.
It fails on missing or corrupt files rather than publishing an incomplete
snapshot. The generated site is written to `website/public/` and ignored by Git.

## Catalog snapshots

`static/catalog/revisions.json` names the current and previous content revisions.
The snapshots live in `static/catalog/current/` and `static/catalog/previous/`,
each with its own `manifest.json` and 24 JSON partitions. Fixed paths keep
unchanged tables out of refresh diffs; content hashes identify the revisions,
excluding the build date. The first snapshot has no previous
revision. New snapshots retain the old current revision and remove anything
older; reverting to the previous revision also works. A date-only change does
not create a revision or a Git diff.

The revision ID is SHA-256 of the manifest's `formatVersion`, `sourceCounts`
and `files` fields encoded as UTF-8 JSON with recursively sorted keys, no
separator whitespace and ASCII-escaped strings. Clients must check this
identity and file hashes, and retry the revision index if requests cross a
deployment; the fixed URLs are not immutable.

To validate a new export and prepare it for a catalog refresh PR, run:

```sh
python3 website/catalog.py promote NEW_EXPORT_DIRECTORY website/static/catalog
```

Promotion checks the format version, complete inventory, per-file size and
SHA-256, JSON column types, SQLite keys and references, edition partitions and
source counts before changing the current pointer. A failed validation leaves
the checked-in snapshots unchanged. CI runs the same validation against both
the source assets and Hugo's output. These checks establish structural validity,
not the correctness of upstream metadata or the availability or legal status of
each candidate EPUB. Feed changes still need review before merge.

The app will fetch `/catalog/revisions.json`, validate `/catalog/current/manifest.json`
against the selected content revision, and import its JSON into a new local
SQLite database. If that fails,
it can try the previous published revision while retaining its installed
catalog. The app-side consumer and scheduled refresh PR workflow are not yet
implemented.

The initial snapshot contains 78,518 works and 157,036 candidate editions from
the official Gutenberg offline CSV, obtained from its
[ODU mirror](https://mirror.cs.odu.edu/gutenberg-epub/feeds/pg_catalog.csv.gz).
The downloaded gzip's SHA-256 is
`66847ed72335833379699bd2c3d0ae1c1180521c43d405a7ab9b28e28e1afd8e`.
Every work ID and title was compared with Python's CSV parser after the
importer's trimming of surrounding whitespace. The corresponding tools are the
[offline importer](https://github.com/chaba-dev/shosai/commit/56e1d7083c26b86fa01734190382402b9dda8756)
and [JSON exporter](https://github.com/chaba-dev/shosai/commit/ef850ac8191753d064479bdfd9d48b4ca695db81).
Gutenberg covers and book files remain upstream; this snapshot includes metadata
only and no thumbnails.

## Cloudflare Pages

Create a Pages project connected to this GitHub repository with these settings:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | `Hugo` |
| Build command | `bash website/build.sh` |
| Build output directory | `website/public` |
| Root directory | *(repository root)* |
| Node.js version | Not required |

Cloudflare Pages provides Hugo when using the Hugo framework preset. Once the custom domain is known, update `baseURL` in `hugo.toml` to its canonical `https://` URL.

Existing Pages projects must also use `bash website/build.sh` to enforce the
catalog gate in production. Committing this documentation does not change the
project's remote build settings.

### Build watch paths

To avoid deploying the site for application-only changes, go to **Settings** > **Build** > **Build watch paths** in the Pages project and configure:

| Setting | Value |
| --- | --- |
| Include paths | `website/*`, `assets/fonts/*` |
| Exclude paths | *(empty)* |

The website mounts the shared font assets from `assets/fonts`, so changes to either the Hugo source or bundled fonts must trigger a deployment.
