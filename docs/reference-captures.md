# Reference captures (package 1B)

Deterministic, inspected **Iced reference images** for the library, import and
settings surfaces, with a provenance manifest. They are the reference the Flutter
restoration is compared against; they are not acceptance evidence for the Flutter
implementation, which produces and inspects its own renders
(`docs/flutter-ui-reference-spec.md` §4.0, `docs/flutter-ui-restoration-plan.md`
stage 1).

Package 1C (reader reference) reuses this runner; see
[Extending for package 1C](#extending-for-package-1c).

## Entry point

```sh
make reference-shots              # render every capture and write the evidence
make reference-shots VERIFY=1     # re-render, write nothing, fail on any difference
```

Both run the ignored test `reference_shots_capture` in `shosai-app`:

```sh
cargo test --package shosai-app --bin shosai reference_shots_capture -- --ignored --nocapture
```

`VERIFY=1` is the reproducibility check an accepting package can rerun: it
regenerates the fixture tree, re-renders every capture from the current code and
fails when an image hash, a capture field, a fixture byte, the committed fixture
tree or a matrix row no longer matches what is committed. Two consecutive verify
runs on the same checkout must both pass; the run prints
`N captures re-rendered byte-identically to the committed evidence`.

The rendering is in-process software rasterization (`iced_tiny_skia`), so no X
server, compositor or GPU is involved.

### Reading the recorded revision

The manifest records the working-copy commit id at render time, the Jujutsu
change id, the bookmark and the pinned design base. Jujutsu rewrites a commit id
when a change is described or committed, so the commit id is informational: the
durable mapping from the evidence to the code is the stable change id plus the
committed evidence change itself, and `make reference-shots VERIFY=1` re-renders
the evidence byte-identically at any revision carrying that change. The manifest
and the generated README repeat this note next to the revision fields.

## Outputs

Everything lives under `rfd/0004/evidence/reference-shots-1b/`:

| Path | Contents |
| --- | --- |
| `captures/*.png` | One image per capture, named `<id>.png` |
| `captures.sha256` | `sha256sum -c captures.sha256` verifies the images |
| `manifest.json` | Machine-readable provenance (see below) |
| `README.md` | Human-readable rendering of the manifest |
| `fixtures/` | The generated reference fixture tree, committed for inspection |
| `fixtures.sha256` | Verifies the committed fixture tree |

`manifest.json` records, per run:

- the entry point and command, the **capture-code revision** (exact commit, Jujutsu
  change id and bookmark, from `jj @`) and the **pinned design base**
  (`1e54270a6bb24f15630ece336a0575bdbe5be113`, #108) that the reference contract
  fixes;
- the preference baseline every state starts from, the renderer, theme, default
  font and default text size, plus the OS/arch/rustc/cargo that produced the run;
- the SHA-256 of every font the captures load;
- the generated fixture inventory (per-file SHA-256, size, redistribution
  statement) and the reused repository fixture with its verified hash;
- the seeded library inventory: profile, book count, page size, ordering,
  continue-reading entry and every seeded row;
- per capture: id, family, state id, image path, image SHA-256 and byte size,
  client size, physical image size, DPR, locale, fixture, state derivation,
  settings that differ from the baseline, covered matrix rows and notes;
- the covered / manifest-satisfied / pending acceptance rows with owners;
- the declared pixel aliases and the known limitations.

## How a capture state is produced

The runner drives the production application:

- `boot()` supplies the starting state; the initialize task it returns is dropped
  without being polled, so the real user data directory is never opened. The
  harness then dispatches `Message::Initialized(Ok(..))` built by
  `initialized_state_from_preferences` against a **disposable** store under
  `/tmp/shosai-reference-shots-1b/`, which is removed at the start and the end of
  a run (`SHOSAI_REFERENCE_SHOTS_KEEP_DATA=1` keeps it for inspection).
- Every state change comes from a production `Message` dispatched through
  `update`, and every task the application starts is driven to completion by
  `iced_runtime::task::into_stream` (or deliberately left unsettled for
  in-flight states). Nothing in the harness writes reader or library model state
  directly.
- `scenarios::assert_reached` runs before each render: the capture must be on the
  surface, in the interface language and in the state flags its rows claim,
  otherwise the run fails instead of writing a wrong image.

## Rendering fidelity

- The element is the production `app::view`; only the window is replaced by an
  offscreen `tiny_skia::Pixmap`.
- The bundled application fonts are loaded into Iced's global font system exactly
  like `iced::application(..).font(..)`, and the renderer's default font and text
  size are the application's.
- The theme is `theme::application()` and the renderer style comes from
  `iced::theme::Base::base`, which is what `iced_winit` uses for a program that
  does not override `Program::style`.
- The interface receives the same `window::Event::RedrawRequested` event the real
  `iced_winit` event loop delivers before a frame, repeated until it stops
  producing messages or layout invalidations. This is what latches widget
  interaction status, so enabled controls draw enabled and disabled controls draw
  disabled — without it every button and text input would fall back to the
  neutral style.
- Messages the view itself produces while handling that event (a visible card
  with no decoded cover asks for it) are dispatched through `update` and settled,
  and the interface tree stays alive across those frames like a real window
  keeps it.
- Window size and scale factor are set from the capture's client size and DPR,
  the values `Message::WindowEvent(.., Opened/Resized/Rescaled)` would set.

## Determinism rules

- The fixture tree is regenerated by `fixtures.rs` from code only: no clock,
  locale, random source or process state; every ZIP entry is `Stored` with the
  fixed `1980-01-01` timestamp; PDFs are written with real object offsets and a
  correct `startxref`; the set is emitted in sorted path order and hashed as
  bytes.
- Captures always read the fixture tree from the disposable data root, **not**
  from the evidence directory or a checkout path. The application renders real
  absolute paths (discovery-failure rows, the managed-library location), so a
  capture taken from a checkout path would embed a machine-specific path and stop
  reproducing. `SHOSAI_REFERENCE_SHOTS_DATA_DIR` moves that root on purpose and
  changes the bytes of the affected captures.
- The evidence directory is pruned of captures a run no longer produces, and the
  committed fixture tree is mirror-copied from the tree the captures rendered
  from and re-hashed, so a renamed capture or a partial copy cannot leave stale
  evidence behind.
- Two states that legitimately render identical pixels must be declared in
  `scenarios::PIXEL_ALIASES` with a reason. The run fails when two captures are
  byte-identical without a declaration, and also when a declared pair stops being
  identical (a stale reason). The declarations are recorded in the manifest and
  the README.

## Tests

`cargo test --package shosai-app --bin shosai reference_shots` runs the regression
tests that do not render: fixture determinism (two generations, byte-identical),
committed-hash agreement, conformant PDF cross-reference tables (with the legacy
`sample.pdf` negative control), EPUB/CBZ metadata contracts, seeded library order
and metadata, template consistency of the capture table, the pixel-alias rules in
both directions, stale-evidence pruning, fixture mirroring, and agreement between
the committed evidence and the current code.

`crates/shosai-core/tests/fixtures/sample.*` remain unverified-provenance
regression fixtures and are never overwritten by the generator.

## Extending for package 1C

1C adds reader captures to the same runner rather than a second harness:

1. add the states to `scenarios.rs` as new `Kind` variants reached by production
   messages, with the `1C-…`/`RD-…` rows they cover, a locale, a client size and
   a DPR from the specification;
2. extend `Kind::apply` to reach the state (open a document, load a page, switch
   format/mode/theme …) using the same `Harness` helpers, and extend
   `assert_reached` with the flags the new rows claim;
3. if a state cannot be reached in-process, record it under
   `matrix_rows()` `pending` with an owner and reason instead of fabricating it;
4. keep the surfaces separate: reader captures may use their own `Base` profile
   and their own disposable store, but they share the fixture generator,
   renderer, manifest, checksum and verify machinery.

Reader states are expected to need document-generation guards (a page render that
completes after the document changed must be ignored); drive them through the
same message/task path so the capture shows what a window shows.

## Coverage and limitations

`manifest.json` and the generated `README.md` list the covered rows, the rows the
manifest itself satisfies (provenance) and the pending rows with owners. The
known limitations section records what is deliberately not captured, including:

- Iced has no text scaling (`T200`), no CBZ filter entry, no tiled continuous
  render and no decision-11 tab overflow: those rows stay with the Flutter and
  renderer packages instead of being faked;
- native file/folder pickers cannot run in-process, so captures start from the
  state that follows a pick;
- the import discovery "reading" phase is a race between the hashing worker and
  the polling tick, and mid-import progress counters depend on the completion
  order of parallel copy tasks: both are captured at their deterministic points
  only;
- window decorations, native menus, toasts and animations are outside an
  offscreen frame, and the disposable data root path is visible in application
  text that names a real path.

## Environment variables

| Variable | Effect |
| --- | --- |
| `SHOSAI_REFERENCE_SHOTS_VERIFY` | `1`/non-empty: verify mode (default: capture) |
| `SHOSAI_REFERENCE_SHOTS_DIR` | Evidence output directory |
| `SHOSAI_REFERENCE_SHOTS_DATA_DIR` | Disposable data root (fixtures, seeded libraries) |
| `SHOSAI_REFERENCE_SHOTS_KEEP_DATA` | Keep the disposable data root after the run |
| `SHOSAI_REFERENCE_SHOTS_REVISION` | Override the recorded capture-code revision |
| `SHOSAI_REFERENCE_SHOTS_CHANGE_ID` | Override the recorded Jujutsu change id |
| `SHOSAI_REFERENCE_SHOTS_BOOKMARK` | Override the recorded bookmark |
| `SHOSAI_REFERENCE_SHOTS_COMMAND` | Override the recorded command |
