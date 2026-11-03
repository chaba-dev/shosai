# EPUB book-wide numbers on Android, round 3 (2f9e4dd)

- Build: `claude/project-thread-r96hxq-verify-all` at `2f9e4ddf`, profile APK, installed with `adb install -r` (first install time unchanged, library kept)
- Device: Pixel 5a. Book: Pride and Prejudice, Pages mode, text size 90%, line spacing 1.6×
- Jumps use Contents → "Go to chapter N of 9" (typed). One check uses a Contents list entry instead.
  `scripts/jump.sh` takes device screenshots as fast as it can (one every ~0.4–0.6 s) after Enter. `sheets/*.png` show the top of the page and the status line or folio for each capture, with ms after the jump.
- Pride's place is restored to 1% · page 9, the "…delicate for pit and gallery" page, and text size is 90%. The app is back on the Library.

| Step | Result |
|------|--------|
| 1. Jump to chapter 3 (first jump after launch) | **PASS**: "16%" alone at 1.4 s, then "16% · page 114" from 2.1 s, steady to 9.9 s. Paging agrees. |
| 2. Paging across the chapter 2/3 boundary | **PASS**: 111 → 112 → 113 → **114** (chapter 3's opening page, no running head) → 115 → 116 and back, consistent |
| 3. Text size 90 → 100 → 90 | **PASS**: 100%: "16%" at 0.6–1.2 s, then **140**, steady. 90%: **114** from the first capture at 0.63 s, steady, the same as before. |
| 4. Jump to chapter 8 | **FAIL at first, PASS later**: shortly after the text-size round trip it showed **646** (paging gives **622**). Later jumps showed 622. |

## Step 1 and 2: chapter 3

Pride opened at its saved place, page 9. Jumping to chapter 3 gave `sheets/j3.png`:

- +0.85 s: keyboard closing
- +1.4 s: "16%" alone
- +2.1 s to +9.9 s: "16% · page 114", then quiet folio "page 114"

Paging from there: back → 113 ("CHAPTER X." head) → 112 → 111. Forward → 112 → 113 → **114** (no running head) → 115 → 116 ("Piling up the fire. CHAPTER XI." head). Then back → 115 → 114.
(Last round this page read 113 by paging. Page breaks before the place depend on where layout starts. In this session, the jump and paging both give 114.)

## Step 3: text size

From page 114 (`sheets/up.png`, `sheets/down.png`):

- 90 → 100%: "16%" alone at +0.6 and +1.2 s, then "16% · page 140" from +1.75 s, steady to +6.9 s.
- 100 → 90%: "16% · page 114" from the first capture at +0.63 s, steady to +7.0 s and still 114 five seconds later. Round 2 showed a stale "page 138" frame here; that is gone.

## Step 4: chapter 8, and wrong numbers just after the text-size round trip

| Time (after the switch back to 90% at 16:42:32) | Jump | Shown | Paging gives | Sheet |
|---|---|---|---|---|
| +36 s | typed → chapter 8 | "98%" until ~3.2 s, then **page 646**, steady | 621 ← back from it; opening page **622** | `j8.png`, screenshot `j8_16` |
| +1 min 58 s | typed → chapter 3 | "16% · page **118**" from 1.25 s, steady | **114** | `k3.png`, `k3_10` |
| +2 min 14 s | typed → chapter 8 | "98% · page **646**" from 1.0 s, steady | back → 621, forward → **622** | `k8.png`, `k8_14` |
| +2 min 49 s | typed → chapter 3 | page **114** | 113 / 114 / 115, consistent | |
| +4 min 9 s | Contents entry "THE FULL PROJECT GUTENBERG™ LICENSE" → Go to (no keyboard) | page **623** | back → 622 → 621, consistent | `t8.png`, `t8_12` |
| +4 min 57 s | typed → chapter 3 | page **114** | | `n3.png`, `n3_8` |
| +5 min 10 s | typed → chapter 8 | "98% · page **622**" from 1.0 s, steady | | `n8.png`, `n8_8` |

So the first chapter 3 jump and every jump from 2 min 49 s after the text-size change onwards were right. Jumps between 36 s and 2 min 14 s after it
showed a number that was too high: +4 on chapter 3 and +24 on chapter 8. The wrong number appeared after the usual uncounted "NN%" phase
and then never changed, while neighbouring pages reached by paging were numbered correctly. For example, 646 was followed by 621 on a back turn.

A guess for whoever fixes it: the excess grows with the chapter (+4 before chapter 3, +24 before chapter 8). At 100% the chapter 3 opener is +26 (140 vs 114).
That looks like some chapters' counts from the brief 100% layout were still used for 90% jumps until a background recount replaced them.
Repro: change the text size up and back, then within about two minutes jump to a late chapter from Contents.

Logcat for the app process (pid 20723): no E or F lines and no exceptions.
