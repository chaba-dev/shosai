# Reference captures (packages 1B and 1C)

Deterministic, inspected **Iced reference images** for the library, import,
settings and reader surfaces, each with a provenance manifest. They are the
reference the Flutter restoration is compared against; they are not acceptance
evidence for the Flutter implementation, which produces and inspects its own
renders (`docs/flutter-ui-reference-spec.md` §4.0, `docs/flutter-ui-restoration-plan.md`
stage 1).

Two packages share one runner, one fixture generator and one validator, and each
writes its own evidence directory:

| Package | Surfaces | Evidence families | Evidence directory |
| --- | --- | --- | --- |
| 1B | Library, import, settings | `1B-LIB-*`, `1B-IMPORT`, `1B-SETTINGS` | `rfd/0004/evidence/reference-shots-1b/` |
| 1C | Reader chrome, panels, formats and modes | `1C-RD-CHROME`, `1C-RD-PANEL`, `1C-SPREAD`, `1C-EPUB-PAG`, `1C-EPUB-CONT`, `1C-PDF-PAG`, `1C-PDF-CONT`, `1C-CBZ-PAG`, `1C-CBZ-CONT` | `rfd/0004/evidence/reference-shots-1c/` |

## What these images are evidence for, and what they are not

A `1B-*`/`1C-*` capture is the **reference** for a row: it records what Iced
renders for a state, so a later package knows what it is rebuilding. It is never
the acceptance evidence for that row. Every accepting package renders and
inspects its own states at the row's configuration and runs its own behavior
checks (specification §4.0 rules 1–3), and a row whose authority is not Iced —
`Owner`, `RFD 6`, `Retained Flutter`, `Plan contract` — cannot be satisfied by a
capture here at all. The reader rows that fall in that class are named in the
package 1C manifest under `non_iced_authority` and listed as `pending` in its
matrix, with the owning package; no image is fabricated for them.

Two consequences worth stating plainly, because both are easy to misread from a
directory of PNGs:

- **Coverage is not acceptance.** A row appearing in a package's `captured`
  matrix means a capture *renders that state*; the row's accepting package still
  has to produce and inspect its own render and its own tests. The matrix in
  each manifest records the accepting package's ownership through the row ids
  the reference specification assigns, not a claim that the row is done.
- **A capture can be comparison-only.** `rd-spread-large-font-bf32-w1280-en` and
  `rd-spread-large-font-bf48-w1280-en` show what Iced does at large book fonts
  (it keeps the width-only spread rule and never falls back). Decision 12
  replaces that behavior in the Flutter reader, so those images are recorded as
  comparison and `FM-11`/`FM-12` stay pending with 5A/5B/5H.

## Entry point

```sh
make reference-shots              # render every capture of both packages and write the evidence
make reference-shots VERIFY=1     # re-render both, write nothing, fail on any difference
```

`SHOSAI_REFERENCE_SHOTS_PACKAGE=1b` or `=1c` restricts a run to one package (an
unknown value is refused rather than ignored). The default runs both, so the
documented command produces every reference set in one pass.

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

**Resolving the recorded change id.** The manifest and the README tell a reader
to resolve `capture_code_change_id`, and the command they name is the one this
evidence was produced with, run under the pinned Jujutsu (`jj 0.39.0`, the
version the dev shell provides):

```sh
jj log --no-graph -r 'change_id(<change id>)' \
  -T 'commit_id.short() ++ " " ++ change_id ++ " " ++ description.first_line() ++ "\n"'
```

`change(<id>)` is **not** a Jujutsu revset function — `jj log -r 'change(<id>)'`
fails with `Function 'change' doesn't exist` — so the note must not name it. The
`change_id()` form was executed against the workspace that produced this
evidence, and the two forms' behavior is checked by the regression test
`recorded_revision_lookup_is_a_real_jujutsu_command`.

## Outputs

Each package writes the same six entries into its own evidence directory
(`rfd/0004/evidence/reference-shots-1b/`, `rfd/0004/evidence/reference-shots-1c/`):

| Path | Contents |
| --- | --- |
| `captures/*.png` | One image per capture, named `<id>.png` |
| `captures.sha256` | `sha256sum -c captures.sha256` verifies the images |
| `manifest.json` | Machine-readable provenance (see below) |
| `README.md` | Human-readable rendering of the manifest |
| `fixtures/` | The generated reference fixture tree, committed for inspection |
| `fixtures.sha256` | Verifies the committed fixture tree |

The two packages share the fixture tree: package 1C adds no fixture of its own,
so its `fixtures/` copy is byte-identical to package 1B's and the accepted 1B
fixture bytes are untouched by 1C work.

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
- the native PDFium identity the PDF pages were rasterized with (best-effort:
  the mapped library, `SHOSAI_PDFIUM_LIBRARY`, the executable directory or an
  `LD_LIBRARY_PATH` entry, with its SHA-256) and, next to it, the reason the
  generated PDFs carry no text: PDFium resolves fonts for unembedded PDF text
  itself by scanning the host font directories and does not follow
  `FONTCONFIG_FILE`, so a text run would make a cover or a page depend on the
  machine;
- the generated fixture inventory (per-file SHA-256, size, redistribution
  statement) and the reused repository fixture with its verified hash;
- the seeded library inventory: profile, book count, page size, ordering,
  continue-reading entry and every seeded row;
- per capture: id, family, state id, image path, image SHA-256 and byte size,
  client size, physical image size, DPR, locale, fixture, state derivation,
  settings that differ from the baseline, covered matrix rows and notes;
- package 1C only: a per-capture `reader` block — the document, format, reading
  mode, the raster zoom mode (`fit-page`, `fit-width`, `manual(<scale>)`, or
  `n/a` when no raster document is open), palette,
  page count, current location, the visible pages and whether they
  form a spread, the available reader size the layout ran at, the book font and
  line spacing, the open panels, and the saved-place, search-match and tab
  counts. The runner compares it with the state it actually reached and fails
  instead of writing an image whose manifest would describe a state it never
  showed;
- the covered / manifest-satisfied / pending acceptance rows with owners, and a
  `reason` on any covered row whose reference coverage is deliberately partial
  (package 1C: `FM-01`, `FM-02`, `FM-13` and `RD-06`, each naming what no image
  covers);
- package 1C only: the `non_iced_authority` records for the rows Iced cannot
  evidence at all (selection and highlighting above all);
- the declared pixel aliases and the known limitations.

### Run metadata, and why some fields are exempt

`evidence::problems` compares the committed manifest with a manifest built from
the current code field by field, and deliberately **exempts run metadata** —
`capture_code_revision`, `capture_code_revision_source`, `capture_code_change_id`,
`capture_code_bookmark`, `command`, `output_directory`, `environment.os`,
`environment.arch`, `environment.rustc`, `environment.cargo` and
`environment.pdfium`. Those fields describe the machine and the checkout that
produced the evidence, not the code, so a verification run on another machine
must not fail on them.

`output_directory` is recorded as an **absolute** path (the run resolves it once
and never re-reads the configuration), and it is run metadata for exactly that
reason: two reviewers verifying the same evidence from different checkouts see
different absolute paths and the same images. The per-capture `image` path stays
relative to the manifest, and the capture and fixture checksum files are relative
to the evidence directory, so the committed set is portable even though the
recorded output path is not.

`capture_code_revision` is exempt but **validated**, not ignored: the writer
refuses to render without an exact revision and the validator rejects a
committed manifest whose revision is not a hexadecimal commit id (see
[Reading the recorded revision](#reading-the-recorded-revision)).

## How a capture state is produced

The runner drives the production application:

- `boot()` supplies the starting state exactly as the application builds it; the
  initialize task it returns is dropped without being polled, so the real user
  data directory is never opened. The harness then dispatches
  `Message::Initialized(Ok(..))` built by `reference_shots::seed::capture_initialized_state`
  against a **disposable** store under the package's own data root
  (`/tmp/shosai-reference-shots-1b/`, `/tmp/shosai-reference-shots-1c/`). That
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

### Colour order and the 1B rebaseline

`iced_tiny_skia` builds every `tiny_skia::Color` in **BGRA** byte order
(`engine::into_color` calls `from_rgba(color.b, color.g, color.r, color.a)`),
because the compositor presents into `softbuffer`'s `u32` buffer and the window
path unpacks that buffer with explicit channel masks. The capture renderer
encodes a `tiny_skia::Pixmap` as an RGBA PNG, so encoding it directly wrote every
pixel with red and blue exchanged: the application accent `#4D5E86` was recorded
as the brown `#865E4D` the design rejects, and the sepia palette read as pale
blue. The renderer now swaps the two channels back before encoding
(`reference_shots::render::encode_rgba_png`), and
`reference_shots::tests::rendered_pixels_carry_the_application_colors` renders the
production library view and checks the recorded bytes against the palette tokens,
so a channel-order regression fails in an ordinary `cargo test`.

**This re-encoded every committed package 1B capture.** The 1B capture set,
states, client and image sizes, DPR, locales, settings, fixture inventory, fonts,
seeded library, matrix and limitations are unchanged. The only differences from
the accepted 1B manifest are each image's `sha256`/`bytes`, the
`capture_code_note` (the corrected `change_id(<id>)` command, which is a code
change rather than a pixel one) and the run metadata the validator exempts
(capture revision, change id, bookmark, command, output directory). Every
deterministic field was compared against the accepted revision to confirm that,
and the corrected images were re-inspected. Package 1B was already accepted, so
the rebaselined 1B evidence is called out to the owner in the pull request
instead of being treated as a silent side effect of 1C work; the previously
accepted bytes remain in the accepted merge `565187cff25e` and in `main@origin`
history for comparison.

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
  once is what keeps the mirror and the manifest outside it. The same holds for
  the disposable data root: both packages' roots are resolved and cross-checked
  before anything runs, each package then runs on those resolved values, and a
  data-root spelling whose resolution changed after the preflight (a link
  another package's preparation removed) is a refusal rather than a write to a
  directory no check covered;
- before anything is created, cleared or written, both packages' evidence
  directories and disposable roots are resolved and cross-checked: equal or
  nested locations (evidence versus evidence, data versus data, or one inside the
  other) are refused, and a directory whose existing `manifest.json` names another
  package is refused as well. That ownership read never opens an entry the writer
  would not have produced — a symlink, a FIFO, a hard-linked file, unreadable
  text, invalid JSON and a manifest without a `package` field are all refusals,
  because a damaged marker is not permission to overwrite the directory;
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
- the committed evidence against the current code **for every package**, plus one
  mutation test per validator rule (missing, tampered or orphaned capture;
  missing, tampered or orphaned fixture; stale README or checksum file; changed
  capture row, reader fact, capture order, alias reason, seeded inventory, seeded
  order, matrix row, limitation or font hash; missing manifest; a fresh render
  that differs). The reader-fact mutation is the negative control for the 1C
  `reader` block: without it the always-on check would still pass if a capture's
  reader facts were compared against nothing. These tests read
  and copy the committed evidence directory, which is a **Linux artifact**: its
  fixture tree contains the dangling-symlink discovery-failure fixture and its
  manifest records `broken_symlinks_available: true`, which a Windows checkout
  cannot represent (the link becomes a regular file). They are therefore gated
  to platforms whose checkouts can hold the link (Linux and macOS); the portable
  half of the contract above runs in every `cargo test`, and `make
  reference-shots VERIFY=1` re-renders and re-checks the evidence on Linux.

`crates/shosai-core/tests/fixtures/sample.*` remain unverified-provenance
regression fixtures and are never overwritten by the generator.

## Package 1C: the reader captures

1C reuses this runner rather than adding a second harness. What it adds:

- `reader::ReaderKind` describes each reader state (a paginated EPUB page, a
  continuous column, a raster page, a panel, a tab set, the opening composition,
  a failure alert, a palette, a large book font) and `reader::apply` reaches it
  through production messages only: `Message::OpenLibraryBook` on a seeded book,
  then page navigation, `Message::ToggleReadingMode`, the panel toggles,
  `Message::ToggleBookmark`, the note editor, the search query through its
  debounce, `Message::CycleTheme` and `Message::FontSizeUp`.
- `reader::ReaderFacts` is the declared state of a capture — document, format,
  mode, palette, page count, location, visible pages, spread, available reader
  size, book font, line spacing, panels, saved places, search matches and tabs.
  The runner compares it with the state it actually reached and fails rather
  than writing an image whose manifest would describe a state it never showed.
  A regression test pins the specification's arithmetic and pairing rule as
  literal expected values, then recomputes every declaration from its own client
  size and panel state and re-paginates every fixture with the core paginator, so
  the declarations are checked against the contract instead of against a previous
  observation.
- `package::Package` separates the two evidence sets: their own evidence
  directory, their own disposable data root, their own allowed families, their
  own capture table, their own matrix and their own limitations. The ownership
  marker and the lock are package-neutral, so this separation is what stops a
  1C run from pruning 1B evidence or clearing the data root 1B's captures were
  rendered from.
- `Surface::Reader` and the `reader` state id let `assert_reached` verify the
  screen, the interface language and the reader facts before a render.
- The reader package clears the durable reader state (reading positions and
  saved places) in its disposable store before every capture, because the
  application persists both: without it a capture that turned to page 4 would
  decide where the next capture of the same book opens, and the saved-place
  captures would see each other's bookmarks. The reset touches the disposable
  store only, exactly like the preference baseline; the reader model is still
  driven by production messages alone.

### The harness had to grow two capabilities

Both are general, and both are documented because they change what a capture can
show:

- **Widget operations are executed.** `Harness::settle` used to deliver
  `iced_runtime::Action::Output` and skip everything else. The reader's
  continuous mode resolves its scroll position with a widget operation
  (`ContinuousItemOperation::resolve`), so `render::operate` now applies an
  `Action::Widget` to an interface built from the same state and view, the way
  `iced_winit` applies it to the live one, including the operation `finish()`
  chains. Without it the continuous captures could not settle at all.
- **A capture may take more than one frame round.** `iced_winit` bounds the
  redraw events per message batch, but its event loop then dispatches the
  messages and draws again. The reader publishes messages per frame while its
  chapter sensors and scroll viewport converge, so the harness has an outer
  round bound (`MAX_FRAME_ROUNDS`) as well as the inner one. A capture that
  never settles still fails instead of looping.

### Non-Iced authority

Iced has no production interactive selection or highlighting, so `RD-12`,
`FM-16` and `FM-17` have no capture here at all. Their authority is RFD 6 plus
the retained Flutter implementation, owned by 4D/5I, and the package 1C manifest
records that in `non_iced_authority` next to the pending matrix rows. The same
section records the other rows Iced cannot evidence (tab overflow, keyboard
reachability, large-text inspection, the decision-12 fallback, tiled continuous
seams, mode-switch position preservation and resource-rejection
distinguishability) with their owning packages.

### Reader fixtures

Package 1C adds no fixture of its own. The shared generated tree already carries
the multi-chapter English and Japanese EPUBs, a four-page and a two-page
artwork-only PDF and a twelve-page and a three-page CBZ that the reader captures
open, and the reused conformance EPUB stays in the tree for the other packages.
Which fixture each capture uses is recorded per capture in the manifest.

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

The `1B-LIB-*`, `1B-IMPORT`, `1B-SETTINGS` and `1C-*` capture-status statements
in `docs/flutter-ui-reference-spec.md` (its introduction and §5.4) describe the
state when the plan was accepted: they name no captures and list these families
as pending. These packages are what produce them; the specification is owned by
the accepting package and is not rewritten here.

The package 1C matrix is the one to read for reader coverage. It records the
`RD-*` rows a capture renders, the `FM-*` rows a capture renders, and — with the
owning package — every reader row this package does **not** cover: `RD-04`
(decision-11 tab overflow), `RD-12` (selection), `RD-13` (panel exclusivity, a
behavioral row), `RD-14`, `RD-15`, `FM-11`, `FM-12`, `FM-14`, `FM-15`, `FM-16`,
`FM-17`, `FM-18`, `FM-19` and `FM-20`. The rows whose authority is not Iced at
all are also recorded in `non_iced_authority`, with the authority that owns them.

`FM-18` (EPUB pages keep document colours through compositing) is pending with
5G even though `1C-EPUB-PAG` is the family the specification assigns to it: the
row's acceptance is plan 5G's, and 1C renders no document-colour fixture of its
own. The `1C-EPUB-PAG` captures are its Iced reference, not its acceptance
evidence.

Four covered rows carry a `reason` saying that their reference coverage is
deliberately partial, so the row id alone is not read as complete coverage:

- `FM-01`: the generated fixtures carry headings and body text, so the row's
  styled text and page number are referenced; its lists, quotes and links need
  the reused conformance fixture, which the Iced reader cannot render under the
  pinned font environment (see the rich-fixture limitation), and acceptance
  stays with 5G;
- `FM-02` and `FM-13`: the raster pages and spreads are referenced at fit-page
  (`rd-pdf-pag-w1280-en`, `rd-spread-pdf-w1280-en`, `rd-spread-cbz-w1280-en`,
  `rd-cbz-pag-w1280-en`) and `rd-pdf-fit-width-w1280-en` adds a PDF fit-width
  spread; manual zoom is stepwise (`Message::ZoomIn`/`ZoomOut` from the current
  fit scale, which is derived from the document's page size) and is not captured
  at all, and there is no CBZ fit-width capture, so both are left to the
  accepting package;
- `RD-06`: the enabled and disabled edge-navigation states are referenced; hover
  needs a pointer position the offscreen renderer does not deliver, so that part
  of the row stays with 4B.

These gaps are the owner's to accept with the package, and they are the reason
the 1C matrix should be read through its `reason` field rather than through the
row ids alone.

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
  text that names a real path;
- the offscreen renderer has no scroll interaction and the application exposes no
  message that scrolls the reader, so the continuous captures show the chapter or
  page column from its top and the paginated captures are reached with the
  production page-navigation messages. Tiled continuous seams (`FM-14`) stay with
  the Flutter/renderer packages;
- the document-opening capture (`rd-chrome-opening-w900-en`) delivers the
  production timer's own `Message::ShowDocumentOpenNotice(generation)` for the
  in-flight generation, because an offscreen run cannot wait on a real window's
  200 ms timer without also completing the open it is capturing; the state it
  shows is the production opening composition;
- the missing-file and open-error captures (`rd-chrome-missing-file-w900-en`,
  `rd-chrome-open-error-w900-en`) need a real failure, so they remove
  (respectively overwrite) the disposable copy of one seeded fixture and write
  the original bytes back immediately afterwards; the committed fixture tree and
  its checksums stay complete, and the disposable root is the run's own. The
  open-error capture delivers the real `OpenDocumentError` the production
  preparation path reports for those bytes through `Message::DocumentOpened`,
  because a *preparation* failure leaves the reader on the library screen rather
  than showing the reader's own alert;
- **the Iced reader cannot render the reused conformance EPUB under the pinned
  capture font environment.** Building its view panics inside the text stack
  (`no default font found`). This is production behavior, not a harness artifact:
  with only the application fonts registered, an EPUB span that asks for the
  default family in italic has no matching face, and cosmic-text's fallback
  iterator runs out. `reader::limitations` records it, `FM-21`/`FM-22`/`FM-23`
  stay pending with 5C/5D, and no rich-composition capture is fabricated; the
  reader's `FM-01` reference uses the generated deterministic fixtures instead.

## Environment variables

| Variable | Effect |
| --- | --- |
| `LANGUAGE` | **Required.** Must be `en-US`: the language the `System`-preference captures resolve |
| `FONTCONFIG_FILE` | **Required.** Must point at a fontconfig file that names a font directory (the entry point names an empty one), so no host font is eligible |
| `SHOSAI_REFERENCE_SHOTS_VERIFY` | `1`/non-empty: verify mode (default: capture) |
| `SHOSAI_REFERENCE_SHOTS_PACKAGE` | `1b`, `1c` or `all` (default): which packages this run produces |
| `SHOSAI_REFERENCE_SHOTS_DIR` | Package 1B evidence output directory |
| `SHOSAI_REFERENCE_SHOTS_DIR_1C` | Package 1C evidence output directory |
| `SHOSAI_REFERENCE_SHOTS_DATA_DIR` | Package 1B disposable data root (fixtures, seeded libraries) |
| `SHOSAI_REFERENCE_SHOTS_DATA_DIR_1C` | Package 1C disposable data root |
| `SHOSAI_REFERENCE_SHOTS_KEEP_DATA` | Keep the disposable data root after the run |
| `SHOSAI_REFERENCE_SHOTS_REVISION` | Override the recorded capture-code revision: a hexadecimal commit id of 7–64 characters. Required when `jj` cannot name the working copy |
| `SHOSAI_REFERENCE_SHOTS_CHANGE_ID` | Override the recorded Jujutsu change id |
| `SHOSAI_REFERENCE_SHOTS_BOOKMARK` | Override the recorded bookmark |
| `SHOSAI_REFERENCE_SHOTS_COMMAND` | Override the recorded command |
