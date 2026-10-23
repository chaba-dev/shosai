import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/shell/controller.dart';
import 'package:shosai_flutter/shell/notes_controller.dart';
import 'package:shosai_flutter/shell/search_controller.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

export 'package:shosai_flutter/shell/controller.dart';
export 'package:shosai_flutter/shell/notes_controller.dart';
export 'package:shosai_flutter/shell/search_controller.dart';

part 'view_controls.dart';
part 'view_cover.dart';
part 'view_navigation.dart';
part 'view_notes.dart';
part 'view_palette.dart';
part 'view_phone.dart';
part 'view_places.dart';
part 'view_search.dart';

// The Bookshelf shell (RFD 4 outcome 1; `docs/design-system.md`, Navigation):
// the frame around the library-side places and the reader.
//
// | Layout | Below 600 px | 600–1199 px | 1200 px and up |
// | --- | --- | --- | --- |
// | Library side | Bottom bar, Reading now cards | Sidebar (220) | Sidebar (240) |
// | Reading | The reader's own bars | Rail (56) | Rail (64) |
//
// Every widget here renders an immutable [ShellModel] and reports intent
// through [ShellActions]; none owns an effect.

/// The window classes the shell adapts to (`docs/design-system.md`, Space,
/// size and layout).
enum ShellLayout {
  phone,
  tablet,
  desktop;

  static const double tabletMinWidth = 600;
  static const double desktopMinWidth = 1200;

  static ShellLayout forWidth(double width) => width < tabletMinWidth
      ? phone
      : width < desktopMinWidth
      ? tablet
      : desktop;

  /// `sidebar-width` on desktop, 20 px narrower on tablet.
  double get sidebarWidth => this == desktop
      ? ShosaiTokens.sizeSidebarWidth
      : ShosaiTokens.sizeSidebarWidth - 20;

  /// `rail-width` on desktop, 8 px narrower on tablet.
  double get railWidth => this == desktop
      ? ShosaiTokens.sizeRailWidth
      : ShosaiTokens.sizeRailWidth - 8;

  /// Touch layouts show controls a pointer would reveal on hover.
  bool get touch => this != desktop;
}

/// `bottomnav-height`: the phone's bottom bar.
const double shellBottomNavHeight = ShosaiTokens.sizeBottomnavHeight;

/// What the shell's widgets report; the composition root routes each intent to
/// the shell or library controller.
final class ShellActions {
  const ShellActions({
    required this.selectPlace,
    required this.openBook,
    required this.closeBook,
    required this.moveBook,
    required this.addBooks,
    required this.loadCover,
    this.closeSwitcher,
  });

  final ValueChanged<ShellPlace> selectPlace;
  final ValueChanged<OpenBook> openBook;
  final ValueChanged<OpenBook> closeBook;
  final void Function(int from, int to) moveBook;

  /// Opens the file picker; null while adding books is unavailable.
  final VoidCallback? addBooks;

  /// Asks for a book's cover; false when the request was not admitted.
  final bool Function(int bookId) loadCover;

  /// Closes the phone's tab switcher, back to the current book.
  final VoidCallback? closeSwitcher;
}

/// The shell around [child]: the sidebar on the library side, the rail while
/// reading, and the bottom bar on a phone's library side.
///
/// On a phone the reader keeps its own bars, so a reading frame is [child]
/// alone, with the tab switcher over it while it is open.
class ShellFrame extends StatelessWidget {
  const ShellFrame({
    super.key,
    required this.layout,
    required this.model,
    required this.covers,
    this.pages = const {},
    required this.actions,
    required this.child,
  });

  final ShellLayout layout;
  final ShellModel model;
  final Map<int, Uint8List> covers;

  /// Miniatures of the open books' pages as they were last read, by book id,
  /// for the tab switcher.
  final Map<int, ui.Image> pages;
  final ShellActions actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    if (layout == ShellLayout.phone) {
      if (model.reading) {
        // The reader stays mounted under the switcher, so it keeps its place,
        // but keyboard focus and assistive technology cannot reach it there.
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: model.switching,
              child: ExcludeSemantics(excluding: model.switching, child: child),
            ),
            if (model.switching)
              ShellTabSwitcher(
                model: model,
                covers: covers,
                pages: pages,
                actions: actions,
              ),
          ],
        );
      }
      return ColoredBox(
        color: palette.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: child),
            ShellBottomNav(place: model.place, onSelected: actions.selectPlace),
          ],
        ),
      );
    }
    return ColoredBox(
      color: palette.canvas,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (model.reading)
            ShellRail(
              layout: layout,
              model: model,
              covers: covers,
              actions: actions,
            )
          else
            ShellSidebar(
              layout: layout,
              model: model,
              covers: covers,
              actions: actions,
            ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The reading status line: `21%`, `Not started` or `Finished`.
///
/// The progress itself says whether a book is under way; only the shown
/// percentage is rounded, and a book under way never rounds to 0% or 100%.
String shellReadingStatus(AppLocalizations l10n, double progress) {
  if (progress <= 0) return l10n.cardNotStarted;
  if (progress >= 1) return l10n.cardFinished;
  return l10n.cardPercentRead((progress * 100).round().clamp(1, 99));
}

/// The 書 mark: the character inside a plain ring, in `brand-mark`
/// (`docs/design-system.md`, Logo). Never smaller than 16 px.
class ShellMark extends StatelessWidget {
  const ShellMark({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) {
    final color = ShellPalette.of(context).brandMark;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: EdgeInsets.only(top: size / 30),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: size / 15),
        ),
        child: Text(
          '書',
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: shellMarkFontFamily,
            fontWeight: FontWeight.w900,
            fontSize: size * 16 / 30,
            height: 1,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// The mark and the wordmark at the head of the sidebar.
class ShellWordmark extends StatelessWidget {
  const ShellWordmark({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    label: 'Shōsai',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 10,
      children: [
        const ShellMark(),
        Flexible(
          child: ExcludeSemantics(
            child: Text(
              'Shōsai',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: shellEditorialStyle(
                22,
                26,
              ).copyWith(color: ShellPalette.of(context).ink),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A small cover: the book's own cover at 2:3, or a ground picked by a hash
/// of the title under a `brand-gold` band.
///
/// The cover is requested once the thumbnail is built, like the library's
/// cards, so only visible books ask for theirs.
class ShellCoverThumb extends StatefulWidget {
  const ShellCoverThumb({
    super.key,
    required this.book,
    required this.cover,
    required this.loadCover,
    required this.width,
  });

  final FlutterLibraryBook book;
  final Uint8List? cover;
  final bool Function(int bookId) loadCover;
  final double width;

  @override
  State<ShellCoverThumb> createState() => _ShellCoverThumbState();
}

class _ShellCoverThumbState extends State<ShellCoverThumb> {
  late bool _requested = widget.cover != null;

  @override
  void didUpdateWidget(ShellCoverThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.bookId != widget.book.bookId) {
      _requested = widget.cover != null;
    } else if (widget.cover != null) {
      _requested = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.cover;
    if (bytes == null && !_requested) {
      // A request the library does not admit (its cover slots are full) is
      // asked again on the next build, as the library's own covers do.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_requested && widget.loadCover(widget.book.bookId)) {
          setState(() => _requested = true);
        }
      });
    }
    final palette = ShellPalette.of(context);
    final radius = BorderRadius.circular(2);
    final generated = DecoratedBox(
      decoration: BoxDecoration(
        color: palette.coverGround(widget.book.title),
        borderRadius: radius,
        border: Border(top: BorderSide(color: palette.brandGold, width: 2)),
      ),
    );
    return Container(
      width: widget.width,
      height: widget.width * 3 / 2,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: palette.thumbShadow,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: bytes == null || bytes.isEmpty
            ? generated
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => generated,
              ),
      ),
    );
  }
}

/// A 3 px progress bar on `surface-sunken`, filled in `accent`.
class ShellProgressBar extends StatelessWidget {
  const ShellProgressBar({super.key, required this.value, this.height = 3});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: palette.surfaceSunken),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value.clamp(0.0, 1.0),
              child: ColoredBox(color: palette.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shared focus ring's width, drawn outside the control.
const double _ringWidth = 2;

/// A quiet pressable surface with the shared 2 px `accent` focus ring.
class _ShellPressable extends StatefulWidget {
  const _ShellPressable({
    required this.onPressed,
    required this.child,
    this.radius = 8,
    this.color,
    this.shadow,
    this.tooltip,
    this.semanticLabel,
    this.current = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final double radius;
  final Color? color;
  final List<BoxShadow>? shadow;
  final String? tooltip;
  final String? semanticLabel;

  /// Marks the current entry (`aria-current`) for assistive technology.
  final bool current;

  @override
  State<_ShellPressable> createState() => _ShellPressableState();
}

class _ShellPressableState extends State<_ShellPressable> {
  bool _focused = false;

  void _focusChanged(bool focused) {
    setState(() => _focused = focused);
    if (!focused) return;
    // Focus traversal scrolls the control itself into view; the ring is
    // drawn 2 px outside it, so bring that margin into view as well.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focused) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      box.showOnScreen(rect: (Offset.zero & box.size).inflate(_ringWidth));
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final radius = BorderRadius.circular(widget.radius);
    Widget result = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: _focused
            ? Border.all(
                color: palette.accent,
                width: _ringWidth,
                strokeAlign: BorderSide.strokeAlignOutside,
              )
            : null,
      ),
      // The fill and its lift sit under a transparent Material, so the hover
      // fill paints over the card instead of under its shadow.
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: radius,
          boxShadow: widget.shadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onPressed,
            hoverColor: palette.hover,
            highlightColor: palette.hover,
            splashFactory: NoSplash.splashFactory,
            focusColor: palette.hover.withValues(alpha: 0),
            onFocusChange: _focusChanged,
            // A label replaces the child's own text for assistive technology,
            // while the InkWell keeps its tap and focus semantics.
            child: widget.semanticLabel == null
                ? widget.child
                : ExcludeSemantics(child: widget.child),
          ),
        ),
      ),
    );
    result = Semantics(
      button: true,
      selected: widget.current,
      label: widget.semanticLabel,
      child: result,
    );
    if (widget.tooltip case final tooltip?) {
      result = Tooltip(message: tooltip, child: result);
    }
    return result;
  }
}
