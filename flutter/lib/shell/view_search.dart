part of 'view.dart';

/// A search hit chosen in the palette: its book and where to open it, or
/// null to open the book where it was left (a book note).
typedef ShellSearchChoice = (FlutterLibraryBook book, ShellSearchPlace? place);

/// Where a search hit sits: a unit, where in its text and the match's
/// length, in Unicode scalars; for a note hit, the annotation and whether
/// it is a page note rather than a highlight, so the reader resolves it.
typedef ShellSearchPlace = ({
  int unit,
  int? offset,
  int? length,
  String? annotationId,
  bool? note,
});

/// The search palette (`docs/design-system.md`, SearchPalette): book text and
/// notes together, from any screen. A query, the scope (This book / All
/// books, while a book is read) and the filter (Everything / Text / Notes),
/// then the results grouped: notes first, then one group per book with its
/// match count. Choosing a hit reports it through [onChosen].
///
/// It renders [model] and reports intent through its callbacks; the
/// [ShellSearchController] owns the searches.
class ShellSearchPalette extends StatefulWidget {
  const ShellSearchPalette({
    super.key,
    required this.layout,
    required this.model,
    required this.onQuery,
    required this.onScope,
    required this.onFilter,
    required this.onChosen,
    required this.onClose,
  });

  final ShellLayout layout;
  final ShellSearchModel model;
  final ValueChanged<String> onQuery;
  final ValueChanged<ShellSearchScope> onScope;
  final ValueChanged<ShellSearchFilter> onFilter;
  final ValueChanged<ShellSearchChoice> onChosen;
  final VoidCallback onClose;

  @override
  State<ShellSearchPalette> createState() => _ShellSearchPaletteState();
}

class _ShellSearchPaletteState extends State<ShellSearchPalette> {
  late final TextEditingController _query =
      TextEditingController(text: widget.model.query)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.model.query.length,
        );

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final model = widget.model;
    final phone = widget.layout == ShellLayout.phone;
    final touch = widget.layout.touch;
    final head = Padding(
      padding: const EdgeInsets.fromLTRB(
        ShosaiTokens.space4,
        ShosaiTokens.space3,
        ShosaiTokens.space2,
        ShosaiTokens.space3,
      ),
      child: Row(
        spacing: ShosaiTokens.space2,
        children: [
          Icon(LucideIcons.search, size: 18, color: palette.inkMuted),
          Expanded(
            child: ShadInput(
              key: const ValueKey('shell-search-field'),
              controller: _query,
              autofocus: true,
              placeholder: Text(l10n.shellSearchField),
              onChanged: widget.onQuery,
            ),
          ),
          Tooltip(
            message: l10n.shellSearchClose,
            child: ShadIconButton.ghost(
              key: const ValueKey('shell-search-close'),
              icon: const Icon(LucideIcons.x, size: 16),
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(
        ShosaiTokens.space4,
        0,
        ShosaiTokens.space4,
        ShosaiTokens.space3,
      ),
      child: Wrap(
        spacing: ShosaiTokens.space3,
        runSpacing: ShosaiTokens.space2,
        children: [
          if (model.book != null)
            ShellSegmentedControl<ShellSearchScope>(
              key: const ValueKey('shell-search-scope'),
              label: l10n.shellSearchScope,
              touch: touch,
              segments: [
                (
                  value: ShellSearchScope.thisBook,
                  label: l10n.shellSearchThisBook,
                ),
                (
                  value: ShellSearchScope.allBooks,
                  label: l10n.shellSearchAllBooks,
                ),
              ],
              selected: model.scope,
              onSelected: widget.onScope,
            ),
          ShellSegmentedControl<ShellSearchFilter>(
            key: const ValueKey('shell-search-filter'),
            label: l10n.shellSearchFilter,
            touch: touch,
            segments: [
              (
                value: ShellSearchFilter.everything,
                label: l10n.shellSearchEverything,
              ),
              (value: ShellSearchFilter.text, label: l10n.shellSearchText),
              (value: ShellSearchFilter.notes, label: l10n.shellSearchNotes),
            ],
            selected: model.filter,
            onSelected: widget.onFilter,
          ),
        ],
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: phone ? MainAxisSize.max : MainAxisSize.min,
      children: [
        head,
        controls,
        Divider(height: 1, thickness: 1, color: palette.line),
        Flexible(
          fit: phone ? FlexFit.tight : FlexFit.loose,
          child: _ShellSearchResults(model: model, onChosen: widget.onChosen),
        ),
      ],
    );
    final palettePanel = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: phone
                ? null
                : BorderRadius.circular(ShosaiTokens.radiusLg),
            boxShadow: phone ? null : palette.menu,
          ),
          child: body,
        ),
      ),
    );
    // A dialog route does not avoid the software keyboard: the palette ends
    // above it, so its last results scroll into view.
    final keyboard = EdgeInsets.only(
      bottom: MediaQuery.viewInsetsOf(context).bottom,
    );
    if (phone) {
      // On phones the palette is the whole screen.
      return ColoredBox(
        color: palette.surface,
        child: Padding(
          padding: keyboard,
          child: SafeArea(child: palettePanel),
        ),
      );
    }
    return Padding(
      padding: keyboard,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 72, 16, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: palettePanel,
            ),
          ),
        ),
      ),
    );
  }
}

/// The palette's results: a hint before a query, then the notes group and
/// one group per book, and a line while books are still searched.
class _ShellSearchResults extends StatelessWidget {
  const _ShellSearchResults({required this.model, required this.onChosen});

  final ShellSearchModel model;
  final ValueChanged<ShellSearchChoice> onChosen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final query = model.query.trim();
    final noteCount = model.notes.fold(
      0,
      (sum, book) => sum + book.hits.length,
    );
    final error = model.error;
    final children = <Widget>[
      if (query.isEmpty)
        _ShellSearchLine(text: l10n.shellSearchHint)
      else ...[
        if (noteCount > 0) ...[
          _ShellSearchGroup(
            key: const ValueKey('shell-search-notes'),
            title: l10n.shellSearchNotesGroup(noteCount),
          ),
          for (final book in model.notes)
            for (final hit in book.hits)
              _ShellSearchNoteHit(
                key: ValueKey('shell-search-note-${hit.note.id}'),
                book: book.book,
                hit: hit,
                onChosen: onChosen,
              ),
        ],
        for (final book in model.text) ...[
          _ShellSearchGroup(
            key: ValueKey('shell-search-book-${book.book.bookId}'),
            title: book.book.title,
            format: book.book.format,
            count: book.error != null
                ? null
                : book.more
                ? l10n.shellSearchMoreMatches(book.matches.length)
                : l10n.shellSearchMatches(book.matches.length),
          ),
          if (book.error case final failure?)
            _ShellSearchLine(text: l10n.shellSearchBookFailed(failure)),
          if (book.partial) _ShellSearchLine(text: l10n.shellSearchPartial),
          for (final (index, match) in book.matches.indexed)
            _ShellSearchTextHit(
              key: ValueKey('shell-search-text-${book.book.bookId}-$index'),
              book: book.book,
              match: match,
              query: query,
              onChosen: onChosen,
            ),
        ],
        if (error != null)
          _ShellSearchLine(
            key: const ValueKey('shell-search-error'),
            text: error,
          )
        else if (model.busy)
          _ShellSearchLine(
            key: const ValueKey('shell-search-busy'),
            text: l10n.shellSearchSearching,
          )
        else if (noteCount == 0 && model.text.isEmpty)
          _ShellSearchLine(
            key: const ValueKey('shell-search-empty'),
            text: l10n.shellSearchNoMatches(query),
          ),
      ],
    ];
    return ListView(
      key: const ValueKey('shell-search-results'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(
        horizontal: ShosaiTokens.space2,
        vertical: ShosaiTokens.space2,
      ),
      children: children,
    );
  }
}

/// A results group heading: the notes, or a book with its badge and count.
/// A long title truncates before the count.
class _ShellSearchGroup extends StatelessWidget {
  const _ShellSearchGroup({
    super.key,
    required this.title,
    this.format,
    this.count,
  });

  final String title;
  final FlutterBookFormat? format;
  final String? count;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final style = shellInterfaceStyle(
      11,
      14,
      weight: FontWeight.w600,
    ).copyWith(color: palette.inkMuted, letterSpacing: .88);
    final format = this.format;
    final count = this.count;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShosaiTokens.space2,
          ShosaiTokens.space3,
          ShosaiTokens.space2,
          ShosaiTokens.space1,
        ),
        child: Row(
          spacing: 6,
          children: [
            if (format != null) ShellFormatBadge(format: format),
            Flexible(
              child: Text(
                format == null ? title.toUpperCase() : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: format == null
                    ? style
                    : shellEditorialStyle(15, 20).copyWith(color: palette.ink),
              ),
            ),
            if (count != null) Text('· $count', style: style),
          ],
        ),
      ),
    );
  }
}

/// A line of the palette that is not a hit: a hint, progress or a failure.
class _ShellSearchLine extends StatelessWidget {
  const _ShellSearchLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(ShosaiTokens.space3),
      child: Text(
        text,
        style: shosaiInterfaceStyleForText(
          shellInterfaceStyle(14, 20).copyWith(color: palette.inkMuted),
          text,
        ),
      ),
    );
  }
}

/// One hit: its meta line and its snippet with the match marked.
class _ShellSearchHit extends StatelessWidget {
  const _ShellSearchHit({
    required this.leading,
    required this.meta,
    required this.snippet,
    required this.onPressed,
    this.editorial = false,
  });

  final Widget leading;
  final String meta;
  final _Snippet snippet;
  final VoidCallback onPressed;

  /// Quoted book text is set in the editorial face.
  final bool editorial;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final base = editorial
        ? shellEditorialStyle(
            15,
            22,
            weight: FontWeight.w400,
          ).copyWith(color: palette.ink)
        : shosaiInterfaceStyleForText(
            shellInterfaceStyle(14, 20).copyWith(color: palette.ink),
            snippet.text,
          );
    return InkWell(
      borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShosaiTokens.space2,
          vertical: ShosaiTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Row(
              spacing: 6,
              children: [
                IconTheme.merge(
                  data: IconThemeData(color: palette.inkMuted),
                  child: leading,
                ),
                Expanded(
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: shosaiInterfaceStyleForText(
                      shellInterfaceStyle(
                        12,
                        16,
                      ).copyWith(color: palette.inkMuted),
                      meta,
                    ),
                  ),
                ),
              ],
            ),
            Text.rich(
              TextSpan(
                style: base,
                children: [
                  TextSpan(text: snippet.before),
                  TextSpan(
                    text: snippet.match,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      backgroundColor: ShosaiTokens.colorSwatchYellow
                          .withValues(alpha: .4),
                    ),
                  ),
                  TextSpan(text: snippet.after),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShellSearchNoteHit extends StatelessWidget {
  const _ShellSearchNoteHit({
    super.key,
    required this.book,
    required this.hit,
    required this.onChosen,
  });

  final FlutterLibraryBook book;
  final FlutterNoteHit hit;
  final ValueChanged<ShellSearchChoice> onChosen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final note = hit.note;
    final unit = note.unit;
    final pdf = book.format == FlutterBookFormat.pdf;
    final place = switch (note.kind) {
      FlutterNoteEntryKind.book => l10n.readerBookNoteTitle,
      FlutterNoteEntryKind.page when pdf && unit != null =>
        l10n.readerPageNoteAt(unit + 1),
      FlutterNoteEntryKind.page => l10n.readerPageNoteTitle,
      FlutterNoteEntryKind.highlight when unit == null => '',
      FlutterNoteEntryKind.highlight =>
        pdf
            ? l10n.readerPageNumber(unit! + 1)
            : l10n.readerChapterNumber(unit! + 1),
    };
    final match = hit.matches.first;
    final field = switch (match.field) {
      FlutterNoteField.quote => note.quote,
      FlutterNoteField.body => note.body,
    };
    return _ShellSearchHit(
      leading: switch (note.color) {
        final color? => ShellHighlightDot(color: color),
        null => Icon(
          note.kind == FlutterNoteEntryKind.book
              ? LucideIcons.book
              : LucideIcons.file,
          size: 14,
        ),
      },
      meta: place.isEmpty ? book.title : '${book.title} · $place',
      snippet: _Snippet.around(field ?? '', match.offset, match.length),
      editorial: match.field == FlutterNoteField.quote,
      onPressed: () => onChosen((
        book,
        unit == null
            ? null
            : (
                unit: unit,
                offset: note.offset,
                length: null,
                annotationId: note.id,
                note: note.kind != FlutterNoteEntryKind.highlight,
              ),
      )),
    );
  }
}

class _ShellSearchTextHit extends StatelessWidget {
  const _ShellSearchTextHit({
    super.key,
    required this.book,
    required this.match,
    required this.query,
    required this.onChosen,
  });

  final FlutterLibraryBook book;
  final FlutterSearchMatch match;
  final String query;
  final ValueChanged<ShellSearchChoice> onChosen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unit = match.unit.toInt();
    return _ShellSearchHit(
      leading: const Icon(LucideIcons.text, size: 14),
      meta: book.format == FlutterBookFormat.pdf
          ? l10n.readerPageNumber(unit + 1)
          : l10n.readerChapterNumber(unit + 1),
      snippet: switch (match.contextOffset) {
        final at? => _Snippet.around(
          match.context,
          at.toInt(),
          match.length.toInt(),
        ),
        null => _Snippet.inContext(match.context, query),
      },
      editorial: true,
      onPressed: () => onChosen((
        book,
        (
          unit: unit,
          offset: match.offset.toInt(),
          length: match.length.toInt(),
          annotationId: null,
          note: null,
        ),
      )),
    );
  }
}

/// A snippet around a match that starts and ends on whole words: the words
/// before the match, the match, and the words after it.
final class _Snippet {
  const _Snippet(this.before, this.match, this.after);

  /// The words around [length] Unicode scalars of [text] from [offset].
  factory _Snippet.around(String text, int offset, int length) {
    final scalars = text.runes.toList();
    final start = offset.clamp(0, scalars.length);
    final end = (offset + length).clamp(start, scalars.length);
    String part(int from, int to) => String.fromCharCodes(scalars, from, to);
    var from = (start - _context).clamp(0, start);
    var to = (end + _context).clamp(end, scalars.length);
    // Cut at a space, so the snippet holds no part of a word.
    if (from > 0) {
      final space = part(from, start).indexOf(' ');
      from = space < 0
          ? start
          : from + part(from, start).substring(0, space).runes.length + 1;
    }
    if (to < scalars.length) {
      final after = part(end, to);
      final space = after.lastIndexOf(' ');
      to = space < 0 ? end : end + after.substring(0, space).runes.length;
    }
    return _Snippet(
      '${from > 0 ? '… ' : ''}${part(from, start)}',
      part(start, end),
      '${part(end, to)}${to < scalars.length ? ' …' : ''}',
    );
  }

  /// [context] with [query]'s first occurrence marked.
  factory _Snippet.inContext(String context, String query) {
    final at = context.toLowerCase().indexOf(query.toLowerCase());
    if (at < 0 || query.isEmpty) return _Snippet('', '', context);
    return _Snippet.around(
      context,
      context.substring(0, at).runes.length,
      context.substring(at, at + query.length).runes.length,
    );
  }

  /// Scalars kept on each side of a match.
  static const _context = 60;

  final String before;
  final String match;
  final String after;

  String get text => '$before$match$after';
}
