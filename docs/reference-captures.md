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

Everything that does **not** need a render runs in an ordinary `cargo test`:
`reference_shots::tests::committed_evidence_matches_current_code` uses the same
validator (`reference_shots::evidence`) as `VERIFY=1`. It

- enumerates the committed evidence (exactly the four files and two directories),
  so a missing or unexpected file fails instead of being skipped;
- hashes every committed PNG against the committed manifest entry (both the
  SHA-256 and the byte size) and rejects images the manifest does not list;
- recomputes `captures.sha256`, `fixtures.sha256` and the generated `README.md`
  from the committed manifest;
- compares the committed fixture tree, file by file, with the tree the generator
  produces now, including the declared dangling symlink;
- compares every deterministic manifest field (package, entry point, revision
  note, pinned base, preference baseline, fonts, fixture inventory, seeded
  library, capture rows in order, pixel aliases, matrix mapping, limitations,
  renderer/theme/font/text-size of the environment block) and exempts only run
  metadata (capture-code revision, change id, bookmark, command, output
  directory, OS, architecture, rustc/cargo versions).

`VERIFY=1` adds one thing on top: it re-renders every capture and fails when a
pixel hash or byte size changed. The validator is one implementation shared by
the test and the verify run, so a rendered and an unrendered check cannot drift.

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

- `boot()` supplies the starting state exactly as the application builds it; the
  initialize task it returns is dropped without being polled, so the real user
  data directory is never opened. The harness then dispatches
  `Message::Initialized(Ok(..))` built by `reference_shots::seed::capture_initialized_state`
  against a **disposable** store under `/tmp/shosai-reference-shots-1b/`. That
  function contains the same preference parsing `boot`'s initialization performs,
  so the capture state is the state a real start with these preferences produces
  while production `boot()` stays untouched.
- The capture process pins the system locale before the runtime starts
  (`LANGUAGE=en-US`): the no-store captures resolve
  `LanguagePreference::System` immediately, so an unpinned host locale would
  silently change their language. Their `EN` locale is only recorded after
  `assert_reached` has compared the resolved interface (UI font and rendered
  strings) with a known English `I18n`.
- Every state change comes from a production `Message` dispatched through
  `update`, and every task the application starts is driven to completion by
  `iced_runtime::task::into_stream` (or deliberately left unsettled for
  in-flight states). Nothing in the harness writes reader or library model state
  directly. Window size and scale factor are applied with the production
  `Message::WindowEvent(.., Resized)` / `(.., Rescaled)` messages, including the
  layout invalidation and generation bump they cause, and are asserted before the
  scenario, after it and after the render.
- Between captures the harness fences the state writer with the production
  `quiesce_and_shutdown` (`reference_shots::runner::fence_capture_writes`):
  dropping a writer task is not a barrier for preference writes that are already
  queued, and every capture resets the same store, so an unfenced write could land
  in the next capture's baseline.
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
- The capture drives the application's own `update`, so every visible field —
  banners, disabled states, counts, progress labels — is computed by production
  code. The only injected non-model input is a failure *result* delivered through
  the production message that carries it (for example
  `ManagedLibraryMovePlanned { result: Err(..) }`); the affected captures say so
  in their manifest note.

## Isolated state

Captures never touch a real library:

- the disposable root must be absolute, must not overlap the evidence directory
  (in either direction), and must not be `/`, `$HOME`, the repository root, the
  evidence output root or the platform's real application data directory; a
  misconfiguration fails the run instead of deleting something;
- a root that is not already empty is **refused**, not cleared, unless it carries
  the marker file `.shosai-reference-shots-root` that a previous run of this tool
  wrote; a symlink or non-directory root is refused as well;
- a second run refuses to start while `.shosai-reference-shots-lock` exists
  (created with `create_new`), so two runs cannot interleave or clear each
  other's state; the lock is removed when the run ends, on success, on failure
  and on panic;
- the root is removed at the end of a completed run unless
  `SHOSAI_REFERENCE_SHOTS_KEEP_DATA=1` keeps it for inspection (a panicking run
  leaves it behind for debugging and only releases the lock).

The seeded rows live in a disposable store inside that root; the imported books
of the completed-import capture are copied into a disposable managed directory
inside it.

## Determinism rules

- The fixture tree is regenerated by `fixtures.rs` from code only: no clock,
  locale, random source or process state; every ZIP entry is `Stored` with the
  fixed `1980-01-01` timestamp; PDFs are written with real object offsets and a
  correct `startxref`; the set is emitted in sorted path order and hashed as
  bytes.
- The dangling symlink fixture is a **relative** link to `missing-target.epub`
  (an absolute target would embed the checkout path in the committed tree). Every
  tree is checked for exactly that link: an unexpected symlink, a wrong target and
  a link that resolves to an existing file are all failures, and the run records
  whether the platform could create the link at all.
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
tests that do not render. They fail when a fixture byte, a fixture order, a
fixture hash, a metadata field, a seeded row, a capture row, a matrix mapping, a
font hash, the README or a checksum file stops agreeing with the code — and they
contain a negative test per failure mode, so a validator that silently stopped
checking would fail the suite:

- fixture determinism (two generations, byte-identical), the in-memory generator
  against the written tree, and the committed `fixtures.sha256`;
- conformant PDF cross-reference tables (with the legacy `sample.pdf` negative
  control) and the EPUB/CBZ metadata contract, including that every chapter and
  nav document declares the same language as its OPF;
- seeded library order and metadata, byte-identical across two seeds;
- capture-table consistency (unique ids, 1B families, rows that exist, no
  fabricated Iced counterpart for a Flutter-only row), the pixel-alias rules in
  both directions, stale-evidence pruning and fixture mirroring;
- disposable-root ownership, the exclusive lock, and the protected/overlapping
  path guard;
- the pinned system locale, English/Japanese interface discrimination, the state
  writer fence, startup preference parsing (defaults, persisted values and
  clamping) and the production window messages;
- symlink target/type/dangling validation in every direction;
- the committed evidence against the current code, plus one mutation test per
  validator rule (missing, tampered or orphaned capture; missing, tampered or
  orphaned fixture; stale README or checksum file; changed capture row, capture
  order, alias reason, seeded inventory, seeded order, matrix row, limitation or
  font hash; missing manifest; a fresh render that differs).

`crates/shosai-core/tests/fixtures/sample.*` remain unverified-provenance
regression fixtures and are never overwritten by the generator.

## Extending for package 1C

1C adds reader captures to the same runner rather than a second harness. The
integration points that are deliberately 1B-only today:

1. `scenarios::Surface` knows only `Library` and `Settings`; a reader surface
   needs its own variant (and the `Screen`/label mapping) before a reader state
   can be asserted as reached.
2. `manifest::PACKAGE_1B_FAMILIES` and the `capture_table_is_consistent` test
   restrict families to the 1B set; a 1C package must add its own allowed-family
   set and its own output label instead of widening 1B's.
3. `runner::DEFAULT_OUTPUT`, `runner::DEFAULT_DATA_ROOT`, the manifest `package`
   field and the generated README title are hard-coded for 1B. 1C must
   parameterize or add its own entry point: reusing the 1B evidence directory or
   data root would fail the ownership/lock guard on purpose, and `RD-*` rows
   currently sit in the 1B `matrix_rows()` pending list and belong to 1C.
4. add the states to `scenarios.rs` as new `Kind` variants reached by production
   messages, with the `1C-…`/`RD-…` rows they cover, a locale, a client size and
   a DPR from the specification;
5. extend `Kind::apply` to reach the state (open a document, load a page, switch
   format/mode/theme …) using the same `Harness` helpers, and extend
   `assert_reached` with the flags the new rows claim;
6. if a state cannot be reached in-process, record it under `matrix_rows()`
   `pending` with an owner and reason instead of fabricating it;
7. keep the surfaces separate: reader captures may use their own `Base` profile
   and their own disposable store, but they share the fixture generator,
   renderer, manifest, checksum and verify machinery.

Two harness limits matter for reader work:

- `Harness::settle` delivers only `iced_runtime::Action::Output(message)` and
  silently skips every other runtime action; a reader state that depends on a
  stream/future/task action must handle it explicitly rather than assuming it ran.
- `SETTLE_LIMIT` counts delivered messages; it is not a timeout. A task that never
  finishes hangs the run instead of failing it, so reader states that wait on a
  real render or a platform event need a bounded driver.

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
- the settings alert (`ST-06`) is the last child of the settings scroll column, so
  its capture uses a taller viewport (`W900_TALL`, 900×1200) to show the real
  banner: the renderer has no scroll interaction and the application exposes no
  message that scrolls that column, so a taller window is the only way to show the
  composition without inventing a scroll position;
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
