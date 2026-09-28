# 5A renderer and persistence contract

Status: **accepted by the owner; merged in [PR #134](https://github.com/chaba-dev/shosai/pull/134)
at [154088a4](https://github.com/chaba-dev/shosai/commit/154088a44ade72ffc77f18c98933f8f3e7c7824e)
on 2026-09-28T05:17:09Z. Its Rust-specific EPUB renderer/persistence portions
are superseded by the 2026-09-28 EPUB adoption decision (see §1); its behavioral
rules and PDF/CBZ portions remain in force.**
Base: [PR #133](https://github.com/chaba-dev/shosai/pull/133),
[6514f5de](https://github.com/chaba-dev/shosai/commit/6514f5de62caecaf781edee0774bc3880ff95bf5).
Owner: [5A thread](https://ampcode.com/threads/T-01a0e64e-c3e6-71fb-bb9b-1a7a40618e26).
The [restoration plan](flutter-ui-restoration-plan.md) owns acceptance and gaps.
This document freezes the former 5B interface, not an implemented renderer or a
baseline. 5B is superseded (see §1); its EPUB mechanisms are reference-only and
its acceptance run below is historical, not a pending dispatch.

## 1. Authority and the implementation being replaced

[Architecture](flutter-architecture.md), [RFD 4](../rfd/0004/PHASE-0.adoc),
[RFD 6](../rfd/0006/README.adoc) and restoration decisions 4, 5, 8 and 12 apply.
Rust owns parsing, canonical text, layout, durable resolution, admission and writes.
Flutter renders immutable state and dispatches typed messages; controller effects
own handles, image decode, cancellation and guarded completion. No second text
layout in Flutter may generate geometry for Rust pixels.

The merged [Dart evaluation](dart-document-stack-evaluation-plan.md) was planning
only when this contract was written; the owner's 2026-09-28 EPUB adoption
decision now amends it for EPUB (see the supersession note below). Its allowance
to discard old-schema compatibility applies to a separately authorized adoption
investigation, not to the retained stores. **Existing stores are preserved while
the EPUB slice is integrated; no schema migration, reset or old-anchor conversion
is authorized.**

**Superseded for EPUB (2026-09-28).** The owner's
[EPUB adoption decision](dart-document-stack-evaluation-plan.md#adoption-decision-2026-09-28)
adopted Dart-owned EPUB parsing/normalization with Flutter layout and amended
[architecture rules](flutter-architecture.md#document-ownership-by-format). This
contract splits for EPUB:

- **Still binding behavioral invariants:** durable locations are not presentation
  addresses and a layout page index is never a durable chapter or a progress
  value; layout identity covers mode, dimensions, DPR/raster scale, typography,
  palette and layout revision; one atomic publication replaces displayed state
  and no mixed-identity frame is shown; work is bounded, cancellable, and stale
  completions are rejected after every await; every retained resource has one
  explicit owner and is released exactly once; canonical durable text maps to
  visible text explicitly; selection/annotation ranges are extracted
  independently of retained tiles; and Rust remains the only database writer
  while the slice is integrated.
- **Superseded EPUB mechanisms (reference-only for EPUB):** the Rust-side
  `FragmentBundle` RGBA raster, the bridge `layout`/`fragment`/
  `viewport_fragments`/`locate`/`point_at`/`extract_range`/`project_range`/
  `release_*` operation set with `FragmentLease`/`take_buffer` transfer and host
  decode, and Rust EPUB layout ownership. The adopted EPUB boundary produces its
  pixels and geometry from one Flutter layout inside the controller's effect
  contract, without a bridge raster round trip. These shapes remain normative for
  PDF/CBZ and for any consumer that keeps the Rust renderer; they are not
  requirements for the EPUB engine slices, and their names/bindings are not
  generated for them.
- The superseded 5B package is paused and is not a consumer; the restoration plan
  records that disposition and keeps all package acceptance unchanged. A later
  slice may reuse an operation shape it still needs, but must say so explicitly.

The contract remains fully in force for PDF/CBZ. RFD 4's
renderer-neutral scene can be encoded as the selected RGBA + sidecars, not Flutter
reshaping. 1D still owns governing-record reconciliation.

Inspected sources and consequences:

| Existing source | Observed contract / change required in 5B |
| --- | --- |
| `crates/shosai-core/src/bridge.rs`: `ReadingStateDto`, `SelectionSurface`, `create_annotation`, `reading_progress` | `unit` is an EPUB chapter, not a layout page. Current annotation creation obtains whole-chapter selection text/geometry and materializes prefix/suffix; current progress ignores offsets. Do not reuse these paths for bounded fragments. |
| `epub/presentation.rs`, `search.rs::extract_text_from_nodes` | Admitted chapter search stream is canonical, including generated separators, image alt and math fallback. Preserve its scalar offsets. |
| `epub/pagination.rs`: `Page`, `PageNode`, `page_size`, `visible_pages` | Reuse Rust pagination and composition ownership; do not invent a new layout engine. Existing page cap is 10,000. |
| `epub/native_text.rs` | Whole request currently capped at 65,536 scalars/endpoints, 4,096 paragraphs, 16,777,216 pixels. Long chapters must use bounded work, not higher limits. |
| `annotations.rs`: `EpubAnchor`, `QuoteSelector`, `TextScalarIndex`, normalization v1 | Half-open Unicode-scalar anchors with fingerprint/resource/spine, normalized quotes and bounded recovery; PDF has page-user-space geometry. Keep existing schema/profile. |
| `reader.rs`, `reading_state.rs`, `state_writer.rs`, migrations 001–016 | Durable state has chapter/page + nullable offset + positive zoom, book/path/content-qualified ownership and ordered transactional writes. Preserve them. |
| `shosai-app/src/app.rs`, `app/dispatch.rs`; Flutter `reader/controller.dart` | Iced defaults use `reader.default_*`; Flutter uses `reader.*` and numeric zoom sentinels. Per-file zoom remains positive. These are distinct codecs, not interchangeable numbers. |
| `docs/flutter-reader-presentation-contract.md` | Presentation ordinals, Contents and sessions remain fixtures until 5E/5F/5G. A 5B DTO does not make the UI live. |

Paths without a crate prefix in this table are under `crates/shosai-core/src`.

## 2. Durable locations are not presentation addresses

The following is normative Rust-shaped DTO notation (owned strings/vectors;
fixed-width wire integers, checked conversions to `usize`; `u64` becomes Dart
`BigInt`). It is not generated source. Reuse existing domain types internally.

```rust
enum DurablePoint {
    Epub { spine: u32, resource: String, scalar: u32 },
    Pdf { page: u32 },
    Cbz { page: u32 },
}
struct EpubRange { spine: u32, resource: String, start: u32, end: u32 }
enum DurableRange {
    Epub(EpubRange),
    Pdf { page: u32, start_character: u32, end_character: u32 },
}
enum ProjectionTarget {
    Text(DurableRange),
    PdfGeometry { page: u32, rectangles: Vec<PageRect> },
}
enum PositionEdge { StartOrInterior, End }
struct ReadingPosition { point: DurablePoint, edge: PositionEdge }
enum Affinity { Upstream, Downstream }
enum FragmentAddress {
    Page { ordinal: u32 },             // document-layout global, zero-based
    Tile { spine: u32, index: u32 },   // bounded continuous chapter tile
    FixedPage { page: u32 },          // PDF/CBZ page, still identity-scoped
}
struct FragmentRef { layout: LayoutId, address: FragmentAddress }
struct LocatedPoint {
    point: DurablePoint,
    fragment: FragmentRef,
    local_x: f64, local_y: f64,
    affinity: Affinity,
    text_selectable: bool,
}
```

Every operation also takes an existing `DocumentHandle`; the handle's content
fingerprint qualifies the point. It is not legal to resolve an old point against
a different document without the existing anchor reconciliation policy. Spine
**occurrence** distinguishes repeated references to the same resource. Rust
canonicalizes/validates the resource against that occurrence; no host path is
accepted as a resource ID. PDF/CBZ have no EPUB offset. CBZ has no text range.

Reading state/bookmarks continue storing `page = spine` and
`location_offset = scalar` for EPUB; fixed formats store physical page and null
offset. Legacy null EPUB offset means chapter start for display, but preserve null
on a load/no-op save; an explicit navigation/selection establishes a concrete
offset. Rust returns clamping diagnostics for out-of-range legacy points; loading
alone never rewrites the row. Saved annotation anchors keep their existing version,
fingerprint, resource and quote selectors; never serialize `FragmentAddress`.

`locate(point, layout, affinity)` and `point_at(fragment, x, y, affinity)` are Rust
operations. At a shared page boundary, downstream chooses the following fragment,
upstream the preceding one; chapter-end chooses its final fragment in either case.
A durable point has no affinity field in storage. Hidden canonical text maps to
its associated object/block location, with `not_text_selectable` in the result;
navigation succeeds without inventing a selectable caret. Image-only/empty chapters
still have a location and one page; the locator uses the chapter start. Out-of-page
hits clamp to the nearest legal caret in that same spine/PDF page.

Projection takes a ProjectionTarget plus a bounded list of fragment refs, returning
only intersections. Endpoints remain chapter-global/PDF-character-global after
eviction. Adjacent fragments may share a caret boundary, never duplicate selected
content. Bidi visual order is separate from logical scalar order. User endpoints
snap to extended-grapheme boundaries in Rust-produced geometry; arbitrary scalar
search anchors remain representable, and highlight projection expands paint to
intersecting clusters without altering the stored search range.

`PdfGeometry` reuses `PdfAnchor`'s canonical page-user-space rectangles and its
16,384-rectangle cap. Persisted annotations with `character_range = None` and
`quote = None` use this case, never fabricated text endpoints. Rust applies the
requested fragment's user-to-local affine transform (crop/rotation/zoom included)
then clips to that fragment. Output echoes its FragmentRef; stale-layout display
rectangles from the old `list_annotations(scale)` response are not valid input.
Geometry-only creation retains the current owned PDF selection geometry path;
it does not call text-only `extract_range` to invent a quote. Its returned annotation
keeps nullable text range/quote plus canonical geometry for subsequent projection.

Progress is Rust-owned and independent of pagination. For EPUB, use
`(spine + scalar / max(1, chapter_scalar_count)) / spine_count`, clamped to [0,1];
null offset contributes zero. At an empty chapter's end its fraction is one;
`ReadingPosition.edge` carries that transient navigation outcome to the Rust save
operation, and is End only on explicit end navigation, never inferred from scalar
zero. A loaded empty chapter starts at StartOrInterior; its stored scalar cannot
distinguish end, so do not recompute stored progress on load. At final document end
progress is one. The edge is not a new database column or an anchor selector.
For PDF/CBZ use `(page + 1) / page_count` (zero if empty). Do not mix `spine` and
layout page count. Keep page ordinals and known/unknown page totals as separate
presentation metadata. Existing persisted progress is not rewritten on load;
5B adopts this policy on the next explicit position save and tests both frontends.

## 3. Layout identity and all-or-nothing publication

```rust
enum Mode { Paginated, Continuous }
enum RasterZoom { FitPage, FitWidth, Manual { scale: f64 } }
struct LayoutSpec {
    mode: Mode,
    viewport_width: f64, viewport_height: f64, // logical document area, not window
    raster_scale: f64,                       // device pixels / logical pixel
    font_size: f64, line_spacing: f64,
    zoom: Option<RasterZoom>,                // None for EPUB
    palette: ReaderTheme,
    font_set_revision: u64,
}
struct LayoutId {
    document: DocumentHandle,
    document_generation: u64,
    revision: u64,                           // Rust-issued, never reused per handle
}
struct LayoutRequest {
    document: DocumentHandle,
    document_generation: u64,
    operation_revision: u64,                 // controller-issued
    spec: LayoutSpec,
    preserve: ReadingPosition,
}
struct LayoutReady {
    id: LayoutId, operation_revision: u64,
    effective_spec: LayoutSpec,
    page_count: Option<u32>,                 // None until known, never fabricated
    spread_columns: u8,                      // 1 or 2; continuous is 1
    located: LocatedPoint,
}
struct FragmentBundle {
    fragment: FragmentRef,
    operation_revision: u64,
    lease: FragmentLease,
    raster: RenderedBuffer,                  // straight-alpha RGBA8, no EPUB tint
    logical_width: f64, logical_height: f64,
    content_box: Rect,
    canonical_ranges: Vec<DurableRange>,
    visible_text: String,
    map: Vec<TextMapRun>,
    geometry: FragmentGeometry,
    semantics: Vec<SemanticNode>,
    placement: Placement,
    retained_bytes: u64,
}
enum Placement {
    Page { ordinal: u32, total: Option<u32> },
    Tile { chapter_y_px: u64, height_px: u32, chapter_origin_y: f64 },
    FixedPage { page: u32, page_count: u32 },
}
```

`Rect` is finite logical left/top/right/bottom, nonnegative extent; all geometry
is fragment-local top-left coordinates. `FragmentGeometry` uses the existing
endpoint, legal grapheme/word boundary, visual-line/caret fields, with global
canonical offsets and upstream/downstream line affinity; PDF also retains its
existing canonical user-space rectangles and explicit user-to-local transform.
Map/semantic structures are defined in §5. Page content box excludes title/footer;
those decorative labels are not inserted into canonical text or reading order.

Rust registry associates `LayoutId` with **all** effective fields, document content
identity and renderer revision. Equality/cache reuse must include mode, both
logical dimensions, DPR/raster scale, font/line spacing, palette, font set and
document zoom. The small ID is an opaque equality token, not a substitute for
checking fields at cache lookup. Validate finite positive dimensions/scales and
supported typography; normalize only once in Rust and return effective values.
Do not equate `raster_scale` with document zoom or persist it. Document generation
is a session guard, not the content fingerprint.

The controller reports width, **height and DPR** changes as typed intent. Coalesce
resize for 80 ms after the last change, with at most one admitted layout and one
latest pending request. Superseded work is cancelled. Old pixels may be scaled
during drag but retain their old geometry transform; disable new selection/semantic
actions during this preview rather than attach new geometry to old pixels.

Publication sequence: admit → layout → raster/sidecars → transfer → decode → typed
completion → one model replacement. Check tab (5F), document generation, layout ID
and operation revision after every await, including decode. A bundle is displayed
only after the image is decoded and all sidecars validated. LayoutReady alone may
set loading metadata, never replace displayed pixels' identity. In a spread, retain
the previous complete pair or show a loading state until both new pages are ready;
never combine pages from different identities. A failed decode/sidecar keeps the
old coherent bundle and reports a guarded error.

`FragmentLease` is one Rust retention reservation for geometry/semantics/map.
The raster buffer follows existing `take_buffer`/release ownership separately;
the host releases it after transfer even if decode fails. A controller owns every
returned lease, unadopted byte array and decoded image; stale/error paths release
each exactly once. Adopted geometry lives until bundle replacement/eviction;
decoded images have a host byte reservation until disposal. Closing a document
waits for outstanding users; finalizers are only a backstop. Neither lease nor
image eviction invalidates durable selection. 5F owns tab policy, not a second
resource budget.

## 4. Bounded operations and resource admission

New bridge operations (5B owns names/bindings once, these shapes are frozen):

| Operation | Input → result | Bound / ownership |
| --- | --- | --- |
| `layout` | LayoutRequest + cancellation → LayoutReady | One cancellable job; Rust retains an admitted layout index, not all page rasters. |
| `fragment` | FragmentRef + operation revision + cancellation → FragmentBundle | One page/tile per call; reuse complete identity-matched bundles. |
| `viewport_fragments` | LayoutId + logical top/bottom + cap (1–8) + optional cursor + cancellation → FragmentWindow | Metadata-only visible-fragment discovery; definitions below. |
| `locate`, `point_at` | As §2 + cancellation → LocatedPoint + selectability | Coarse navigation only; drag uses retained geometry without bridge calls. |
| `extract_range` | DocumentHandle + DurableRange + layout ID + purpose (Copy/Annotation) + cancellation → RangeText | Independent of retained tiles; layout ID qualifies visibility mapping, not canonical offsets. |
| `project_range` | ProjectionTarget + up to 8 FragmentRefs + cancellation → bounded fragment-keyed rectangles | Text or canonical PDF geometry; no re-extraction of entire chapter. |
| `release_fragment`, `release_layout` | Lease / LayoutId | Explicit owner release; existing users hold reservations until drained. |

`RangeText` has optional `canonical_original`, `normalized_exact`, `prefix`, `suffix`,
`visible_copy: Option<String>`, `copy_eligible`, `mapping_complete`. It carries no
raster or per-character geometry. The four selector fields are all present for
complete text-backed annotation extraction, all absent for incomplete PDF mapping;
copy then is unavailable. Geometry-only PDF creation uses the separate path above.
Text-backed annotation creation calls this same bounded
core path; it must not call `selection_surface` as a surrogate extractor. Exact
range extraction uses admitted scalar checkpoints (at most 1,024 scalars apart)
or an equivalent bounded index, then visits only the range and limited context.
Count index memory in document admission. Quote normalization v1 and persisted
selector fields remain unchanged. Scan prefix/suffix incrementally until 32
normalized context scalars are determined, each within the existing 65,536 input
scalar cap; if a pathological sequence prevents a correct boundary, return a
typed limit error instead of scanning the chapter or silently truncating context.
Context is the same whole-grapheme prefix tail / suffix head as `quote_context_v1`,
not 32 raw code points; normalization removes soft hyphens and folds the existing
whitespace profile before choosing boundaries. Finishing exactly at the input cap
is permitted only if a correct normalization/grapheme boundary is established.

```rust
enum ScrollExtent { Complete { height: f64 }, KnownPrefix { height: f64 } }
struct FragmentDescriptor {
    fragment: FragmentRef,
    placement: Placement,
    bounds: Rect,                       // global flow coordinates, clipped extent
}
struct FragmentWindow {
    layout: LayoutId,
    descriptors: Vec<FragmentDescriptor>, // <= requested cap, <= 64 KiB total
    extent: ScrollExtent,
    continuation: Option<WindowCursor>,
    waiting_for_layout: bool,
    reached_document_end: bool,
}
```

Rust owns the continuous interval index. Query `[top,bottom)` returns descriptors
whose clipped bounds intersect it, sorted by global y then logical order, without
rasterizing earlier tiles or exposing all chapter geometry. Cursor is an opaque,
bounded (≤128 bytes) layout/query/cap-qualified continuation; a different layout
returns StaleLayout, mismatched query returns InvalidRequest. At cap, continuation
resumes at the next matching descriptor; no duplicates/skips on resume. The JSON
fixture illustrates a resume-after encoding (`next` is the last returned ID);
consumers treat the real cursor as opaque, not as a fragment to render. A gap-only
query returns an empty completed window, not end-of-document. `reached_document_end`
is true only when extent is Complete and bottom reaches/exceeds that height.

Unknown distant extents may require cancellable index work, never earlier raster
fetches. One call advances at most 65,536 source scalars / 4,096 blocks and returns
`waiting_for_layout = true` with continuation if more work is needed. KnownPrefix
is the finalized indexed extent, not an estimate used to save scroll fractions;
consumers keep the durable anchor/loading tail until enough index is available.
Indexed prefix placements never change within a LayoutId. KnownPrefix→Complete
may append metadata without changing ID; relayout changes the ID. A window may
contain descriptors plus continuation; completed gap/empty windows have neither
continuation nor waiting flag. 5H implements this contract; 5B reserves the shapes.

| Quantity | Hard ceiling / rule |
| --- | --- |
| Page/tile raster | 16,777,216 pixels, checked width × height × 4; dimension ≤ 16,384 device px; never whole-chapter tall allocation |
| One shaping work window | ≤ 65,536 scalars, ≤ 65,536 endpoints, ≤ 4,096 paragraphs; split ordinary flow into smaller cancellable chunks; an indivisible over-limit cluster is a declared rejection |
| Retained selection geometry | ≤ 8 MiB **per open document across fragments**, including endpoints/carets/boundaries and vector capacity |
| Bundle sidecars (map + semantics + geometry) | ≤ 8 MiB per fragment and counted in shared retained admission; ≤ 65,536 semantic nodes or mapping runs each, additionally byte bounded |
| Quote/copy | ≤ 65,536 selected scalars, ≤ 65,536 raw context scalars on each side, ≤ 32 normalized context scalars per side; reject 65,537, no partial annotation write |
| Projection | ≤ 8 requested fragments; ≤ 65,536 rectangles total, byte-accounted; continuation requires another coarse request, not per-pointer calls |
| Layout | ≤ 10,000 pages (existing cap), ≤ 10,000 tiles per spine; index ≤ 8 MiB per layout, two live layouts per document during replacement |
| Global core bridge | Existing 160 MiB single buffer / 320 MiB retained buffers, 64 requests, 2 render workers, 64 documents, 256 buffers remain hard maxima |
| Host image cache | ≤ 128 MiB decoded images across tabs; ≤ 8 decoded fragments per active view; reserve before decode, evict unpinned entries first |
| Input/resource admission | Existing `EpubLimits`, font isolation, image decode, XML/CSS/SVG/table/recovery limits stay in force; no network resource fetch |

These are ceilings, not cache targets or an RSS promise. Byte arithmetic is checked
before allocation and includes simultaneously live native output, transfer copy,
host decode and old/new bundles. Account layout indexes, source text and resources
in retained-document admission, not as free metadata. Admission failure preserves
the old display; never evict a pinned in-use lease to fake capacity. Rejection is
typed (`InvalidRequest`, `Cancelled`, `StaleLayout`, `ResourceLimit { kind, limit }`,
`Unsupported`, plus existing domain/storage errors); never truncate successful
output or silently strip geometry. Recovery keeps the existing 64 Mi work cap and
ambiguous/orphaned states; it is not folded into a supposedly range-local fast path.

A valid 90,000-scalar chapter in §8 must render and annotate beyond offset 65,536.
Its *aggregate* untiled pixels may exceed the old ceiling; each bounded fragment
must not. Geometry for offscreen pages need not be retained. Supporting this case
does not require admitting an oversized image, one hostile grapheme or 10,001 pages.

## 5. Canonical text, visible text and semantics

```rust
enum TextMapKind { Text, Separator, HiddenFallback, VisibleFallback, Object }
struct TextMapRun {
    canonical_start: u32, canonical_end: u32,
    visible_start: u32, visible_end: u32, // scalar offsets in fragment visible text
    kind: TextMapKind,
    selectable: bool,
}
struct SemanticNode {
    id: String,                         // document + spine/page + source node ID
    parent: Option<String>,
    order: u32,                         // logical document order, not x/y sort
    role: SemanticRole,                 // document/heading/paragraph/link/image/math/table/cell
    label: String,
    range: Option<DurableRange>,
    bounds: Vec<Rect>,
    actions: Vec<SemanticAction>,       // select range, activate validated link
}
```

The bundle also carries its bounded `visible_text: String`. Map runs cover the
canonical intervals represented by its nodes in order, including zero-visible
segments; identity text runs have equal scalar lengths. Non-identity text shaping
(ligatures, bidi, discretionary hyphens) uses renderer cluster/caret tables, not
linear interpolation. A painted discretionary hyphen is synthetic visible text
with zero canonical length; copying uses the original canonical word. Generated
list markers/page labels likewise do not shift durable offsets. Scalars are not
UTF-16 code units, bytes or graphemes; wire Dart conversion occurs only for UI APIs.

Canonical stream v1 is exactly the existing `search_text()` extraction order,
including newlines/tabs and fallback strings; normalization is a *quote/search*
operation, not an edit to that stream. No font/width/palette change renumbers it.
Successful images and rendered math retain canonical fallback ranges but expose
no text carets for those hidden strings. A missing-image or unsupported-math
fallback visibly painted as text uses `VisibleFallback` and is selectable. Captions
remain separate visible text. Semantic image/math labels may use alt/fallback even
when it is not copyable text; semantics does not manufacture text-selection endpoints.

A selection may span an object between visible endpoints. Its persisted canonical
selector includes the interior canonical fallback so the current anchor resolver
can validate it; **clipboard copy includes only visible selectable content and
canonical separators**, not hidden alt/math or synthetic page furniture. Both
forms are returned explicitly; UI must not copy `canonical_original`. A hidden-only
range cannot be created from user selection and reports `not_text_selectable`;
existing/search anchors in it can navigate to the object and show no text overlay.
Incomplete PDF text mapping preserves geometry-only annotation support and disables
copy/quote recovery as today. Never infer a quote from cached rasters/tiles.

Semantic IDs are stable across tile cuts/reflow, scoped by document generation at
the host. One logical node may have several fragment bounds; Flutter merges retained
pieces by ID and logical order, not duplicate announcements. On eviction, preserve
focused durable node identity; request its fragment or move focus with an explicit
accessible transition. 5I verifies live ordering/focus, not merely static labels.
Links preserve the existing allowed-scheme policy and Rust canonical internal-link
resolution; no file/data/javascript launch is inferred from a semantic action.

## 6. Continuous coordinates, spreads and fit

EPUB continuous is a separate Rust flow layout, not pages stitched together.
Use 20 logical px outer content padding, a column capped at 800 logical px including
padding, and 32 logical px between chapter flows exactly once. No page boxes,
page titles/margins or footers. Text/block positions are computed before tiling.

For raster scale `r`, chapter tile boundary `b[i]` is an integer device-pixel row.
Tile i covers half-open `[b[i], b[i+1])`, has local logical origin `b[i]/r`, and is
placed at `chapter_origin_y + b[i]/r`. Use the same accumulated boundaries for
raster clipping, geometry translation and placement; never independently round
each tile's logical height. Last tile ends at `ceil(chapter_height * r)`; clip its
extra edge to the chapter extent. Chapter origins derive from the same continuous
flow including the single 32 px gap. Rasterization may include a small admitted
sampling halo, but crop it before publication; published tile intervals never
overlap. Tile cut through text/image/block spacing does not insert a line gap.

For a small fixture, compare concatenated tile pixels/geometry with **one untiled
render of the identical continuous layout**, not with paginated output. Test DPR
1, 1.25 and 2 with cuts through styled lines, image and spacing. Raster-phase
translation must be identical at each cut. Large coordinates use f64 / checked
u64 pixel rows; reject loss of exact row identity beyond the representable range.
Flutter virtualizes a local window rather than allocating a giant image/widget.

Paginated EPUB spread rule v1: let W/H be the available document area after chrome,
panels and edge controls; gutter G = 20 logical px. Candidate usable column
`C = (W - G)/2 - 40`. Use two columns iff W ≥ 720 and
`C ≥ max(120, 12 × font_size)`, otherwise one. Preserve chosen font size.
Keep existing readable-width cap `font_size × 0.55 × 72` and page-height rule
`max(120, H - 40 - (11 × 1.2 + font_size × line_spacing))`. W/H must admit the
minimum content box; otherwise report a viewport-too-small state, not overflow.
The 12-em minimum is an engineering starting calibration, not a claimed EN/JA
quality pass. 5B must render EN/JA at 16/32/48 px and report any proposed threshold
change before consumers freeze measurements. Formula and location preservation
are fixed; numeric calibration needs evidence, not owner permission to omit spreads.
Pair consecutive pages 0/1, 2/3; an odd last EPUB page keeps the half-row filler,
never repeats itself; narrow mode reserves no filler. 5H exercises live switches.

PDF/CBZ typed zoom uses 1.0 = one logical pixel per native page unit (existing
page-size convention); DPR only affects sampling. FitWidth uses usable viewport
width / page width; FitPage uses min(width ratio, viewport-height ratio), including
in continuous mode (fit the current page to one viewport, not the entire scroll
column). Recompute per page for mixed dimensions. Paginated spreads fit each page
to its slot; continuous has one column and existing 20 px spacing/padding. Clamp
derived fit scale to [0.1,5]; manual controls emit [0.25,5]. Legacy positive manual
values outside the control range are preserved as requested preferences; admission
may reject their raster size, never silently rewrite the saved number. Changing
mode/fit/font/viewport first captures a durable location and resolves it in the new
layout; it does not retain a raw scroll fraction or a page ordinal.

## 7. Typed codecs without a schema migration

Implement codecs in Rust `reader`/persistence ownership and adapt both frontends;
no sentinel in new widgets/DTOs. Existing old bridge APIs remain compatible during
5B–5G. Typed wire enum is `Mode` / `RasterZoom` in §3, not a free-form string.

New preference values use existing bounded `preferences(key,value)` rows:

```json
{"version":1,"mode":"continuous","zoom":{"kind":"manual","scale":1.75}}
```

Key `reader.defaults.v1` holds optional default mode/zoom fields;
`reader.book.<decimal-book-id>.v1` holds optional per-library-book overrides.
Absent mode inherits; clearing mode removes it. For **book zoom only**, absence
means untouched legacy fallback, whereas `{"kind":"inherit"}` means deliberately
inherit defaults and suppress `reading_state.zoom`. Clearing zoom writes this
storage-only marker rather than deleting it. The preferences API represents it as
`ZoomOverride::Inherit` versus `Explicit(RasterZoom)`; Inherit is never a layout
`RasterZoom` variant and is invalid in the defaults row.
Zoom variants are exactly `{"kind":"fit-page"}`, `{"kind":"fit-width"}`, or
`{"kind":"manual","scale":positive-finite-number}`. Mode exactly `paginated`
or `continuous`. Reject duplicate/unknown fields, unsupported version, wrong types,
non-finite/non-positive scale and extra variant fields; return a settings warning
and fall through to a valid lower-precedence source without rewriting bad rows.
New API writes validate the full object before a single transaction. Preserve
unrelated keys. Keep preference row/key/value/total limits; saturation is an explicit
save error, never unbounded per-book growth. Remove owned override on book deletion
in the existing transaction; unmanaged files use session overrides plus existing
path/content-qualified location/positive-zoom state, no unbounded path-key preference.

Precedence, independently for each field:
1. Explicit session intent (until saved or cleared).
2. Valid explicit `reader.book.<id>.v1` field. Book Inherit skips step 3.
3. For zoom only without Inherit, valid legacy per-book/file `reading_state.zoom` as Manual(scale).
4. Valid `reader.defaults.v1` field.
5. Legacy Flutter `reader.mode` / `reader.pdf_zoom`.
6. Legacy Iced `reader.default_mode` / `reader.default_pdf_zoom`.
7. Built-in Paginated / FitPage.

Legacy numeric zoom preference: `0` → FitPage, `-1` → FitWidth, finite positive →
Manual unchanged; any other negative/NaN/infinity/malformed → warning + next source.
Legacy Iced default zoom: `fit-width` or `fit-page`. Legacy modes use their existing
strings. A positive reading-state zoom (including 1.0) cannot reveal whether an old
frontend used fit; treat it as Manual, do not guess. This is an explicit information
loss in old stores. Retain all values on no-op load. EPUB ignores zoom for layout,
but does not destroy stored raster preference/positive zoom. Typography/theme
retain existing codecs and precedence until 6B, including preserved valid old
values beyond today's UI control range; they are layout inputs, not persisted DPR.

Saving typed fit writes a positive compatibility zoom of 1.0 to reading state and
the typed per-book override atomically. Manual writes its exact positive scale.
Clearing zoom writes Inherit and compatibility zoom 1.0 atomically; the effective
zoom then follows defaults, including subsequent default changes. Position-only
saves never pin an inherited default into an explicit override: for a library book
with no prior state/zoom decision, its first position save creates Inherit plus
positive compatibility zoom in the same transaction. Existing legacy state with
absent zoom override retains its original manual value. Inherit stays Inherit on
later position saves; fit's compatibility value is 1.0, inherited manual's is the
resolved manual scale. Failure rolls back both state and preference. No-op loads
write neither. Unmanaged files still persist only legacy positive zoom; fit/mode
remain session-only there, and reopen uses legacy Manual, an explicit limitation.
Saving mode does not change durable position. New code in **both frontends** reads
the same decoder; unmodified old binaries can still read positive zoom/location,
but cannot recover newly typed per-book fit/mode semantics. That forward limitation
is not advertised as lossless old-binary interoperability. Defaults writes mirror
legacy compatible keys in the same transaction (numeric Flutter sentinel; Iced
fit string only for fit variants); manual has no Iced default representation.
Do not add a new SQL migration. Extending the existing ordered writer to include
these preference fields must preserve revision ordering, restore-failure write
blocking, removed-book checks and save draining. A stale frontend completion is not
permission to undo a newer durable write.

## 8. Independent fixtures and former 5B handoff

[`renderer-contract-fixtures.json`](renderer-contract-fixtures.json) contains
literal expected values, not output captured from the proposed implementation.
Run `python3 scripts/check_renderer_contract.py` to check scalar/UTF-16 arithmetic,
range normalization, progress, boundary/spread/tile arithmetic and plan accounting.
This is a specification consistency check, **not evidence that 5B works**. The 5B
consumer is superseded; the fixture expectations remain usable by a later named
consumer of these behavioral rules.

Fixture expectations and derivations:

| ID | Independent source and required consumer result |
| --- | --- |
| scalar-v1 | Literal `A😀é日\nZ`: 7 scalars, 8 UTF-16 units; `[1,4)` = emoji + decomposed e-acute; normalized quote `😀é`, UTF-16 `[1,5)`, legal caret boundaries `[0,1,2,4,5,6,7]`. Splitting at 3 is illegal. |
| long-v1 | 10,000 XHTML paragraphs each exactly `ab日😀é Z`; one generated newline per paragraph gives 90,000 canonical scalars. At paragraph 8,000, `[72002,72006)` is `日😀é`, normalized `日😀é`. Renderer-independent source recipe, not a shaper count. An annotation here must create/reopen/evict/reflow identically, and project only on the owning fragments. |
| reflow-v1 | Synthetic known canonical intervals A: `[0,6),[6,12),[12,20)`; B: `[0,4),[4,10),[10,15),[15,20)`. Point 8 maps to A1/B1, point 12 downstream A2/B2, range `[8,16)` intersects A1/A2 and B1/B2/B3 with literal clipped ranges in JSON. These are address algebra fixtures, not promised real line breaks. |
| map-v1 | Canonical `A\ncat\nB\nx+1\nC\n`: image alt `[2,5)`, math `[8,11)`. When both are rendered objects, copy `[0,14)` is `A\n\nB\n\nC\n`; canonical selector remains the full stream. When image fallback is painted, copy includes `cat`, not hidden math. No endpoints inside hidden ranges. |
| continuous-v1 | r=1.25; 1,001 logical px chapter; rows `[0,512,1024,1252]`, origins `[0,409.6,819.2]`; final tile clipped from 182.4 to 181.8 logical px. Next chapter origin `20+1001+32=1053`, not 1085. Small untiled composition comparison remains a 5H pixel check. |
| spread-v1 | G=20, f=32 ⇒ minimum C=384 and threshold W=868: 867→one, 868/869→two. f=48 ⇒ W=1252; f=16 retains W=720 minimum. Odd total 5, current 4→`[4]`, never `[4,4]`. |
| legacy-v1 | Disposable pre-change schema-16 database, rows with chapter=2/offset=null/zoom=1.75 and chapter=1/offset=72002/zoom=2.25; offsets and positive zoom survive both frontends, null stays null absent navigation. Fit overrides 0/-1 belong to legacy *preferences*, never state.zoom. Literal codec cases in JSON. |
| zoom-transitions-v1 | First inherited position save and clear-fit produce Inherit, not Manual(1); a later default 2.5 takes effect; failed clear leaves FitPage and state unchanged. Legacy 1.75 remains manual on a position-only save. |
| viewport-v1 | Add a second 100 px chapter at 1053 and 20 px trailing padding (total 1173). `[1021,1053)` returns no tile and not end; `[429.6,430)` returns only tile 0:1. Cap-2 resume enumerates four descriptors exactly once. Distant lookup needs no preceding rasters; stale layout is an error, unfinished index is waiting, not EOF. |
| pdf-geometry-v1 | Canonical bottom-left rectangle `[10,20,30,50]` on a 200-high page becomes top-left `[10,150,30,180]` at scale 1; at scale 2 clipped to `[0,320,50,400]` it is `[20,320,50,360]`. Character range/quote stay null. |
| context-v1 | Source is 70,000 `x` characters + ` prefix selected suffix`; `[70008,70016)` selects `selected`, prefix is 25 `x` + ` prefix`, suffix `suffix`. Prefix `q́` + 31 `a` and suffix 31 `b` + `q́` exclude the two-scalar grapheme rather than split it. A preceding run of 65,537 soft hyphens cannot establish the required normalized context within the 65,536 input cap and returns ResourceLimit. |
| empty-progress-v1 | Empty spine 1 of 4 has progress 0.25 at StartOrInterior and 0.5 at explicit End despite the same scalar zero; a reload does not recalculate persisted progress. |

5B builds the long EPUB from this fixed source recipe with deterministic ZIP
ordering/timestamps (reuse conformance generator container helpers), commits its
bytes/hash and expected canonical assertions, then checks real output against the
literal expectations. Use 480×640 logical viewport, 48 px font, 1.6 spacing, DPR 2
for the long-chapter admission case; record actual fragments and maximum allocation.
No expected real page count is invented before shaping. The total chapter raster
at that setup must exceed 16,777,216 pixels; demonstrate it from measured extent
without allocating it. Distinguish this from hostile input tests at each limit
and +1, including one huge grapheme, image dimensions and page count.

Reuse committed `crates/shosai-core/tests/fixtures/epub-conformance` bytes and
`SHA256SUMS` for `bidi`, `fonts`/`fonts-isolation`, `nested-image`, `mathml`, `table`,
`links`, `css-cascade` and `conformance`. Their XHTML IDs and source assertions in
`epub_conformance_tests.rs` are independent content oracles. Do not bless current
renderer screenshots as expectations or assume every fixture opens: the test's
`REJECTION_FIXTURES` is authoritative, including malformed markup/resource limits.
5C/5D extend visible mapping assertions against source, not snapshot their own DTOs.

Required 5B acceptance run (each result must identify revision/fixture/hash):
- Address round trips and stale width/height/DPR/palette/font results, decode failure,
  cancellation after transfer, exactly-once lease release and mixed-spread rejection.
- Long chapter non-first-page search/bookmark/annotation/state round trips, null
  offset, reopening, eviction, width/font reflow; exact quote/range and projected
  intersection assertions, no whole-chapter extraction/allocation on the fast path.
- Disposable stores produced by the **pre-change** frontend at this base; copy
  them before each frontend test. Exercise actual Iced and Flutter load/save paths,
  shared codec precedence, rejected values, no-op retention, per-book fit override,
  failed transaction, late save ordering and remove/reopen. Do not use shared data.
- CPU raster production, bridge transfer, Dart materialization, decode, first
  content-bearing frame, warm turns, chapter transitions, font relayout and retained
  memory measured separately. Five warmups / ≥50 release samples; p50/p95/max,
  viewport/DPR/font/device/power/build and cache definitions. RFD 4 ceilings remain
  warm turn 8/16.7 ms, transition 16.7/33.3 ms, relayout 50/100 ms, DTO transfer
  p95 ≤4 ms, bridge no-op ≤1 ms; desktop steady RSS ≤512 MiB, no retained growth
  over 20 open/render/release cycles. No budget waiver inferred from a prototype.

One 5B owner edits core DTOs, bridge API and generated Rust/Dart bindings once;
run existing generated-contract, formatting, core/bridge and targeted Flutter
tests. 5B does **not** implement all rich composition, sessions or continuous UI.
5C owns font/bidi/rich blocks and CJK fallback; 5D objects/palette/map composition;
5E navigation/sidecars; 5F lifecycle; 5G live presentation/pixels; 5H modes/spreads;
5I cross-fragment interaction/semantics; 5J stress acceptance. Their implementation
may not redefine durable offsets, codecs or identity without returning to this
contract with independent changed expectations and review.

## 9. Review and decisions at handoff

Oracle round 1 found three blockers: clearing fit resurrected compatibility zoom
as Manual; continuous consumers lacked bounded viewport fragment discovery; and
geometry-only PDF annotations lacked an identity-qualified projection route.
Resolved with storage-only Inherit plus atomic position-save rules, metadata-only
viewport queries with extent/continuation, and ProjectionTarget::PdfGeometry.
The same review requested stronger exact quote-context and empty-chapter progress
vectors; both are added, with transient PositionEdge defining empty start/end.
Oracle round 2 reviewed revision `553b25af` and closed all three findings with
**no remaining blockers for documentation-only consumer freeze**. Its optional
cursor-encoding clarification is incorporated above. No findings were waived.
`python3 scripts/check_renderer_contract.py` passes all literal vectors, 12
deliberately wrong expectation controls, 15 existing conformance fixture hashes,
local links and restoration accounting. The subsequent handoff/checklist edits
do not change the reviewed interfaces; the same checks are rerun before commit.

No consumer implementation or publication is authorized by
this document alone. The 5A acceptance is now recorded (owner acceptance in the
parent thread and the #134 merge at `154088a4`); future numeric readability
calibration and the existing restoration gaps remain distinct decisions. The
former 5B dispatch is superseded by the 2026-09-28 EPUB adoption decision and
will not start: the replacement EPUB engine slices own the long-chapter/
legacy-store tests, EN/JA readability calibration and measured prototype that
contract §8 assigned to 5B, and none of that evidence is claimed here. No new
UI screenshot is required for this documentation-only package.
