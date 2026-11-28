part of 'view.dart';

// The library as a list (`docs/design-system.md`, LibraryBook): one row per
// shelf item, chosen with the section head's Grid / List control.
//
// A wide row is a ledger: a 28 px cover, the whole title over the author, then
// columns for the format, the reading progress, when the book was last read
// and when it was added, under small-capital column labels. Below
// [_libraryListWideWidth] of content (phones and tablets) a row stacks
// instead: a 40 px cover beside the title, the author and a meta line
// of format and status, over the progress bar.

/// The content width a list needs for its columns: about 600 px of columns
/// leaves the title 280 px or more.
const double _libraryListWideWidth = 900;

bool _listIsWide(double available) => available >= _libraryListWideWidth;

/// The wide row's columns after the title, in order.
const double _listCoverWidth = 28;
const double _listFormatWidth = 72;
const double _listProgressWidth = 168;
const double _listLastReadWidth = 104;
const double _listAddedWidth = 88;
const double _listActionWidth = 40;
const double _listGap = 16;

/// [iso] as a short date in the app's locale: the month and day this year,
/// otherwise with its year too.
String? _listDate(BuildContext context, String? iso) {
  final date = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (date == null) return null;
  final strings = MaterialLocalizations.of(context);
  return date.year == DateTime.now().year
      ? strings.formatShortMonthDay(date)
      : strings.formatShortDate(date);
}

/// The column labels above a wide list.
class _LibraryListHeader extends StatelessWidget {
  const _LibraryListHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final style = shellInterfaceStyle(
      11,
      14,
    ).copyWith(color: palette.inkMuted, fontWeight: FontWeight.w600);
    Widget label(String text) => Text(
      Localizations.localeOf(context).languageCode == 'ja'
          ? text
          : text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(letterSpacing: 11 * .08),
    );
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        child: Row(
          spacing: _listGap,
          children: [
            const SizedBox(width: _listCoverWidth),
            Expanded(child: label(l10n.libraryListTitle)),
            SizedBox(
              width: _listFormatWidth,
              child: label(l10n.libraryListFormat),
            ),
            SizedBox(
              width: _listProgressWidth,
              child: label(l10n.libraryListProgress),
            ),
            SizedBox(
              width: _listLastReadWidth,
              child: label(l10n.libraryListLastRead),
            ),
            SizedBox(
              width: _listAddedWidth,
              child: label(l10n.libraryListAdded),
            ),
            const SizedBox(width: _listActionWidth),
          ],
        ),
      ),
    );
  }
}

/// One shelf item as a row. The row opens the item; [action] sits at its end,
/// outside the row's button, as the card's action sits on its cover.
class _LibraryListRow extends StatelessWidget {
  const _LibraryListRow({
    super.key,
    required this.wide,
    required this.cover,
    required this.title,
    required this.author,
    required this.formats,
    required this.status,
    required this.progress,
    this.lastRead,
    this.added,
    this.open = false,
    required this.onPressed,
    this.action,
  });

  final bool wide;
  final Widget cover;
  final String title;
  final String? author;
  final List<FlutterBookFormat> formats;

  /// The reading state, a lock, or where an unopened file is.
  final Widget status;
  final double progress;
  final String? lastRead;
  final String? added;

  /// Whether the book is open in Reading now: *Open* follows the author.
  final bool open;
  final VoidCallback? onPressed;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final meta = _cardMetaStyle(context);
    final underway = progress > 0 && progress < 1;
    final author = this.author;
    final byline = Row(
      spacing: 8,
      children: [
        if (author != null)
          Flexible(
            child: Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: shosaiInterfaceStyleForText(meta, author),
            ),
          ),
        if (open)
          Text(
            l10n.cardOpenTag,
            maxLines: 1,
            softWrap: false,
            style: shosaiInterfaceStyleForText(
              _cardOpenTagStyle,
              l10n.cardOpenTag,
            ).copyWith(color: palette.accent),
          ),
      ],
    );
    final heading = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textHeightBehavior: _cardTitleHeightBehavior,
      style: shellEditorialStyle(14, 19).copyWith(color: palette.ink),
    );
    final badges = Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final format in formats) ShellFormatBadge(format: format),
      ],
    );
    final bar = ShellProgressBar(value: progress, height: _cardProgressHeight);
    final Widget content;
    if (wide) {
      Widget date(String? iso, double width) => SizedBox(
        width: width,
        child: Text(
          _listDate(context, iso) ?? '—',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: meta,
        ),
      );
      content = Row(
        spacing: _listGap,
        children: [
          SizedBox(width: _listCoverWidth, child: cover),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [heading, byline],
            ),
          ),
          SizedBox(width: _listFormatWidth, child: badges),
          SizedBox(
            width: _listProgressWidth,
            child: Row(
              spacing: 10,
              children: [
                if (underway) Expanded(child: bar),
                underway ? status : Flexible(child: status),
              ],
            ),
          ),
          date(lastRead, _listLastReadWidth),
          date(added, _listAddedWidth),
          const SizedBox(width: _listActionWidth),
        ],
      );
    } else {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          SizedBox(width: 40, child: cover),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                heading,
                byline,
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [badges, status],
                  ),
                ),
                if (underway)
                  Padding(padding: const EdgeInsets.only(top: 4), child: bar),
              ],
            ),
          ),
          const SizedBox(width: _listActionWidth - 12),
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Stack(
        children: [
          ShadButton.raw(
            variant: ShadButtonVariant.ghost,
            width: double.infinity,
            height: 0,
            padding: EdgeInsets.symmetric(
              horizontal: 8,
              vertical: wide ? 6 : 10,
            ),
            backgroundColor: _triggerNoFill,
            hoverBackgroundColor: palette.hover,
            pressedBackgroundColor: palette.hover,
            foregroundColor: palette.ink,
            mainAxisAlignment: MainAxisAlignment.start,
            onPressed: onPressed,
            enabled: onPressed != null,
            // The button centres its label; a row reads from the start.
            child: Expanded(
              child: DefaultTextStyle.merge(
                textAlign: TextAlign.start,
                child: content,
              ),
            ),
          ),
          if (action case final action?)
            PositionedDirectional(
              end: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: SizedBox(width: _listActionWidth, child: action),
              ),
            ),
        ],
      ),
    );
  }
}

/// A placeholder row while page one loads in the list layout.
class _LibraryListSkeletonRow extends StatelessWidget {
  const _LibraryListSkeletonRow();

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    Widget block(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.surfaceSunken,
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusXs),
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        spacing: 12,
        children: [
          block(_listCoverWidth, _listCoverWidth * 1.5),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [block(180, 12), block(100, 9)],
          ),
        ],
      ),
    );
  }
}
