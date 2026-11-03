# EPUB book-wide numbers on Android, round 4 (0c19676)

- Build: `claude/project-thread-r96hxq-verify-all` at `0c19676f` ("share EPUB page counts across heights under one line"), profile APK, installed with `adb install -r` (first install time unchanged, library kept)
- Device: Pixel 5a. Book: Pride and Prejudice, Pages mode, 90%, 1.6×
- Same scripts as round 3 (`scripts/`): typed jumps go through Contents → "Go to chapter N of 9" (the keyboard opens), and device screenshots are taken back to back after Enter (`sheets/*.png`).
  After each jump I turned back one page and forward one page and read the folio from the accessibility tree.
- I put Pride's place back at 1% · page 9 (the "…delicate for pit and gallery" page, compared against a screenshot taken at the start), left text at 90% and 1.6×, and left the app on the Library. The app logged no E or F lines and no exceptions.

| # | Check | Time | Shown after the jump | Back / forward | Result |
|---|-------|------|----------------------|----------------|--------|
| 1 | Typed jump → chapter 3, right after launch | 17:02:22 | "16% · page 114" from the first capture at 1.3 s, then the quiet folio "page 114" | 113 / 114 | **PASS** |
| 1 | Text size 90 → 100 → 90 | 17:02:41 / 17:02:50 | back at 90%: page 114 | | **PASS** |
| 2 | Typed jump → chapter 8 (+20 s after the switch back to 90%) | 17:03:10 | "98% · page 622" from the first capture at 0.7 s, steady | 621 / 622 | **PASS** (round 3: 646) |
| 2 | Typed jump → chapter 3 (+43 s) | 17:03:33 | "16% · page 114" from 1.3 s, steady | 113 / 114 | **PASS** (round 3: 118) |
| 2 | Typed jump → chapter 8 (+63 s) | 17:03:53 | "98% · page 622" from 0.9 s, steady | 621 / 622 | **PASS** (round 3: 646) |
| 3 | Contents list entry "CHAPTER XXX." → Go to (no keyboard) | 17:04:55 | "page 289" | 288 / 289 / 290 / 289 | **PASS** |
| 4 | Is a jumped-to page a line short? | | no (see below) | | recorded |

None of the jumps showed a wrong number at any point. The counts were already cached, so there was no uncounted "NN%" phase either: the right number was there from the first frame.

## Step 4: jumped page vs the same page reached by paging

`sheets/jumped-vs-paged.png` puts each typed-jump page next to the same page after back + forward. The text and line breaks are identical:
page 114 ends "…what painter could do justice" and page 622 ends "…copies of this eBook, complying with the" in both versions.
So the page is not a line short. The one visible difference after a typed jump is a dark-blue focus outline around the page body. It comes from the keyboard's
Enter key giving the page keyboard focus, and it goes away on the next turn.

Separately, the list-entry jump to "CHAPTER XXX." (`sheets/e30-list-jump-and-paging.png`) landed on a page where chapter XXX starts partway down.
The jumped-to page's running head read "CHAPTER XXX.", while the same page reached by paging reads "'Lady Catherine, said she, you have given me a treasure.' CHAPTER XXIX.", the chapter in force at the top of the page.
The folio was 289 both ways. A "Back to CHAPTER LXI." snackbar covered the folio until I dismissed it.
