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

Both run the ignored test `reference_shots_capture` in `shosai-app` with the
capture environment pinned:

```sh
( font_config=$(mktemp -d) && \
  trap 'rm -rf "$font_config"' EXIT && \
  mkdir -p "$font_config/fonts" && \
  printf '<?xml version="1.0"?>\n<fontconfig>\n  <dir>%s</dir>\n</fontconfig>\n' \
    "$font_config/fonts" > "$font_config/fontconfig.xml" && \
  LANGUAGE=en-US FONTCONFIG_FILE="$font_config/fontconfig.xml" \
  cargo test --package shosai-app --bin shosai reference_shots_capture -- --ignored --nocapture )
```

The configuration is written inside a private temporary directory that the
command owns and removes: a fixed path under the checkout would be truncated by
the shell before any check could refuse a symlinked or hard-linked destination,
and `make reference-shots` uses the same private-directory shape. The snippet is
failure-chained inside a subshell with an `EXIT` trap for the same reason: if
`mktemp` fails, nothing after it runs, and the temporary directory is removed on
failure as well as on success.

The two variables are not optional. `LANGUAGE` fixes the language the captures
whose persisted preference is `System` resolve, and `FONTCONFIG_FILE` points at a
fontconfig configuration whose only font directory is empty, so the renderer can
only shape with the application fonts and Iced's built-ins. The run refuses to
start when either variable is missing, does not name a font directory, or when
the renderer's font database turns out to contain a file-backed (host) face: a
machine with different installed fonts must fail loudly instead of writing images
that do not reproduce.

The captures run on Linux. On macOS and Windows the system language does not
follow `LANGUAGE`, so the `System`-preference captures cannot be pinned there and
the run refuses to start.

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
  directory, OS, architecture, rustc/cargo versions, native PDFium identity).

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

Because the revision is exempt from the freshness comparison, it is validated
instead of compared, on both sides:

- the capture run resolves the revision **before** it renders anything and fails
  when it cannot: `jj log -r @` must succeed, or
  `SHOSAI_REFERENCE_SHOTS_REVISION` must carry a hexadecimal commit id (7–64
  characters). A missing `jj`, an empty value and a placeholder such as
  `unknown` are refusals, not recorded provenance — the run has no `git HEAD`
  fallback;
- the validator (`reference_shots::evidence`) rejects a committed manifest whose
  `capture_code_revision` is not a hexadecimal commit id, and — for a
  Jujutsu-derived manifest — one whose change id or bookmark is missing or
  `unknown`. A manifest produced through the explicit override may honestly
  record `unknown` for the descriptive fields, because its source field says so.

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
- the SHA-256 of each application font the capture loads (`InterVariable.ttf`,
  `NotoSansJP-Variable.ttf` and the math font); Iced's built-in icon font is
  pinned by the locked `iced_*` dependencies instead of being hashed here;
- the native PDFium identity the PDF covers were rasterized with (best-effort:
  the mapped library, `SHOSAI_PDFIUM_LIBRARY`, the executable directory or an
  `LD_LIBRARY_PATH` entry, with its SHA-256) and, next to it, the reason the
  generated PDFs carry no text: PDFium resolves fonts for unembedded PDF text
  itself by scanning the host font directories and does not follow
  `FONTCONFIG_FILE`, so a text run would make a cover depend on the machine;
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
- The capture environment is pinned by the entry point and asserted before
  anything is rendered (`runner::assert_capture_environment`): the no-store
  captures resolve `LanguagePreference::System` immediately, so an unpinned host
  language would silently change their language, and unpinned font discovery
  would let the machine's installed fonts change the pixels. The captures never
  mutate the environment themselves — an ordinary `cargo test` shares that
  process — they require it to be right and fail closed when it is not. Their
  `EN` locale is only recorded after `assert_reached` has compared the resolved
  interface (UI font and rendered strings) with a known English `I18n`.
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
- Font discovery is pinned by the entry point and verified in-process: the
  renderer's font database must hold only in-memory faces, so installing or
  removing host fonts cannot change a pixel. Without the pin, Iced's text stack
  would consider the machine's fonts (and its `sans-serif` aliases) for shaping
  and fallback, which is not reproducible across machines.
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
  code. A state that shows a *production* failure requires the production
  operation to fail in the capture: a fixture that cannot be created, a
  storage path that unexpectedly opens, an oversized library query that
  succeeds or an unexpected non-`Err` result fails the run, instead of
  substituting a message the application would never show that way. The only
  injected non-model input is a failure *result* delivered through the
  production message that carries it (for example
  `ManagedLibraryMovePlanned { result: Err(..) }`); the affected captures say so
  in their manifest note.

## Isolated state

Captures never touch a real library:

- the evidence entries the run writes are inspected by their own type before
  anything is created or cleared: the four metadata files and every capture image
  must be regular files and `captures/` and `fixtures/` must be real
  directories. A symlink among them is refused — following one could write the
  manifest into the disposable root that the same run deletes, or let the capture
  writes and the stale-evidence prune modify an unrelated directory — and the
  read-only validator enforces the same types, so a redirected entry cannot pass
  the self-check either;
- a file with more than one name is refused for the same reason: a hard link
  shares its inode, so truncating the evidence name would overwrite the other
  name. The preflight rejects multiply linked metadata files and capture images,
  every capture write re-checks its own destination (a link created after the
  preflight must not be written through either), the metadata destinations are
  checked again immediately before the manifest is written, and the validator
  rejects a committed metadata file or capture that is hard-linked to another
  name without opening it (the rejection names the file; that metadata or
  capture pathname is not opened);
- the multiply-linked rule is scoped to the entries a run **overwrites in
  place**: the four metadata files under the evidence root and the capture images
  under `captures/`, whose destinations are truncated and rewritten. The
  `fixtures/` tree is deliberately outside it: the read-only validator hashes
  regular fixture files in place and accepts a multiply linked one without a
  link-count diagnostic, and the capture path never truncates a committed
  fixture. It generates the tree inside the disposable root and copies it out
  with `mirror_reference_fixtures`, which removes the previous committed
  `fixtures/` directory, recreates it and copies each generated file (re-hashing
  the copy), so the most a committed tree can lose is the evidence pathname of a
  hard-linked fixture — never the contents reachable through the other name.
  Verification leaves the committed tree unchanged. The exclusive-inode
  inventory covers what the tool writes, not the material it only reads;
- those checks are **check-then-write**, not an atomic or race-proof write
  protocol: they refuse a destination that is already a link, an entry of another
  type or a multiply linked file when it is inspected, and they re-inspect at
  every write, but they do not defend against a hostile process that replaces a
  path between the inspection and the write. The threat they address is a
  misconfigured or already-prepared evidence directory, not a concurrent
  attacker;

- the disposable root must be absolute, must not overlap the evidence directory
  (in either direction), and must not be `/`, `$HOME`, the repository root, the
  evidence output root or the platform's real application data directory; a
  misconfiguration fails the run instead of deleting something;
- both the root and the evidence directory are **resolved** before they are
  compared, and the resolved evidence path is the one the run then writes,
  mirrors into, prunes and verifies: an existing component is canonicalized, so
  symlinks are followed, and `.`/`..` are applied to the *resolved* prefix — the
  way the file system applies them — so `…/link/..` is the link target's parent
  and `…/missing/../evidence` is the evidence directory even though `missing`
  does not exist yet. A spelling whose lexical form differs from its physical
  form therefore cannot pass the overlap check as one directory and be written
  or deleted as another;
- that resolution is **fallible and physical**: it walks the spelling component by
  component and fails the run when the file system cannot traverse it — a symlink
  loop, a dangling link, a final component that exists but is not a directory
  when a `..` follows it, an unreadable component, or a drive-relative spelling
  that would silently become an absolute path against the process directory. A
  spelling that cannot be resolved is never replaced by its lexical form, so a
  misconfigured evidence path or data root stops the run instead of redirecting
  writes;
- the evidence directory is resolved **once per run**, before `prepare()` clears
  the data root: the overlap check, the capture writes, the fixture mirror, the
  manifest writer and the verifier all use that one value. The data root may
  contain the very symlink the evidence configuration names, so a re-read after
  preparation would resolve to the cleared path *inside* the root — resolving
  once is what keeps the mirror and the manifest outside it;
- the root's *input* policy is enforced before that resolution: a relative root
  is refused rather than turned into an absolute path against the process
  directory, and a root that is itself a symlink is refused rather than
  dereferenced to whatever directory the link names. The final component is
  inspected without trailing separators or `.`, so `link/` and `link/.` cannot
  smuggle the symlink past the check;
- a root that is not already empty is **refused**, not cleared, unless it carries
  the marker file `.shosai-reference-shots-root` whose contents name that exact
  root; a symlink or non-directory root is refused as well;
- a second run refuses to start while `.shosai-reference-shots-lock` exists
  (created with `create_new`), so two runs cannot interleave or clear each
  other's state; the lock is removed when the run ends, on success, on failure
  and on panic;
- the lock is never released while the root is being deleted: a completed run
  renames the root aside (a sibling `.<name>-discard-<pid>` directory, so the
  rename stays on one filesystem) and deletes the renamed directory afterwards.
  A run that takes the root name in between gets a fresh root, and the rename
  target is only deleted when its marker names the root being discarded, so a
  directory that merely has the discard name — or a marker belonging to another
  root — is left untouched and fails the run;
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
- Generated PDFs draw shapes only (header band, accent bar, text-line bars and a
  page-count marker). PDFium resolves fonts for unembedded PDF text itself by
  scanning the host font directories — it does not follow `FONTCONFIG_FILE` — so
  a text run would make a rendered cover depend on the machine's installed fonts
  even though Iced's font database is pinned. `fixtures::pdf_font_free_problems`
  is checked for every generated PDF by the generator and by a regression test;
  the native PDFium identity is recorded in the manifest as run metadata.
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
  against the written tree, and the committed `fixtures.sha256` (a missing or
  unreadable checksum file fails the test rather than skipping it): the committed
  tree itself is read as regular files plus the one declared dangling symlink, so
  a socket or other special file in it is refused instead of skipped;
- conformant PDF cross-reference tables (with the legacy `sample.pdf` negative
  control), the font-free contract for every generated PDF (with a
  text-bearing-PDF negative control) and the EPUB/CBZ metadata contract,
  including that every chapter and nav document declares the same language as
  its OPF;
- seeded library order and metadata, byte-identical across two seeds;
- capture-table consistency (unique ids, 1B families, rows that exist, no
  fabricated Iced counterpart for a Flutter-only row), the `LB-03` breakpoint row
  against its required configurations (a `B760±` probe at 759, 760 and 761 in
  both interfaces, not merely a capture that references the row), the
  pixel-alias rules in both directions, stale-evidence pruning and fixture
  mirroring;
- provenance: the exact-revision resolution refuses a missing `jj`, an empty
  override, a placeholder such as `unknown` and a non-hexadecimal probe result,
  the validator rejects a committed manifest whose `capture_code_revision` is a
  placeholder (the revision is exempt from the freshness comparison, so a
  separate check is what keeps it exact), and it accepts exactly the two sources
  the writer produces: a well-formed override manifest with a synchronized README
  validates, while a source tag the writer never emits (including a padded one)
  buys no exemption and a blank, re-cased or padded change id or bookmark is
  refused;
- evidence destinations: the preflight refuses a metadata symlink into the
  disposable root, a symlinked `captures/` directory and a symlinked capture
  image without creating or modifying their targets, refuses hard-linked
  metadata and capture destinations, accepts regular destinations and missing
  ones, the write path refuses a destination that became a hard link after the
  preflight, and the validator refuses a symlinked or hard-linked metadata file
  and capture in a committed tree (each hard-link case checks that the unrelated
  name the fixture was linked to keeps its bytes, and a separate case asserts the
  hard-linked metadata is *not opened* — the sentinel may not be read as a
  checksum file), refuses a manifest capture
  path that is nested or escapes `captures/` without opening it (the escaping
  case names a FIFO with no writer, so resolving it would block, not merely
  report a missing file), reports a
  symlinked `captures/` or `fixtures/` directory without traversing it, and
  refuses a FIFO instead of opening it — those checks run on a worker thread with
  a bound, so a validator that opened the refused entry would fail the suite
  rather than hang it;
- disposable-root ownership, the exclusive lock, the protected/overlapping path
  guard including `..` (existing and missing components), a symlink followed by
  `..` in either the root or the evidence spelling, relative and symlinked
  spellings of the same location, the refusal of a relative root, of a root that
  is itself a symlink (also spelled `link/` and `link/.`, which must not be
  dereferenced or adopted), and of an evidence spelling the file system cannot
  traverse (a symlink loop, a dangling link, a file used as a directory) without
  touching the resolved or the configured location, the resolved evidence
  directory surviving the root teardown that removes the symlink it was
  configured through, the rename-aside teardown, the refusal to adopt a discard
  directory this tool did not create, and the refusal to delete one whose marker
  names a different root;
- the capture environment contract (language, font configuration, platform), the
  font-database contract, English/Japanese interface discrimination, the state
  writer fence, startup preference parsing (defaults, persisted values and
  clamping) and the production window messages; the PDFium discovery test drives
  the documented search with controlled directories and known bytes (mapped
  object over a configured path and a scan, configured-over-scan precedence, a
  configured non-file falling through to the scan, a directory scan finding a
  versioned `libpdfium.*` name among several, asserting the documented sort — a
  scan that stopped sorting would report whichever name the directory happened to
  enumerate first — and the "nothing
  found" case) rather than depending on what the host has installed, and a second
  test checks that a recorded identity on this machine names a real library whose
  hash matches the bytes;
- symlink target/type/dangling validation in every direction;
- the committed evidence against the current code, plus one mutation test per
  validator rule (missing, tampered or orphaned capture; missing, tampered or
  orphaned fixture; stale README or checksum file; changed capture row, capture
  order, alias reason, seeded inventory, seeded order, matrix row, limitation or
  font hash; missing manifest; a fresh render that differs). These tests read
  and copy the committed evidence directory, which is a **Linux artifact**: its
  fixture tree contains the dangling-symlink discovery-failure fixture and its
  manifest records `broken_symlinks_available: true`, which a Windows checkout
  cannot represent (the link becomes a regular file). They are therefore gated
  to platforms whose checkouts can hold the link (Linux and macOS); the portable
  half of the contract above runs in every `cargo test`, and `make
  reference-shots VERIFY=1` re-renders and re-checks the evidence on Linux.

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
   parameterize them or add its own entry point and **must choose its own
   evidence directory and data root**: the ownership marker and the lock are
   package-neutral, so they do not stop a later run from pruning 1B evidence or
   clearing a 1B data root that it points at. `RD-*` rows currently sit in the
   1B `matrix_rows()` pending list and belong to 1C.
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
   renderer, manifest, checksum and verify machinery — and their entry point has
   to export the pinned environment (`LANGUAGE`, `FONTCONFIG_FILE`) that
   `runner::assert_capture_environment` and the font-database check require.

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
manifest itself satisfies (provenance) and the pending rows with owners. A row's
entry is the set of captures that contribute evidence for it, so the
configuration columns of the specification can be followed through it: `LB-02`
(the compact composition) is carried by the two `C390` captures and by the three
English `B760±` probes, `LB-03` (the breakpoint) by the `B760±` probes in both
interfaces *and* by the wide captures the breakpoint switches to, and `LB-05`
(compact filter row) by the `C390` captures only. Two regression tests assert
those memberships instead of trusting the labels.

The `1B-LIB-*`, `1B-IMPORT` and `1B-SETTINGS` capture-status statements in
`docs/flutter-ui-reference-spec.md` (its introduction and §5.4) describe the state
when the plan was accepted: they name no captures and list these families as
pending. This package is what produces them; the specification is owned by the
accepting package and is not rewritten here.

The known limitations section records what is deliberately not captured, including:

- Iced has no text scaling (`T200`), no CBZ filter entry, no tiled continuous
  render and no decision-11 tab overflow: those rows stay with the Flutter and
  renderer packages instead of being faked;
- native file/folder pickers cannot run in-process, so captures start from the
  state that follows a pick;
- the generated PDF fixtures are artwork-only (no page text), because PDFium's
  font substitution for unembedded text scans the host font directories and does
  not follow `FONTCONFIG_FILE`; a PDF *reader* reference with real typography
  needs an embedded, pinned font and stays with 1C/5G rather than being faked
  here, and PDF covers are rasterized by the machine's native PDFium, whose
  identity the manifest records as run metadata;
- the import discovery "reading" phase is a race between the hashing worker and
  the polling tick, and mid-import progress counters depend on the completion
  order of parallel copy tasks: both are captured at their deterministic points
  only;
- the settings page is taller than the usual `W900` window: the reader-defaults
  card (`ST-05`) and the settings alert (`ST-06`) are the last items of the
  settings scroll column, so those captures use a taller viewport (`W900_TALL`,
  900×1200) that shows the whole page;
- the loading-more indicator and the paging row (`LB-22`) are appended after the
  book grid, so at the usual `W1280` viewport they sit below the 40-card first
  page; those two captures use `W1280_TALL` (1280×3250) so both paging states are
  visible in the same frame;
- neither viewport changes the application's layout rules: the window is simply
  tall enough for the column, because the offscreen renderer has no scroll
  interaction and the application exposes no message that scrolls those columns,
  so a taller window is the only way to show the composition without inventing a
  scroll position;
- window decorations, native menus, toasts and animations are outside an
  offscreen frame, and the disposable data root path is visible in application
  text that names a real path.

## Environment variables

| Variable | Effect |
| --- | --- |
| `LANGUAGE` | **Required.** Must be `en-US`: the language the `System`-preference captures resolve |
| `FONTCONFIG_FILE` | **Required.** Must point at a fontconfig file that names a font directory (the entry point names an empty one), so no host font is eligible |
| `SHOSAI_REFERENCE_SHOTS_VERIFY` | `1`/non-empty: verify mode (default: capture) |
| `SHOSAI_REFERENCE_SHOTS_DIR` | Evidence output directory |
| `SHOSAI_REFERENCE_SHOTS_DATA_DIR` | Disposable data root (fixtures, seeded libraries) |
| `SHOSAI_REFERENCE_SHOTS_KEEP_DATA` | Keep the disposable data root after the run |
| `SHOSAI_REFERENCE_SHOTS_REVISION` | Override the recorded capture-code revision: a hexadecimal commit id of 7–64 characters. Required when `jj` cannot name the working copy |
| `SHOSAI_REFERENCE_SHOTS_CHANGE_ID` | Override the recorded Jujutsu change id |
| `SHOSAI_REFERENCE_SHOTS_BOOKMARK` | Override the recorded bookmark |
| `SHOSAI_REFERENCE_SHOTS_COMMAND` | Override the recorded command |
