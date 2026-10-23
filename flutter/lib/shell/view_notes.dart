part of 'view.dart';

/// The Notes place (`NotesPanel`, All books): every highlight and note across
/// the library, books most recently read first and each book's notes in
/// reading order. Choosing a card opens its book at its place.
class ShellNotesPage extends StatelessWidget {
  const ShellNotesPage({
    super.key,
    required this.layout,
    required this.model,
    required this.onOpen,
    required this.onRetry,
    required this.onMore,
  });

  final ShellLayout layout;
  final ShellNotesModel model;
  final void Function(FlutterBookNotes book, FlutterNoteEntry note) onOpen;
  final VoidCallback onRetry;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final gutter = layout == ShellLayout.phone ? 16.0 : 48.0;
    final count = model.books.fold(0, (sum, book) => sum + book.notes.length);
    final error = model.error;
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          shellPlaceLabel(l10n, ShellPlace.notes),
          style: shellScreenTitleStyle(layout).copyWith(color: palette.ink),
        ),
      ),
      if (model.status == ShellNotesStatus.loaded && count > 0)
        Padding(
          padding: const EdgeInsets.only(top: ShosaiTokens.space2),
          child: Text(
            l10n.readerNotesCount(count),
            key: const ValueKey('shell-notes-count'),
            style: shellInterfaceStyle(
              14,
              20,
            ).copyWith(color: palette.inkMuted),
          ),
        ),
      const SizedBox(height: ShosaiTokens.space6),
      ...switch (model.status) {
        ShellNotesStatus.idle || ShellNotesStatus.loading => [
          _ShellNotesMessage(
            key: const ValueKey('shell-notes-loading'),
            body: l10n.shellNotesLoading,
          ),
        ],
        ShellNotesStatus.failed => [
          _ShellNotesMessage(
            key: const ValueKey('shell-notes-error'),
            body: error ?? '',
            action: ShadButton.outline(
              key: const ValueKey('shell-notes-retry'),
              height: shosaiShadButtonHeight(context),
              onPressed: onRetry,
              child: Text(l10n.libraryRetry),
            ),
          ),
        ],
        ShellNotesStatus.loaded when count == 0 => [
          _ShellNotesMessage(
            key: const ValueKey('shell-notes-empty'),
            heading: l10n.shellNotesEmptyHeading,
            body: l10n.shellNotesEmptyBody,
          ),
        ],
        ShellNotesStatus.loaded => [
          for (final book in model.books)
            for (final note in book.notes)
              Padding(
                padding: const EdgeInsets.only(bottom: ShosaiTokens.space3),
                child: ShellNoteCard(
                  key: ValueKey('shell-note-${note.id}'),
                  book: book.book,
                  note: note,
                  onOpen: () => onOpen(book, note),
                ),
              ),
          if (error != null)
            _ShellNotesMessage(
              key: const ValueKey('shell-notes-more-error'),
              body: error,
              action: ShadButton.outline(
                key: const ValueKey('shell-notes-more-retry'),
                height: shosaiShadButtonHeight(context),
                onPressed: onMore,
                child: Text(l10n.libraryRetry),
              ),
            )
          else if (model.hasMore)
            Center(
              child: ShadButton.outline(
                key: const ValueKey('shell-notes-more'),
                height: shosaiShadButtonHeight(context),
                onPressed: model.appending ? null : onMore,
                child: Text(
                  model.appending
                      ? l10n.libraryLoadingMore
                      : l10n.shellNotesMore,
                ),
              ),
            ),
        ],
      },
    ];
    return ColoredBox(
      color: palette.canvas,
      child: SafeArea(
        bottom: false,
        child: ListView(
          key: const ValueKey('shell-notes'),
          padding: EdgeInsets.fromLTRB(gutter, gutter * .75, gutter, gutter),
          children: [
            for (final child in children)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: child,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A Notes place state: a heading, what it means and an action.
class _ShellNotesMessage extends StatelessWidget {
  const _ShellNotesMessage({
    super.key,
    this.heading,
    required this.body,
    this.action,
  });

  final String? heading;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final heading = this.heading;
    final action = this.action;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          spacing: 8,
          children: [
            if (heading != null)
              Text(
                heading,
                textAlign: TextAlign.center,
                style: shellEditorialStyle(22, 26).copyWith(color: palette.ink),
              ),
            Text(
              body,
              textAlign: TextAlign.center,
              style: shosaiInterfaceStyleForText(
                shellInterfaceStyle(14, 20).copyWith(color: palette.inkMuted),
                body,
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// One note or highlight across the library (`NoteCard`, All books): the
/// meta line leads with the format badge and the book title, then its place;
/// the quote in the editorial face, then the note. Choosing it opens the
/// book there.
class ShellNoteCard extends StatefulWidget {
  const ShellNoteCard({
    super.key,
    required this.book,
    required this.note,
    required this.onOpen,
  });

  final FlutterLibraryBook book;
  final FlutterNoteEntry note;
  final VoidCallback? onOpen;

  @override
  State<ShellNoteCard> createState() => _ShellNoteCardState();
}

class _ShellNoteCardState extends State<ShellNoteCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final note = widget.note;
    final pdf = widget.book.format == FlutterBookFormat.pdf;
    final unit = note.unit;
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
    final meta = place.isEmpty
        ? widget.book.title
        : '${widget.book.title} · $place';
    final quote = note.quote?.trim();
    final body = note.body?.trim();
    final metaStyle = shellInterfaceStyle(
      12,
      16,
    ).copyWith(color: palette.inkMuted);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
          boxShadow: [
            ...palette.raised,
            if (_hovered) BoxShadow(color: palette.lineStrong, spreadRadius: 1),
          ],
        ),
        child: InkWell(
          key: ValueKey('shell-note-${note.id}-open'),
          borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
          onTap: widget.onOpen,
          child: Padding(
            padding: const EdgeInsets.all(ShosaiTokens.space3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 6,
              children: [
                Row(
                  spacing: 6,
                  children: [
                    switch (note.color) {
                      final color? => ShellHighlightDot(color: color),
                      null => Icon(
                        note.kind == FlutterNoteEntryKind.book
                            ? LucideIcons.book
                            : LucideIcons.file,
                        size: 14,
                        color: palette.inkMuted,
                      ),
                    },
                    ShellFormatBadge(format: widget.book.format),
                    Expanded(
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: shosaiInterfaceStyleForText(metaStyle, meta),
                      ),
                    ),
                  ],
                ),
                if (quote != null && quote.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.only(left: ShosaiTokens.space3),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: palette.line, width: 2),
                      ),
                    ),
                    child: Text(
                      quote,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: shellEditorialStyle(
                        15,
                        23,
                        weight: FontWeight.w400,
                      ).copyWith(color: palette.ink),
                    ),
                  ),
                if (body != null && body.isNotEmpty)
                  Text(
                    body,
                    style: shosaiInterfaceStyleForText(
                      shellInterfaceStyle(14, 20).copyWith(color: palette.ink),
                      body,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A highlight's colour on its note card (`sh-dot`).
class ShellHighlightDot extends StatelessWidget {
  const ShellHighlightDot({super.key, required this.color});

  final FlutterHighlightColor color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: switch (color) {
        FlutterHighlightColor.yellow => ShosaiTokens.colorSwatchYellow,
        FlutterHighlightColor.green => ShosaiTokens.colorSwatchGreen,
        FlutterHighlightColor.blue => ShosaiTokens.colorSwatchBlue,
        FlutterHighlightColor.pink => ShosaiTokens.colorSwatchPink,
        FlutterHighlightColor.purple => ShosaiTokens.colorSwatchPurple,
      },
    ),
  );
}
