# Manual Linux check (profile build of c6a214bd, Sway + XWayland via GDK_BACKEND=x11, xdotool)

Session was locked with displays powered off throughout, so screenshots are X11 window captures
(`import -window`) and keys are XTEST events delivered to the window under the pointer (X focus = PointerRoot).
Data dir isolated: XDG_DATA_HOME=/tmp/tour-manual-data, seeded from the Linux tour's library
(the GTK "Choose Directory" picker would not list any folder under the locked session).

Keyboard (Gibbon, two-page spread, opened with a mouse click on its cover):
- Without clicking the page: PageDown, Space, Right -> none turned the page (m06-m09).
- After one click on the page: PageDown turned (m10->m11); Space and Right did not (m12, m13).
- Repeated per key, each after a fresh page click: Space no, Right no, PageDown yes (r-*.png).

Relaunch: opened Gibbon + attention (rail showed both), closed the window via the WM (app exit 0),
relaunched -> library shows "4 books" with no "Reading now" section and no open-books count (m17).
Reading positions and recency were kept (attention 14%, Gibbon 10%; Gibbon resumed at its page, m18-m20).

Other: first frame of Gibbon after open (m06, ~5 s) drew a single text column straddling the spread's spine;
it settled to a proper two-column spread afterwards. attention.pdf still showed "Opening document..." 5 s after
the click (m15) and was rendered when next captured (m15b); my timing probe was inconclusive.
