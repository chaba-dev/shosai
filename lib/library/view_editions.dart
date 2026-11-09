part of 'view.dart';

class _EditionCard extends StatelessWidget {
  const _EditionCard({
    super.key,
    required this.edition,
    required this.model,
    required this.shelf,
    required this.open,
    required this.loadCover,
    required this.loadSourceCover,
    this.onOpen,
    this.onChoose,
  });
  final BookEdition edition;
  final LibraryModel model;
  final LibraryShelf shelf;
  final bool open;
  final bool Function(int) loadCover;
  final bool Function(BookLocator)? loadSourceCover;
  final VoidCallback? onOpen;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final file = edition.displayFile;
    final coverFile = edition.coverFile;
    final book = model.books
        .where((b) => b.bookId == coverFile.book?.id)
        .firstOrNull;
    final source = model.sourceFiles
        .where((s) => s.locator == coverFile.locator)
        .firstOrNull;
    var readingFile = edition.preferred ?? file;
    if (edition.preferred == null) {
      for (final candidate in edition.files) {
        if (candidate.book != null &&
            (readingFile.book == null ||
                (candidate.book!.lastRead ?? '').compareTo(
                      readingFile.book!.lastRead ?? '',
                    ) >
                    0)) {
          readingFile = candidate;
        }
      }
    }
    final progress = readingFile.book?.progress ?? 0.0;
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final status = readingFile.unavailable
        ? l10n.libraryBookUnavailable
        : readingFile.book == null
        ? readingFile.source
        : shellReadingStatus(l10n, progress);
    return Stack(
      children: [
        ShadButton.raw(
          variant: ShadButtonVariant.ghost,
          width: double.infinity,
          height: double.infinity,
          padding: EdgeInsets.zero,
          backgroundColor: _triggerNoFill,
          hoverBackgroundColor: _triggerNoFill,
          pressedBackgroundColor: _triggerNoFill,
          foregroundColor: palette.ink,
          onPressed: onOpen,
          child: Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: _cardSpacing,
              children: [
                if (book != null)
                  LibraryBookCover(
                    book: book,
                    cover: model.covers[book.bookId],
                    demandRevision: model.coverRevision,
                    loadCover: loadCover,
                    type: shelf.coverType,
                    shadow: palette.shelfCoverShadow,
                  )
                else if (source != null)
                  SizedBox(
                    height: shelf.columnWidth * 1.5,
                    child: _SourceFileCover(
                      file: source,
                      cover: model.sourceCovers[source.locator],
                      demandRevision: model.coverRevision,
                      loadCover: loadSourceCover,
                      type: shelf.coverType,
                    ),
                  ),
                SizedBox(
                  height: _cardTitleBox(context, shelf),
                  child: Text(
                    file.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: _cardTitleStyle(shelf).copyWith(color: palette.ink),
                  ),
                ),
                SizedBox(
                  height: _cardMetadataBox(context, shelf),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: _cardMetadataRunSpacing,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: _cardMetadataRunSpacing,
                          children: [
                            for (final format in [
                              BookFormat.epub,
                              BookFormat.pdf,
                            ])
                              if (edition.formats.contains(format))
                                ShellFormatBadge(
                                  format: FlutterBookFormat.values.byName(
                                    format.name,
                                  ),
                                ),
                          ],
                        ),
                        Text(
                          status,
                          maxLines: _cardMetadataWraps(context)
                              ? _cardMetadataWrappedLines
                              : 1,
                          overflow: TextOverflow.ellipsis,
                          style: shosaiInterfaceStyleForText(
                            _cardMetaStyle(context),
                            status,
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
                    ),
                  ),
                ),
                SizedBox(
                  height: _cardProgressHeight,
                  child: progress > 0 && progress < 1
                      ? ShellProgressBar(
                          value: progress,
                          height: _cardProgressHeight,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: ShadTooltip(
            builder: (_) => Text(AppLocalizations.of(context).editionReadAs),
            child: ShadButton.ghost(
              key: ValueKey('edition-read-as-${edition.id}'),
              onPressed: onChoose,
              width: 40,
              height: 40,
              padding: EdgeInsets.zero,
              child: const _CardTriggerSurface(active: false),
            ),
          ),
        ),
      ],
    );
  }
}

/// The approved Quick picker. Selecting a file closes the adapter; the
/// controller owns admission, persistence and reader navigation.
class LibraryQuickPicker extends StatelessWidget {
  const LibraryQuickPicker({super.key, required this.edition, this.format});
  final BookEdition edition;
  final FlutterBookFormat? format;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    void choose(EditionAction action, EditionFile file) =>
        Navigator.pop(context, EditionChoice(action, file.key));
    return ShadDialog(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height - 32,
      ),
      title: Text(l10n.editionReadAs),
      description: Text(
        edition.displayFile.title,
        style: shellEditorialStyle(24, 30).copyWith(color: palette.ink),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.editionPickerExplanation,
                style: shellInterfaceStyle(
                  13,
                  19,
                ).copyWith(color: palette.inkMuted),
              ),
              const SizedBox(height: 16),
              for (final type in [BookFormat.epub, BookFormat.pdf])
                if (format == null || type.name == format!.name)
                  for (final file in edition.files.where(
                    (f) => f.format == type,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surface,
                          border: Border.all(color: palette.line),
                          borderRadius: BorderRadius.circular(
                            ShosaiTokens.radiusSmall,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ShadButton.raw(
                                    variant: ShadButtonVariant.ghost,
                                    height: 0,
                                    padding: const EdgeInsets.all(16),
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    // Availability is the last read's result,
                                    // not a permanent ban on verifying recovery.
                                    onPressed: () =>
                                        choose(EditionAction.read, file),
                                    child: Flexible(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            spacing: 8,
                                            children: [
                                              ShellFormatBadge(
                                                format: FlutterBookFormat.values
                                                    .byName(type.name),
                                              ),
                                              if (edition.preferredKey ==
                                                  file.key)
                                                Flexible(
                                                  child: Text(
                                                    l10n.editionLastUsed,
                                                    style:
                                                        shellInterfaceStyle(
                                                          12,
                                                          16,
                                                        ).copyWith(
                                                          color: palette.accent,
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            file.name,
                                            softWrap: true,
                                            style: shellInterfaceStyle(14, 20),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            [
                                              file.book != null &&
                                                      file.locations.isEmpty
                                                  ? l10n.editionOnDevice
                                                  : file.source,
                                              if (file.size case final bytes?)
                                                _editionSize(bytes),
                                              if (file.unavailable)
                                                l10n.libraryBookUnavailable,
                                              if (file.book case final book?
                                                  when book.progress > 0)
                                                shellReadingStatus(
                                                  l10n,
                                                  book.progress,
                                                ),
                                            ].join(' · '),
                                            style: shellInterfaceStyle(
                                              12,
                                              18,
                                            ).copyWith(color: palette.inkMuted),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (edition.files.length > 1 ||
                                    file.book != null)
                                  PopupMenuButton<EditionAction>(
                                    tooltip: l10n.editionFileActions,
                                    icon: Icon(
                                      LucideIcons.ellipsis,
                                      size: 18,
                                      color: palette.inkMuted,
                                    ),
                                    onSelected: (action) =>
                                        choose(action, file),
                                    itemBuilder: (_) => [
                                      if (file.book case final book?
                                          when file.locations.isNotEmpty)
                                        PopupMenuItem(
                                          value: EditionAction.keep,
                                          child: Text(
                                            book.keptOnDevice
                                                ? l10n.cardStopKeeping
                                                : l10n.cardKeepOnDevice,
                                          ),
                                        ),
                                      if (edition.files.length > 1)
                                        PopupMenuItem(
                                          value: EditionAction.separate,
                                          child: Text(l10n.editionSeparate),
                                        ),
                                      if (file.book != null)
                                        PopupMenuItem(
                                          value: EditionAction.remove,
                                          child: Text(
                                            l10n.cardRemoveFromLibrary,
                                          ),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                            if (file.locations.isNotEmpty)
                              ExpansionTile(
                                title: Text(
                                  l10n.editionLocations(file.locations.length),
                                  style: shellInterfaceStyle(12, 18),
                                ),
                                children: [
                                  for (final location in file.locations)
                                    ListTile(
                                      dense: true,
                                      title: Text(location.label),
                                      subtitle: Text(location.key),
                                      trailing: location.unavailable
                                          ? Icon(
                                              LucideIcons.cloudOff,
                                              color: palette.inkMuted,
                                              size: 16,
                                            )
                                          : null,
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
              const SizedBox(height: 4),
              ShadButton.ghost(
                onPressed: () => Navigator.pop(
                  context,
                  const EditionChoice(EditionAction.group),
                ),
                child: Text(
                  edition.possibleMatches.isEmpty
                      ? l10n.editionGroupWith
                      : l10n.editionReviewMatches(
                          edition.possibleMatches.length,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _editionSize(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).ceil()} KB';

class _GroupEditionDialog extends StatefulWidget {
  const _GroupEditionDialog({required this.edition, required this.choices});
  final BookEdition edition;
  final List<BookEdition> choices;
  @override
  State<_GroupEditionDialog> createState() => _GroupEditionDialogState();
}

class _GroupEditionDialogState extends State<_GroupEditionDialog> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final choices =
        widget.choices
            .where(
              (e) => e.files.any(
                (f) => '${f.title} ${f.author ?? ''} ${f.name}'
                    .toLowerCase()
                    .contains(_query.toLowerCase()),
              ),
            )
            .toList()
          ..sort((a, b) {
            final aSuggested = widget.edition.possibleMatches.containsKey(a.id);
            final bSuggested = widget.edition.possibleMatches.containsKey(b.id);
            if (aSuggested != bSuggested) return aSuggested ? -1 : 1;
            return a.displayFile.title.compareTo(b.displayFile.title);
          });
    return ShadDialog(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height - 32,
      ),
      title: Text(
        widget.edition.possibleMatches.isEmpty
            ? l10n.editionGroupWith
            : l10n.editionPossibleMatches,
      ),
      description: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.edition.displayFile.title,
            style: shellEditorialStyle(24, 30),
          ),
          const SizedBox(height: 8),
          Text(
            widget.edition.possibleMatches.isEmpty
                ? l10n.editionGroupExplanation
                : l10n.editionMatchExplanation,
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShadInput(
              placeholder: Text(l10n.searchLibraryPlaceholder),
              onChanged: (query) => setState(() => _query = query),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: choices.length,
                itemBuilder: (context, index) {
                  final choice = choices[index];
                  final evidence = widget.edition.possibleMatches[choice.id];
                  return ListTile(
                    title: Text(choice.displayFile.title),
                    subtitle: Text(
                      [
                        [
                          ?choice.displayFile.author,
                          choice.formats.map((f) => f.displayName).join(' · '),
                        ].join(' · '),
                        if (evidence != null)
                          evidence
                              .map(
                                (reason) => switch (reason) {
                                  EditionMatchEvidence.title =>
                                    l10n.editionMatchTitle,
                                  EditionMatchEvidence.filename =>
                                    l10n.editionMatchFilename,
                                  EditionMatchEvidence.folder =>
                                    l10n.editionMatchFolder,
                                  EditionMatchEvidence.isbn =>
                                    l10n.editionMatchIsbn,
                                  EditionMatchEvidence.metadataConflict =>
                                    l10n.editionMatchConflict,
                                },
                              )
                              .join(' · '),
                        if (evidence != null)
                          choice.files.map((file) => file.name).join('\n'),
                      ].join('\n'),
                    ),
                    onTap: () => Navigator.pop(context, choice.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
