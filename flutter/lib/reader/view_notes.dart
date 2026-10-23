part of 'view.dart';

/// The height, at 100% text, below which the Notes panel scrolls as a whole:
/// its heading, a card, and the foot.
const double _notesPanelMinHeight = 260;

/// The Notes panel (`NotesPanel`): the book's notes and highlights, the book
/// notes first and then a group per section in reading order, with **Page
/// note** and **Book note** in the foot. Highlights are made from the page.
class _ReaderNotesPanel extends StatelessWidget {
  const _ReaderNotesPanel({required this.model, required this.dispatch});

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final enabled = _readerChromeEnabled(model);
    final count = model.annotations.length + model.notes.length;
    final canWrite = enabled && model.document?.bookId != null;
    // As in the Contents panel, a short window (a scaled interface, a
    // keyboard) scrolls the panel as a whole, so its heading and foot stay
    // reachable; otherwise only the cards scroll between them.
    final minHeight =
        _notesPanelMinHeight *
        math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const ValueKey('reader-notes-panel-scroll'),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(constraints.maxHeight, minHeight),
          ),
          child: _column(l10n, palette, enabled, count, canWrite: canWrite),
        ),
      ),
    );
  }

  Widget _column(
    AppLocalizations l10n,
    ShellPalette palette,
    bool enabled,
    int count, {
    required bool canWrite,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReaderPanelHeading(
          headingKey: const ValueKey('reader-notes-heading'),
          title: l10n.readerNotesAction,
          closeKey: const ValueKey('reader-notes-close'),
          closeLabel: l10n.readerCloseNotes,
          onClose: () => dispatch(const ReaderPanelToggled(ReaderPanel.notes)),
          actions: [
            // Highlights saved against an earlier version of the book can be
            // associated with this one; a failed load can be retried.
            if (model.document != null)
              _ReaderToolButton(
                key: const ValueKey('reader-notes-association'),
                icon: model.annotationsReady
                    ? LucideIcons.link
                    : LucideIcons.refreshCw,
                label: model.annotationsReady
                    ? 'Associate highlights from an earlier version…'
                    : 'Retry loading highlights',
                onPressed: enabled && model.annotationOperations.isEmpty
                    ? () => dispatch(
                        model.annotationsReady
                            ? const ReaderAnnotationAssociationRequested()
                            : const ReaderAnnotationReloadRequested(),
                      )
                    : null,
              ),
          ],
        ),
        if (count > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShosaiTokens.space4,
              0,
              ShosaiTokens.space4,
              ShosaiTokens.space2,
            ),
            child: Text(
              l10n.readerNotesCount(count),
              key: const ValueKey('reader-notes-count'),
              style: shellInterfaceStyle(
                12,
                16,
              ).copyWith(color: palette.inkMuted),
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('reader-notes-scroll'),
            padding: const EdgeInsets.fromLTRB(
              ShosaiTokens.space3,
              ShosaiTokens.space1,
              ShosaiTokens.space3,
              ShosaiTokens.space3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: ShosaiTokens.space2,
              children: count == 0
                  ? [
                      _ReaderPanelNote(
                        key: const ValueKey('reader-notes-empty'),
                        text: l10n.readerNotesEmpty,
                      ),
                    ]
                  : _cards(l10n, enabled),
            ),
          ),
        ),
        if (model.document != null)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.line)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(ShosaiTokens.space3),
              child: Row(
                spacing: ShosaiTokens.space2,
                children: [
                  Expanded(
                    child: _ReaderNotesFootAction(
                      key: const ValueKey('reader-notes-add-page'),
                      icon: LucideIcons.file,
                      label: l10n.readerPageNoteTitle,
                      onPressed: canWrite && !model.notesBusy
                          ? () => dispatch(const ReaderPageNoteRequested())
                          : null,
                    ),
                  ),
                  Expanded(
                    child: _ReaderNotesFootAction(
                      key: const ValueKey('reader-notes-add-book'),
                      icon: LucideIcons.book,
                      label: l10n.readerBookNoteTitle,
                      onPressed: canWrite && !model.notesBusy
                          ? () => dispatch(const ReaderBookNoteRequested())
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// The book notes, then each section's page notes and highlights in
  /// reading order under the section's title.
  List<Widget> _cards(AppLocalizations l10n, bool enabled) {
    final pdf = model.document?.format == FlutterBookFormat.pdf;
    final entries = model.contents.status == ReaderContentsStatus.ready
        ? model.contents.entries
        : const <ReaderContentsEntry>[];
    final placed = <({int unit, int position, Widget Function(String?) card})>[
      for (final note in model.notes)
        if (note.unit case final unit?)
          (
            unit: unit.toInt(),
            position: note.offset?.toInt() ?? 0,
            card: (_) => _placeNoteCard(l10n, note, enabled, pdf: pdf),
          ),
      for (final annotation in model.annotations)
        (
          unit: annotation.unit.toInt(),
          position: annotation.textRange?.start.toInt() ?? 0,
          card: (section) =>
              _highlightCard(l10n, annotation, section, pdf: pdf),
        ),
    ];
    // A stable sort: notes and highlights at one place keep their order.
    final order = [for (var i = 0; i < placed.length; i++) i]
      ..sort((i, j) {
        final (a, b) = (placed[i], placed[j]);
        if (a.unit != b.unit) return a.unit.compareTo(b.unit);
        if (a.position != b.position) return a.position.compareTo(b.position);
        return i.compareTo(j);
      });
    final cards = <Widget>[
      for (final note in model.notes)
        if (note.unit == null) _placeNoteCard(l10n, note, enabled, pdf: pdf),
    ];
    Object? group;
    for (final i in order) {
      final item = placed[i];
      final section = _noteSection(
        l10n,
        entries,
        item.unit,
        item.position,
        pdf: pdf,
      );
      // Sections are told apart by their entry, not their title: two
      // chapters may both have a "Summary".
      if (section != null && section.id != group) {
        cards.add(
          _ReaderPanelGroup(
            key: ValueKey('reader-notes-group-${cards.length}'),
            text: section.title,
          ),
        );
      }
      group = section?.id;
      cards.add(item.card(section?.title));
    }
    return cards;
  }

  /// Card [card]'s draft, when its note is being edited.
  String? _editOf(String card) => switch (model.noteEdit) {
    final edit? when edit.card == card => edit.text,
    _ => null,
  };

  Widget _placeNoteCard(
    AppLocalizations l10n,
    FlutterNote note,
    bool enabled, {
    required bool pdf,
  }) {
    final unit = note.unit?.toInt();
    // An orphaned note's stored place is not in this edition.
    final found = switch (note.resolution) {
      FlutterAnnotationResolution.exact ||
      FlutterAnnotationResolution.recovered => true,
      FlutterAnnotationResolution.ambiguous ||
      FlutterAnnotationResolution.orphaned => false,
    };
    return _ReaderNoteCard(
      key: ValueKey('reader-place-note-${note.id}'),
      id: 'reader-place-note-${note.id}',
      edit: _editOf('reader-place-note-${note.id}'),
      dispatch: dispatch,
      leading: Icon(
        unit == null ? LucideIcons.book : LucideIcons.file,
        size: 14,
      ),
      meta:
          '${unit == null
              ? l10n.readerBookNoteTitle
              : pdf
              ? l10n.readerPageNoteAt(unit + 1)
              : l10n.readerPageNoteTitle}'
          '${_annotationResolutionSuffix(l10n, note.resolution)}',
      body: note.body,
      enabled: enabled && !model.notesBusy,
      // A page note opens its place; the book is already open where it was
      // left, so a book note, or a page note whose place is lost, opens its
      // editor instead.
      onOpen: unit == null || !found
          ? null
          : () => dispatch(
              ReaderNoteNavigated(unit, offset: note.offset?.toInt()),
            ),
      onSave: (body) => dispatch(ReaderNoteSaved(note.id, body)),
      deleteLabel: l10n.readerDeleteNote,
      onDelete: () => dispatch(ReaderNoteDeleted(note.id)),
    );
  }

  Widget _highlightCard(
    AppLocalizations l10n,
    FlutterAnnotation annotation,
    String? section, {
    required bool pdf,
  }) {
    final unit = annotation.unit.toInt();
    final place = pdf
        ? l10n.readerPageNumber(unit + 1)
        : section ?? l10n.readerChapterNumber(unit + 1);
    return _ReaderNoteCard(
      key: ValueKey('reader-annotation-${annotation.id}'),
      id: 'reader-annotation-${annotation.id}',
      edit: _editOf('reader-annotation-${annotation.id}'),
      dispatch: dispatch,
      leading: _ReaderNoteDot(color: annotation.color),
      meta:
          '$place'
          '${_annotationResolutionSuffix(l10n, annotation.resolution)}',
      quote: annotation.quote,
      body: annotation.body,
      clearable: true,
      enabled:
          _readerChromeEnabled(model) && model.annotationOperations.isEmpty,
      onOpen: () => dispatch(ReaderAnnotationNavigated(annotation.id)),
      onSave: (body) =>
          dispatch(ReaderAnnotationNoteSaved(annotation.id, body)),
      onRecolor: () => dispatch(
        ReaderAnnotationUpdated(
          annotation.id,
          _nextColor(annotation.color),
          annotation.body,
        ),
      ),
      deleteLabel: l10n.readerDeleteHighlight,
      onDelete: () => dispatch(ReaderAnnotationDeleted(annotation.id)),
    );
  }
}

/// The section a note at [unit] and [position] sits in: the last contents
/// entry at or before it, identified by its index. Without one, an EPUB
/// chapter is named by its number and identified by its unit, and a PDF page
/// has no section.
({Object id, String title})? _noteSection(
  AppLocalizations l10n,
  List<ReaderContentsEntry> entries,
  int unit,
  int position, {
  required bool pdf,
}) {
  ReaderContentsEntry? section;
  var index = -1;
  for (final (i, entry) in entries.indexed) {
    final offset = entry.offset ?? 0;
    final before =
        entry.unit < unit || (entry.unit == unit && offset <= position);
    if (!before) continue;
    final best = section;
    if (best == null ||
        entry.unit > best.unit ||
        (entry.unit == best.unit && offset >= (best.offset ?? 0))) {
      section = entry;
      index = i;
    }
  }
  if (section != null) {
    final title = section.title.trim();
    return (
      id: index,
      title: title.isEmpty ? l10n.readerChapterNumber(section.unit + 1) : title,
    );
  }
  return pdf
      ? null
      : (id: 'unit $unit', title: l10n.readerChapterNumber(unit + 1));
}

/// A highlight's colour on its note card (`sh-dot`).
class _ReaderNoteDot extends StatelessWidget {
  const _ReaderNoteDot({required this.color});

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

/// One of the Notes panel's foot actions: a secondary button with its icon.
class _ReaderNotesFootAction extends StatelessWidget {
  const _ReaderNotesFootAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ShadButton.outline(
    height: shosaiShadButtonHeight(context),
    leading: Icon(icon, size: 16),
    onPressed: onPressed,
    child: Flexible(
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

/// One note or highlight (`NoteCard`): its meta line, the quote in the
/// editorial face, then the note.
///
/// Choosing the card opens its place. The note is edited in place with
/// **Save** and **Cancel**; the card's other actions are in its menu, opened
/// by its actions button, a secondary click or long press, or the ContextMenu
/// key or Shift+F10 while the card has focus.
class _ReaderNoteCard extends StatefulWidget {
  const _ReaderNoteCard({
    super.key,
    required this.id,
    required this.edit,
    required this.dispatch,
    required this.leading,
    required this.meta,
    this.quote,
    this.body,
    this.clearable = false,
    required this.enabled,
    required this.onOpen,
    required this.onSave,
    this.onRecolor,
    required this.deleteLabel,
    required this.onDelete,
  });

  /// The prefix of the card's control keys, and its identity in the
  /// model's in-place edit.
  final String id;

  /// The draft, while the card's note is being edited in place.
  final String? edit;
  final void Function(ReaderMessage) dispatch;
  final Widget leading;
  final String meta;
  final String? quote;
  final String? body;

  /// Whether the note can be saved empty, which removes it (a highlight's).
  final bool clearable;
  final bool enabled;

  /// Opens the card's place; null opens the editor instead.
  final VoidCallback? onOpen;
  final void Function(String body) onSave;
  final VoidCallback? onRecolor;
  final String deleteLabel;
  final VoidCallback onDelete;

  @override
  State<_ReaderNoteCard> createState() => _ReaderNoteCardState();
}

class _ReaderNoteCardState extends State<_ReaderNoteCard> {
  final ShadContextMenuController _menu = ShadContextMenuController();

  /// The editor's text, made from the model's draft when the edit starts and
  /// reporting each change back to it.
  TextEditingController? _draft;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _syncDraft();
  }

  @override
  void didUpdateWidget(_ReaderNoteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDraft();
  }

  void _syncDraft() {
    final edit = widget.edit;
    final draft = _draft;
    if (edit == null) {
      if (draft == null) return;
      _draft = null;
      draft.dispose();
    } else if (draft == null) {
      _draft = TextEditingController(text: edit)..addListener(_draftChanged);
    } else if (draft.text != edit) {
      draft.text = edit;
    }
  }

  // Every change is reported: the controller compares it with the model's
  // draft, which may be newer than the one this card was built with.
  void _draftChanged() {
    if (_draft case final draft?) {
      widget.dispatch(ReaderNoteDraftChanged(draft.text));
    }
  }

  @override
  void dispose() {
    _menu.dispose();
    _draft?.dispose();
    super.dispose();
  }

  void _openMenu() {
    if (widget.enabled && !_menu.isOpen) _menu.show();
  }

  void _edit() {
    if (!widget.enabled || widget.edit != null) return;
    widget.dispatch(ReaderNoteEditStarted(widget.id, widget.body ?? ''));
  }

  void _cancel() {
    if (widget.edit != null) {
      widget.dispatch(const ReaderNoteEditCancelled());
    }
  }

  bool get _canSave {
    final edit = widget.edit;
    return widget.enabled &&
        edit != null &&
        (edit.trim().isNotEmpty || widget.clearable);
  }

  void _save() {
    // The field's text: its last change may not be rebuilt into [edit] yet.
    final body = _draft?.text;
    if (!widget.enabled || body == null) return;
    if (body.trim().isEmpty && !widget.clearable) return;
    widget.onSave(body);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final draft = _draft;
    final hasBody = widget.body?.trim().isNotEmpty ?? false;
    final quote = widget.quote?.trim();
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
        boxShadow: [
          ...palette.raised,
          if (_hovered && draft == null)
            BoxShadow(color: palette.lineStrong, spreadRadius: 1),
        ],
      ),
      child: InkWell(
        key: ValueKey('${widget.id}-open'),
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
        onTap: !widget.enabled || draft != null ? null : widget.onOpen ?? _edit,
        child: Padding(
          padding: const EdgeInsets.all(ShosaiTokens.space3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: [
              Row(
                spacing: 6,
                children: [
                  IconTheme.merge(
                    data: IconThemeData(color: palette.inkMuted),
                    child: widget.leading,
                  ),
                  Expanded(
                    child: Text(
                      widget.meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: shosaiInterfaceStyleForText(
                        shellInterfaceStyle(
                          12,
                          16,
                        ).copyWith(color: palette.inkMuted),
                        widget.meta,
                      ),
                    ),
                  ),
                  _ReaderToolButton(
                    key: ValueKey('${widget.id}-actions'),
                    icon: LucideIcons.ellipsis,
                    label: l10n.readerNoteActions,
                    onPressed: widget.enabled && draft == null
                        ? _openMenu
                        : null,
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
              if (draft != null)
                _editor(l10n, draft)
              else if (hasBody)
                Text(
                  widget.body!,
                  style: shosaiInterfaceStyleForText(
                    shellInterfaceStyle(14, 20).copyWith(color: palette.ink),
                    widget.body!,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
        const SingleActivator(LogicalKeyboardKey.f10, shift: true): _openMenu,
      },
      // A raw listener is not a gesture-arena competitor, so a secondary
      // press opens the menu wherever it lands in the card.
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kSecondaryButton) _openMenu();
        },
        child: ShadContextMenuRegion(
          controller: _menu,
          tapEnabled: false,
          longPressEnabled: widget.enabled && draft == null,
          items: [
            ShadContextMenuItem(
              key: ValueKey('${widget.id}-edit'),
              enabled: widget.enabled,
              onPressed: _edit,
              child: Text(hasBody ? l10n.readerEditNote : l10n.readerAddNote),
            ),
            if (widget.onRecolor case final recolor?)
              ShadContextMenuItem(
                key: ValueKey('${widget.id}-color'),
                enabled: widget.enabled,
                onPressed: recolor,
                child: Text(l10n.readerChangeColor),
              ),
            ShadContextMenuItem(
              key: ValueKey('${widget.id}-delete'),
              enabled: widget.enabled,
              onPressed: widget.onDelete,
              child: Text(widget.deleteLabel),
            ),
          ],
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: card,
          ),
        ),
      ),
    );
  }

  /// The editor: Escape cancels wherever its focus is, on the field or on
  /// either button.
  Widget _editor(AppLocalizations l10n, TextEditingController draft) =>
      CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            ShadInput(
              key: const ValueKey('reader-note-edit-field'),
              controller: draft,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: ShosaiTokens.space2,
              runSpacing: ShosaiTokens.space2,
              children: [
                ShadButton.outline(
                  key: const ValueKey('reader-note-edit-cancel'),
                  height: shosaiShadButtonHeight(context),
                  onPressed: _cancel,
                  child: Text(l10n.readerNoteCancel),
                ),
                // A busy reader keeps the draft and saves it once it can.
                ShadButton(
                  key: const ValueKey('reader-note-edit-save'),
                  height: shosaiShadButtonHeight(context),
                  onPressed: _canSave ? _save : null,
                  child: Text(l10n.readerNoteSave),
                ),
              ],
            ),
          ],
        ),
      );
}
