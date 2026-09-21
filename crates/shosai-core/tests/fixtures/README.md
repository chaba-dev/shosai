# Core test fixtures — provenance record

Engineering provenance record for the checked-in fixtures directly under
`crates/shosai-core/tests/fixtures/`. It records what is **verified** about how
these files came to be, what remains **unknown**, the license basis that can and
cannot be claimed, and what a deterministic replacement would have to preserve.

- Scope: `sample.epub`, `sample.pdf`, `sample.cbz` (`F1`–`F3` in
  [`docs/flutter-ui-reference-spec.md`](../../../../docs/flutter-ui-reference-spec.md)
  §5.1), plus the two `native-computed-style.*` inputs, plus a supporting check of
  the `epub-conformance/` font chain.
- Status: engineering record for the 1A fixture follow-up; the test-only-font
  source/version records remain with package 2C (spec §5.2).
- Recorded: 2026-09-20 on runner `framework16`, `jj 0.39.0` via `.agents/dev jj`.
- This file is a supporting record, not an owner decision. It does not itself make
  any fixture redistribution-safe; the five required fields in spec §5.2 still
  apply.

## Files covered

| File | Size | SHA-256 | Added in |
| --- | --- | --- | --- |
| `sample.epub` | 2,840 B | `57875ecbc8b9656d3671f3384d366c89182ccff43df8ed9e5fa8f631d1b4bae6` | `5b70a2293ceb54aac397f9f02da855e7ff38f6b6` — “Phase 2/epub support (#2)” |
| `sample.pdf` | 865 B | `6bc48cb51d339b242e11ed63dd257ee45f929127fb8ecf50e85d1307bf8b614d` | `117c2693809a346afd93281c4d901494671e260c` — “Phase 1 - foundation pdf viewer (#1)” |
| `sample.cbz` | 827 B | `1e184f5f978fc541757a9db748081903c6365832ba4f384da725fad0390669a5` | `223aec291fa6677a9e073c2d848cf3d1d3747c00` — “Phase 3/cbz library (#3)” |
| `native-computed-style.css` | 1,289 B | `351aa2ca637a21197ee0b5bae264b1a73e59fd313548fa5300795ded2266d9a7` | `47b50421b60dde97df7534117df2758eaa7f57f7` — “test(epub): prototype native computed styles (#29)” |
| `native-computed-style.xhtml` | 1,866 B | `0fcece708c2173612ccd40e6c15be7916f8eebc2be94f29c0d34c252a0b463b2` | `47b50421b60dde97df7534117df2758eaa7f57f7` — “test(epub): prototype native computed styles (#29)” |

The three `sample.*` hashes match spec §5.1 (`F1`–`F3`) exactly.

## Verified facts

1. **Hashes** recompute on the working copy (`sha256sum`) and match the spec
   §5.1 table.
2. **Each path has exactly one commit in the local `jj` history**, and the blob at
   that commit hashes to the working-copy SHA-256 above. The fixtures have not
   been edited since they were added:

   ```sh
   .agents/dev jj log -r 'all()' -- crates/shosai-core/tests/fixtures/sample.pdf
   .agents/dev jj file show -r 117c2693 crates/shosai-core/tests/fixtures/sample.pdf | sha256sum
   ```

3. **No generator is recorded for these files.** No script, Make target, or test
   helper produces `sample.epub`/`sample.pdf`/`sample.cbz`. The repository’s
   committed generators are
   `crates/shosai-core/tests/fixtures/epub-conformance/generate.py`,
   `benchmarks/epub-page-turn/2026-08-17/generate-fixtures.py`, and
   `crates/shosai-app/tests/fonts/generate_epub_font_fixtures.py`; none of them
   emits these fixtures. A full scan of every path that appears anywhere in the
   local `jj` history found no other fixture-generation script.
4. **Contents were inspected** (unzip listings, entry hashes, hex dumps, PNG and
   ZIP metadata). Findings are recorded per fixture below.
5. **The conformance EPUB family regenerates byte-identically** from the current
   tree with system Python 3.13.15 (see the font-chain section). It is the only
   fixture family covered here with a committed generator, and it is the only
   regeneration check performed in this record.

## sample.epub

EPUB 3.0 container, 9 entries, no archive comment, `mimetype` first and stored:

| Entry (uncompressed SHA-256) | Size | Notes |
| --- | --- | --- |
| `e468e350…f48b  mimetype` | 20 B | `application/epub+zip`, stored |
| `7ce02a13…8334  META-INF/container.xml` | 252 B | points at `OEBPS/content.opf` |
| `1b6be16f…ade2  OEBPS/content.opf` | 1,044 B | title `Sample Book`, creator `Test Author`, publisher `Shosai Press`, language `en` |
| `f9beb138…a6d1  OEBPS/toc.ncx` | 424 B | EPUB 2 TOC |
| `c31266ea…6929  OEBPS/nav.xhtml` | 378 B | EPUB 3 nav TOC |
| `d45800dc…8055  OEBPS/chapter1.xhtml` | 490 B | heading, paragraphs, `strong`/`em`, blockquote, list |
| `dc828f48…391a  OEBPS/chapter2.xhtml` | 424 B | heading, section, image reference, ordered list |
| `180553f3…daa5  OEBPS/style.css` | 114 B | three serif/margin rules; no `@font-face` |
| `4ff6ab67…80b5  OEBPS/images/cover.png` | 70 B | 1×1, 8-bit RGBA, opaque red pixel |

- ZIP metadata for every entry: `create_system` Unix, `create_version` 2.0,
  `flag_bits` 0, no extra fields, `external_attr` `0o600 << 16`. Those are the
  `zipfile.ZipInfo` defaults used when a Python `zipfile` writer emits an entry
  without explicit attributes; the archive is **consistent with** a Python
  `zipfile`-based script, but no script is recorded and the exact command is
  unknown. (It is not from `epub-conformance/generate.py`, which sets
  `create_system = 0` and `external_attr = 0o644 << 16`.)
- All entries except `mimetype` carry ZIP date `2026-03-28 14:07:20` (local time,
  2-second ZIP granularity, no timezone); `mimetype` carries `2024-01-01 00:00`.
- No embedded fonts and no third-party images or text were identified; content is
  first-party test prose and a generated 1×1 PNG.

## sample.pdf

Minimal PDF 1.4, two US-Letter pages (`MediaBox [0 0 612 792]`), uncompressed
content streams, no `/Info`, `/Producer`, `/Creator` or date metadata, LF line
endings, no binary marker comment:

- Page 1 draws `Hello World` and page 2 `Second Page` with base-14 `Helvetica`
  (font name only; no font program embedded).
- **The cross-reference table is not self-consistent.** The table starts at byte
  642 but `startxref` says 686; the listed object offsets are 9, 58, 115, 266,
  360, 441, 592 while the objects actually begin at 9, 59, 123, 253, 347, 418,
  548. Only object 1’s offset is correct. The file therefore depends on a
  reader’s xref-recovery behavior (pdfium renders it in the current tests).
- The style (hand-laid-out objects, stale cross-reference offsets, base-14 font)
  indicates a minimal hand-authored or script-assembled file, but **the authoring
  command or tool is not recorded** and must not be asserted.

## sample.cbz

ZIP archive, 5 entries, `create_system` Unix, `create_version` 2.0, no extra
fields, `external_attr` `0o600 << 16` (same Python-`zipfile`-default signature as
`sample.epub`; exact command unknown):

| Entry (uncompressed SHA-256) | Size | Notes |
| --- | --- | --- |
| `2c2eb8b2…5b89  page1.png` | 459 B | 100×150 RGB, first pixel `ff0000` |
| `36fe427d…5539  page2.png` | 459 B | 100×150 RGB, first pixel `00ff00` |
| `219ecc22…95a1  page10.png` | 459 B | 100×150 RGB, first pixel `0000ff` |
| `37663e5b…0760  ComicInfo.xml` | 12 B | literally `<ComicInfo/>` |
| `ef875a17…9e37  __MACOSX/.DS_Store` | 4 B | literally ASCII `junk` |

- ZIP dates are `2026-03-29 11:57:26` for all entries.
- The names and colors are load-bearing: `cbz_tests.rs` asserts three pages, the
  natural-sort order `page1 < page2 < page10`, the red/green/blue renders and the
  100×150 raster size, and `cbz.rs` filters `__MACOSX` entries. The `junk`
  payload is a deliberate junk-entry case, not real macOS metadata.
- No third-party art was identified; the PNGs are solid-color generated images.

## native-computed-style.css / .xhtml

Compile-time test inputs for `crates/shosai-core/src/epub/computed_style.rs`
(`include_str!`, tests only). They contain first-party fixture markup/CSS; the
`@font-face` rule references `fixture.woff2`, which does not exist on disk and is
not loaded by these tests. No generator is recorded; same unknown-authoring
limitation as the `sample.*` files.

## Provenance status

**Verified:** file identities and sizes; the adding commits; that no later commit
touched them; the contents summarized above; the absence of an in-tree generator;
the absence of identifiable third-party content by inspection.

**Unknown:** the exact generator command, tool and version for all five files; the
identity of the author beyond repository commit metadata; any explicit per-file
license or contribution statement.

**License basis:** the repository-wide `LICENSE` is Apache-2.0, and the adding
commits attribute the files to the project maintainer
(`Darwin <5746693+darwin67@users.noreply.github.com>`), so the project license is
the intended basis. However, no per-file provenance or license statement exists
in-tree, and “the content looks trivial” is **not** evidence of authorship or of
third-party absence. Until the spec §5.2 record (generator/source, deterministic
inputs, SHA-256, third-party content statement, redistribution statement) exists,
these files must be cited as **unverified provenance** and must **not** be
described as redistribution-safe.

## Recommended deterministic replacement

Origin cannot be established from the repository, so closing the record requires a
committed generator rather than a deletion or an inferred command:

1. Add `crates/shosai-core/tests/fixtures/generate.py` (naming consistent with
   `epub-conformance/generate.py`) plus a checked-in `SHA256SUMS`, emitting all
   five files deterministically: fixed ZIP timestamps, stored `mimetype`, and
   documented tool versions.
2. Either reproduce the current bytes or produce a documented replacement set.
   Do not hand-edit or regenerate in place as a drive-by change: the plan requires
   serialized ownership of fixture writes, and the current blobs are what tests
   and benchmarks pin.
3. A replacement must preserve the asserted contracts: EPUB metadata
   (`Sample Book` / `Test Author`, two spine chapters, nav + NCX, cover resource);
   PDF two pages at 612×792 with `Hello World` and `Second Page` and working
   search-highlight ranges; CBZ entry names/count/colors/100×150 sizes,
   `ComicInfo.xml`, and a `__MACOSX` junk entry.
4. A replacement PDF should be a conformant file (correct object offsets and
   `startxref`) rather than reproducing the stale xref; changing that behavior is
   a fixture change to review with the suites above, not a silent fix.
5. After the generator lands, this README should gain the generator path, its
   SHA-256, the tool versions and the redistribution statement. The spec §5.1
   citations are owned elsewhere; do not treat this README as updating them.

## Conformance font chain check (supporting)

Parent asked whether `epub-conformance/README.md` can serve as approved evidence
for its embedded fonts. Findings, without editing any font or font document:

- `generate.py` embeds fonts only from
  `crates/shosai-app/tests/fonts/epub/`, and inspection confirms the chain:
  `fonts.epub` contains `book-a.otf`
  `ae23fd1a751851a7a2fb78525e1b83ae45de8998b4dca2186ff7f8d653117239`,
  `book-a.ttf` `df9ce3d95f3055a4fcb2fa46eda9cdf2a0bf1c37676b26e97e84c8f2807c9a31`,
  `book-a.woff` `ca5d801df1aa80e05a8967ffcba563ed23f92f527500fa46d7dc5abfa50763aa`,
  `book-a.woff2` `1ce6c54df4377186df819074a1d03b9192d5d20bc89bd47d87b4d31ece81d212`,
  and `corrupt.woff2` (the `b"not a font"` sentinel from `generate.py`);
  `fonts-isolation.epub` contains `book-b.ttf`
  `cf654af96497cbe150dbd6b9d013b6322c14ea1bfcbe0f20e95be008292cae2e`. All match
  the committed files under `crates/shosai-app/tests/fonts/epub/`.
- Those font fixtures are generated by
  `crates/shosai-app/tests/fonts/generate_epub_font_fixtures.py`
  (`dcf135e196e627293fb871e1782b6e3ab3a5dedf394578140d363bc688169bb5`), which
  draws rectangle glyphs with `fontTools.fontBuilder` and reads no source font —
  there is no third-party font input in the chain. Requirements pin
  `fonttools==4.63.0`, `brotli==1.2.0`, `zopfli==0.4.3`.
- The rest of the conformance content is generated in `generate.py` (XHTML, the
  base64 1×1 PNG, `b"F" * 1 MiB` stress payloads). Regenerating with
  `python3 crates/shosai-core/tests/fixtures/epub-conformance/generate.py --output /tmp/conf-regen`
  reproduced all 15 books and `SHA256SUMS` byte-identically, so the README’s
  reproducibility claim holds today.
- Residual gaps: the conformance README does not name the font generator or its
  hash, and it records no per-file font-fixture hashes (they are listed above for
  traceability). Font-fixture regeneration determinism was **not** verified here:
  `fontTools`/`brotli`/`zopfli` are not installed in this runner and no network
  install was performed. Package 2C should verify the pinned toolchain reproduces
  the committed font bytes and then decide whether the five-field record is
  complete; until then the conformance README is supporting evidence, not an
  approved provenance record.
- The separate 2C gap for `InterVariable-Italic.ttf`, `NotoSansArabic.ttf` and
  `NotoSansHebrew.ttf` (licenses present, no upstream source/version) is **not**
  part of the conformance chain: `generate.py` never reads them. That gap does not
  contaminate the conformance family, but it remains open.

## Reproduce these checks

```sh
cd <repo root>
sha256sum crates/shosai-core/tests/fixtures/sample.epub \
          crates/shosai-core/tests/fixtures/sample.pdf \
          crates/shosai-core/tests/fixtures/sample.cbz
for f in sample.epub sample.pdf sample.cbz; do
  .agents/dev jj log -r 'all()' -- "crates/shosai-core/tests/fixtures/$f"
done
python3 crates/shosai-core/tests/fixtures/epub-conformance/generate.py --output /tmp/conf-regen
diff /tmp/conf-regen/SHA256SUMS crates/shosai-core/tests/fixtures/epub-conformance/SHA256SUMS
```

## Related records

- `docs/flutter-ui-reference-spec.md` §5.1 (`F1`–`F3` hashes), §5.2 (five-field
  fixture record and the “unverified provenance” citation rule), §7.3 item 5.
- `crates/shosai-core/tests/fixtures/epub-conformance/README.md` and
  `SHA256SUMS` (generation record and checksums for the conformance family).
- `assets/fonts/README.md` (bundled application/website fonts).
