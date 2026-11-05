# PDF Columns re-test on main (cab5aa0b)

**Verdict: needs changes (small).** Almost ready. Most issues from the PR #290 run are fixed. The remaining problems:

- 5 headings in Thrift still end a screen.
- A selection lands one line low on a reopened screen.
- Text size jumps between columns that are fitted separately.

## Setup

- **Device:** iPhone 15 Pro Max (iPhone16,2), iOS 27.2, Japanese UI, USB.
- **Build:** `origin/main` at **cab5aa0b**, which includes #289, #290, #291 and #293.
- **Signing:** Profile build, team NALL3XDPUR. Xcode created a fresh profile that is valid until 2026-11-12 05:31 UTC. iOS then refused to launch until Darwin re-trusted the developer under VPNとデバイス管理.
- **Data:** installed over the existing app; library and data kept (24 books now: 23 + BERT).
- **Papers:**
  - Thrift (8 pages)
  - ResNet arXiv 1512.03385v1 (12 pages)
  - Attention arXiv 1706.03762v7 (15 pages, one column)
  - BERT arXiv 1810.04805v2, freshly imported for the default-open check
- **Final state:**
  - The phone runs the normal `main.dart` Profile build of cab5aa0b.
  - Thrift is open in Columns at page 3.
  - Zoom is left on Columns.
  - The two test highlights I made are deleted.

### How I drove it

- **Touch input:** a test-only entrypoint (`lib/verify_main.dart`, not committed) injects touch events into Flutter's `GestureBinding`. This time it can also inject mouse drags.
- **Screenshots:** device framebuffer via the accessibility service.
- **Recording:** macOS CoreMediaIO capture over USB, 60 fps. The status bar shows 9:41 because of the capture.
- **Long-press limit:** injected touch long-presses did not start a selection, in Fit page or in Columns. I therefore tested selection and highlight with an injected mouse drag, which goes through the same `_SelectableSurface` mapping. Mouse drags do not snap to word boundaries, so the highlights start mid-word (for example "entally…"). **Touch long-press selection needs a check with a real finger.**

## 1. Problems from the PR #290 report, re-checked

| Problem | Before (19b6101f) | Now (cab5aa0b) | Result | Evidence |
|---|---|---|---|---|
| Thrift p2/p6/p7 shown as a whole tiny page | Whole page | All 8 Thrift pages in columns, code included | **FIXED** | `before-after/01–03` |
| ResNet figure/table pages shown as whole pages | 9 of 12 pages | All 12 pages in columns; figures and tables shown as bands | **FIXED** | `before-after/04–05`, `resnet-all-screens/` |
| Folio and title under the Dynamic Island | Folio y ≈ 8–23 pt | Strip starts at the 59 pt safe inset; folio at y ≈ 68–82 pt | **FIXED** | `before-after/06` |
| Last line under the home indicator | Text to y ≈ 925 pt | Strip ends at y ≈ 897 pt (34 pt inset) | **FIXED** | `before-after/07` |
| Headings stranded at the bottom of a screen | 3 in Thrift, 1 in ResNet | **Still 5 in Thrift:** "2.2 Structs", "2.4 Exceptions", "5. Versioning", "7.2 Generated Structs", "7.6 Thread, Runnable, and shared_ptr". None in ResNet | **NOT FIXED (Thrift)** | `before-after/08`, `awkward/thrift-stranded-*.png` |
| Half-empty screens | Up to about 130 pt blank | Thrift: none. ResNet: about 20% blank before the tall Fig. 3 (s008) and 2 smaller gaps. Attention p2: about 40% blank before Fig. 1 | **MOSTLY FIXED** | `awkward/resnet-screen-ends-early-before-tall-figure.png` |
| Folio skips pages | Pages 2 and 7 never named | Names ranges: "8ページ中1〜2ページ", "6〜7", "7〜8". Every page appears | **FIXED** | `before-after/09` |
| Size above 100% cuts lines | 125% cut every line | Size shows "100% · 最大" and + is disabled | **FIXED** | `before-after/10`, `new-behaviour/04` |
| Slide speed | About 0.40 s | About 0.22 s, measured from the 60 fps recording | **FIXED** | `thrift-p1-3-read.mov` |
| Line split, repeat or skip across screens | None | None. OCR checked all 20 Thrift and 30 ResNet screen changes | **PASS** | |
| Reading order | Correct | Correct, figures and tables included | **PASS** | |

## 2. New behaviour from #291

| Check | Result | Evidence |
|---|---|---|
| Phones open multi-column PDFs in Columns by default | **PASS**. Freshly imported BERT opened in Columns. Shark, a Drive book never opened before, also opened in Columns. I could not reset Zoom to unset, so I used the fresh import | `new-behaviour/18`, `19` |
| A saved choice wins | **UNCLEAR**. Attention (one column) was left on Fit page in the 19b6101f run, but opened in Columns. Either the choice is global, or the old choice was not carried over | `new-behaviour/20` |
| Double tap in Fit page enters Columns | **PASS**. Lands on the tapped part of the column (tapped near "Service.thrift" on p5 and got that line) | `new-behaviour/01–02` |
| Double tap in Columns returns to Fit page | **PASS**. Same page | `new-behaviour/03` |
| Place kept across a fit switch | **PASS**. Columns p5 screen, then Fit page p5, then back to the identical Columns screen | `new-behaviour/05–07` |
| Close and reopen keeps the place | **PASS**. Library, then reopen, came back to the identical screen | `new-behaviour/08–09` |
| Selection in Columns (mouse path) | **PARTIAL**. On normal screens the selection sits exactly on the dragged line, tested at top, middle and bottom. **On the screen restored after reopen, the selection landed one line below the pointer** | `new-behaviour/10`, `13–15` |
| Highlight in Columns, also shown in Fit page | **PASS**. The highlight shows on the same words in Fit page | `new-behaviour/11–12b` |
| Notes list quote | **Possible issue**. Both two-line highlights show only their first line in ノート | `new-behaviour/16–17` |
| Touch long-press selection | **NOT VERIFIED**. Injected long-presses did not select, in either mode; needs a real finger | |

## 3. Reading experience

I read both two-column papers end to end on the iPhone in Columns: Thrift in 21 screens, ResNet in 31.

- **Comfort.** Body text in two-column papers is comfortable: about 16.5 pt line pitch, about 58 characters per line. The safe-area insets cost about 2 lines per screen compared with before, which is a fair price. Night, Sepia and Paper behave as before.
- **Taps per page.** About 2.6 for both papers (Thrift 21 screens for 8 pages, ResNet 31 for 12). Nothing needs Fit page any more.
- **Where the eye lands.** The next line is at the top, with nothing repeated or skipped, and the column rule and page band are quiet. Exceptions:
  - The 5 stranded headings in Thrift.
  - Two places where the text size jumps between columns, so the eye has to re-adjust:
    - Thrift p7's right column renders about 15% smaller. A long line ("…TNonBlockingServer … TFramedTransport.") overflows into the gutter and widens that column's fit (`awkward/thrift-p7-right-column-smaller-text.png`).
    - BERT's indented abstract is smaller than the body that follows (`awkward/bert-text-size-jumps-abstract-vs-body.png`).
- **Figures, tables, equations and code:**
  - **Code:** Thrift listings read well.
  - **Figures:** ResNet Fig. 1, 2, 4, 6 and 7 are readable as bands. The tall Fig. 3 gets a screen of its own (fine).
  - **Equations:** (1) and (2) are crisp and in order.
  - **Narrow tables:** Tables 2–8 read fine.
  - **Wide tables are too small:** ResNet Table 1 (p5) and Tables 10/11 (p11), which span the full width, need a zoom you can't do from Columns (`awkward/resnet-wide-table1-too-small.png`).
  - **arXiv stamp:** the rotated stamp on p1 of ResNet and BERT takes the left part of the first column, so those columns render smaller.
- **Taps on links.** An outer-quarter page-turn tap that lands on an in-text reference ("Fig. 2" in ResNet) opens the 参照 link sheet instead of turning the page. That interrupts a read (`awkward/resnet-page-turn-tap-opens-link-sheet.png`).
- **Folio.** Now useful: it is visible and names ranges (for example "1〜2ページ"), and the outline shows which column you're in.
- **When I'd rather be in Fit page:**
  - Wide tables.
  - Looking at a figure together with its caption.
  - The one-column Attention paper. It renders full-width at about 10 pt with half-empty screens before figures, which is no better than Fit width (`awkward/attention-single-column-small-and-half-empty.png`).
- **Slide.** At about 0.22 s it no longer slows the rhythm.

## Top remaining issues

1. **Keep headings with their text.** 5 Thrift headings still end a screen: "2.2 Structs", "2.4 Exceptions", "5. Versioning", "7.2", "7.6".
2. **Selection.**
   - **Mapping:** a selection on a screen restored after reopen lands one line below the pointer. Check the transform for screens that start mid-region.
   - **Touch:** confirm long-press selection with a real finger.
   - **Notes:** check whether ノート stores or shows the whole quote of a multi-line highlight.
3. **Consistent text scale.** Fit all columns of a page at one scale, ignoring gutter overflow and the arXiv side stamp. Give wide full-width tables a way to zoom.

Also:

- Outer-quarter taps should turn the page rather than open links.
- Attention opened in Columns despite an earlier Fit page choice.
- On the library card, ResNet once showed 未読 together with 開いた本, before it was read to the end (`awkward/library-resnet-unread-and-opened.png`).

## Files

- `thrift-p1-3-read.mov` (1290×2796, 60 fps, 68 s, 184 MB) is not in this commit; it is on the Mac at ~/workspace/shosai-evidence/pdf-columns-main/.
- `thrift-p1-3-read-small.mp4`: the same, smaller. The read goes:
  1. double tap into Columns at the abstract;
  2. read p1–2;
  3. select two lines and highlight them yellow;
  4. read through p3;
  5. double tap out to Fit page;
  6. double tap back in.
- `before-after/`: 10 side-by-side pairs, PR #290 on the left and main on the right.
- `new-behaviour/`: #291 checks.
- `awkward/`: every remaining awkward moment.
- `thrift-all-screens/` (21 screens) and `resnet-all-screens/` (31 screens), plus contact sheets.
