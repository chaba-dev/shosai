part of 'view.dart';

/// Search and Browse share one place. This view owns no catalog IO; every
/// query, selection, refresh and platform-link intent goes to its controller.
class ShellBrowsePage extends StatefulWidget {
  const ShellBrowsePage({
    super.key,
    required this.layout,
    required this.model,
    required this.local,
    required this.dispatch,
    required this.onChosen,
    this.searchFocus,
  });
  final ShellLayout layout;
  final BrowseModel model;
  final ShellSearchModel local;
  final ValueChanged<BrowseMessage> dispatch;
  final ValueChanged<ShellSearchChoice> onChosen;
  final FocusNode? searchFocus;

  @override
  State<ShellBrowsePage> createState() => _ShellBrowsePageState();
}

class _ShellBrowsePageState extends State<ShellBrowsePage> {
  late final _query = TextEditingController(text: widget.model.criteria.query);
  @override
  void didUpdateWidget(ShellBrowsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final query = widget.model.criteria.query;
    if (_query.text != query) {
      _query.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _change({
    String? query,
    BrowseFilter? filter,
    String? Function()? category,
    String? Function()? language,
    String? Function()? source,
    CatalogAuthor? Function()? author,
  }) {
    final c = widget.model.criteria;
    widget.dispatch(
      BrowseChanged((
        query: query ?? c.query,
        filter: filter ?? c.filter,
        category: category == null ? c.category : category(),
        language: language == null ? c.language : language(),
        source: source == null ? c.source : source(),
        author: author == null ? c.author : author(),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final c = model.criteria;
    final gutter = widget.layout == ShellLayout.phone
        ? ShosaiTokens.space4
        : ShosaiTokens.space6;
    if (model.details != null || model.detailBusy || model.detailFailed) {
      return _CatalogBookPage(
        layout: widget.layout,
        model: model,
        dispatch: widget.dispatch,
      );
    }
    final catalog =
        c.filter == BrowseFilter.all || c.filter == BrowseFilter.freeBooks;
    final browse =
        c.query.trim().isEmpty && c.category == null && c.author == null;
    return ColoredBox(
      color: palette.canvas,
      child: SafeArea(
        bottom: false,
        child: ListView(
          key: const PageStorageKey('catalog-search-scroll'),
          padding: EdgeInsets.all(gutter),
          children: [
            ShadInput(
              key: const ValueKey('browse-search-field'),
              controller: _query,
              focusNode: widget.searchFocus,
              autofocus: widget.layout != ShellLayout.phone,
              leading: const Icon(LucideIcons.search, size: 20),
              placeholder: Text(
                l10n.catalogSearchPlaceholder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _query.text.isEmpty
                  ? null
                  : Tooltip(
                      message: l10n.catalogClearSearch,
                      child: ShadIconButton.ghost(
                        width: ShosaiTokens.sizeTouchTarget,
                        height: ShosaiTokens.sizeTouchTarget,
                        icon: const Icon(LucideIcons.x, size: 16),
                        onPressed: () => _change(query: ''),
                      ),
                    ),
              onChanged: (value) => _change(query: value, author: () => null),
            ),
            const SizedBox(height: ShosaiTokens.space3),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: ShosaiTokens.space2,
                children: [
                  for (final filter in BrowseFilter.values)
                    ChoiceChip(
                      label: Text(_filterLabel(l10n, filter)),
                      selected: c.filter == filter,
                      onSelected: (_) => _change(
                        filter: filter,
                        category: () => null,
                        language: () => null,
                        source: () => null,
                        author: () => null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: ShosaiTokens.space5),
            if (model.refreshing) _status(l10n.catalogUpdating),
            if (model.offline) _status(l10n.catalogOffline),
            if (catalog) ...[
              Wrap(
                spacing: ShosaiTokens.space2,
                runSpacing: ShosaiTokens.space2,
                children: [
                  if (model.filters.languages.isNotEmpty)
                    _filterMenu(
                      l10n.catalogLanguage,
                      c.language,
                      [
                        for (final value in model.filters.languages)
                          (value, value),
                      ],
                      (v) => _change(language: () => v),
                    ),
                  if (model.categories.isNotEmpty)
                    _filterMenu(
                      l10n.catalogCategory,
                      c.category,
                      [
                        for (final value in model.categories)
                          (value.id, value.label),
                      ],
                      (v) => _change(category: () => v),
                    ),
                  if (model.filters.sources.isNotEmpty)
                    _filterMenu(l10n.catalogSource, c.source, [
                      for (final value in model.filters.sources)
                        (value.id, value.name),
                    ], (v) => _change(source: () => v)),
                ],
              ),
              const SizedBox(height: ShosaiTokens.space5),
            ],
            if (c.query.trim().isNotEmpty &&
                (c.filter == BrowseFilter.all ||
                    c.filter == BrowseFilter.yourBooks ||
                    c.filter == BrowseFilter.notes)) ...[
              _heading(
                c.filter == BrowseFilter.notes
                    ? l10n.catalogYourNotes
                    : l10n.catalogYourBooks,
              ),
              if (widget.layout == ShellLayout.desktop &&
                  c.filter == BrowseFilter.all &&
                  widget.local.notes.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: ShellSearchResults(
                        model: widget.local.copyWith(
                          notes: const [],
                          notesBusy: false,
                        ),
                        onChosen: widget.onChosen,
                        embedded: true,
                      ),
                    ),
                    const SizedBox(width: ShosaiTokens.space5),
                    Expanded(
                      flex: 2,
                      child: ShellSearchResults(
                        model: widget.local.copyWith(
                          books: const [],
                          text: const [],
                          textBusy: false,
                          titlesBusy: false,
                        ),
                        onChosen: widget.onChosen,
                        embedded: true,
                      ),
                    ),
                  ],
                )
              else
                ShellSearchResults(
                  model: widget.local,
                  onChosen: widget.onChosen,
                  embedded: true,
                ),
              if (widget.local.titlesMore)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ShadButton.outline(
                    height: math.max(
                      ShosaiTokens.sizeTouchTarget,
                      shosaiShadButtonHeight(context),
                    ),
                    onPressed: widget.local.titlesBusy
                        ? null
                        : () =>
                              widget.dispatch(const BrowseLocalMoreRequested()),
                    child: Text(l10n.catalogShowMore),
                  ),
                ),
              const SizedBox(height: ShosaiTokens.space6),
            ],
            if (catalog && browse && model.categories.isNotEmpty) ...[
              _heading(l10n.catalogBrowse),
              Wrap(
                spacing: ShosaiTokens.space3,
                runSpacing: ShosaiTokens.space3,
                children: [
                  for (final category in model.categories)
                    SizedBox(
                      width: widget.layout == ShellLayout.phone ? 160 : 200,
                      child: ShadButton.outline(
                        height: 72,
                        onPressed: () => _change(
                          filter: BrowseFilter.freeBooks,
                          category: () => category.id,
                        ),
                        leading: const Icon(LucideIcons.book, size: 20),
                        child: Text(
                          category.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: ShosaiTokens.space6),
            ],
            if (c.filter == BrowseFilter.authors ||
                (c.filter == BrowseFilter.all && model.authors.isNotEmpty)) ...[
              _heading(l10n.catalogAuthors),
              for (final author in model.authors)
                ListTile(
                  title: Text(author.name, style: shellEditorialStyle(18, 26)),
                  subtitle: Text(l10n.catalogBookCount(author.books)),
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => _change(
                    query: '',
                    filter: BrowseFilter.freeBooks,
                    author: () => author,
                  ),
                ),
            ],
            if (catalog) ...[
              _heading(
                c.author?.name ??
                    _categoryLabel(c.category) ??
                    l10n.catalogFreeBooks,
              ),
              if (c.filter == BrowseFilter.all &&
                  widget.layout != ShellLayout.phone &&
                  model.books.isNotEmpty)
                SizedBox(
                  height: 302 * MediaQuery.textScalerOf(context).scale(1),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: model.books.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: ShosaiTokens.space5),
                    itemBuilder: (_, index) {
                      final book = model.books[index];
                      return SizedBox(
                        width: 136,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(
                            ShosaiTokens.radiusSm,
                          ),
                          onTap: () =>
                              widget.dispatch(BrowseBookRequested(book.id)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 204,
                                child: _CatalogCover(book: book),
                              ),
                              const SizedBox(height: ShosaiTokens.space2),
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: shellEditorialStyle(14, 19),
                              ),
                              Text(
                                book.authors.join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: shellInterfaceStyle(
                                  12,
                                  16,
                                ).copyWith(color: palette.inkMuted),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                for (final book in model.books)
                  Padding(
                    padding: const EdgeInsets.only(bottom: ShosaiTokens.space2),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(ShosaiTokens.space2),
                      leading: SizedBox(
                        width: 40,
                        height: 60,
                        child: _CatalogCover(book: book),
                      ),
                      title: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: shellEditorialStyle(17, 24),
                      ),
                      subtitle: Text(
                        [...book.authors, ...book.sources].join(' · '),
                        style: shellInterfaceStyle(
                          12,
                          18,
                        ).copyWith(color: palette.inkMuted),
                      ),
                      trailing: const Icon(LucideIcons.chevronRight, size: 18),
                      onTap: () =>
                          widget.dispatch(BrowseBookRequested(book.id)),
                    ),
                  ),
            ],
            if (model.busy)
              _status(l10n.shellSearchSearching)
            else if (model.failed)
              _status(l10n.catalogReadFailed)
            else if ((catalog && model.books.isEmpty) ||
                (c.filter == BrowseFilter.authors && model.authors.isEmpty))
              _status(
                !model.installed
                    ? l10n.catalogFirstDownload
                    : l10n.shellSearchNoMatches(c.query),
              ),
            if (model.more)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShadButton.outline(
                  height: math.max(
                    ShosaiTokens.sizeTouchTarget,
                    shosaiShadButtonHeight(context),
                  ),
                  onPressed: model.busy
                      ? null
                      : () => widget.dispatch(const BrowseMoreRequested()),
                  child: Text(l10n.catalogShowMore),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _categoryLabel(String? id) {
    for (final category in widget.model.categories) {
      if (category.id == id) return category.label;
    }
    return null;
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: ShosaiTokens.space4),
    child: Semantics(
      header: true,
      child: Text(text, style: shellEditorialStyle(22, 28)),
    ),
  );
  Widget _status(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: ShosaiTokens.space3),
    child: Text(
      text,
      style: shellInterfaceStyle(
        13,
        20,
      ).copyWith(color: ShellPalette.of(context).inkMuted),
    ),
  );
  Widget _filterMenu(
    String label,
    String? selected,
    List<(String, String)> values,
    ValueChanged<String?> onChanged,
  ) => PopupMenuButton<String>(
    tooltip: label,
    onSelected: (value) => onChanged(value.isEmpty ? null : value),
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: '',
        checked: selected == null,
        child: Text(AppLocalizations.of(context).catalogAll),
      ),
      for (final (id, name) in values)
        CheckedPopupMenuItem(
          value: id,
          checked: selected == id,
          child: Text(name),
        ),
    ],
    child: Chip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: ShosaiTokens.space2,
        children: [
          Flexible(
            child: Text(
              selected == null
                  ? label
                  : values
                        .firstWhere(
                          (v) => v.$1 == selected,
                          orElse: () => (selected, selected),
                        )
                        .$2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(LucideIcons.chevronDown, size: 14),
        ],
      ),
    ),
  );
}

String _filterLabel(AppLocalizations l10n, BrowseFilter filter) =>
    switch (filter) {
      BrowseFilter.all => l10n.catalogAll,
      BrowseFilter.yourBooks => l10n.catalogYourBooks,
      BrowseFilter.notes => l10n.shellPlaceNotes,
      BrowseFilter.freeBooks => l10n.catalogFreeBooks,
      BrowseFilter.authors => l10n.catalogAuthors,
    };

class _CatalogCover extends StatelessWidget {
  const _CatalogCover({required this.book});
  final CatalogBook book;
  @override
  Widget build(BuildContext context) {
    final fallback = LayoutBuilder(
      builder: (_, constraints) => ShellGeneratedCover(
        title: book.title,
        author: book.authors.firstOrNull,
        type: constraints.maxWidth < 60
            ? ShellCoverType.heroCompact
            : ShellCoverType.shelf,
      ),
    );
    final url = Uri.tryParse(book.coverUrl ?? '');
    return ExcludeSemantics(
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: url?.scheme == 'https'
              ? Image.network(
                  url.toString(),
                  headers: const {'User-Agent': catalogUserAgent},
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                  loadingBuilder: (_, child, loading) =>
                      loading == null ? child : fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

class _CatalogBookPage extends StatelessWidget {
  const _CatalogBookPage({
    required this.layout,
    required this.model,
    required this.dispatch,
  });
  final ShellLayout layout;
  final BrowseModel model;
  final ValueChanged<BrowseMessage> dispatch;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final details = model.details;
    final phone = layout == ShellLayout.phone;
    final metadata = details == null
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(details.book.title, style: shellScreenTitleStyle(layout)),
              const SizedBox(height: ShosaiTokens.space2),
              Text(
                details.book.authors.join(', '),
                style: shellEditorialStyle(
                  20,
                  28,
                ).copyWith(color: palette.inkMuted),
              ),
              const SizedBox(height: ShosaiTokens.space4),
              Wrap(
                spacing: ShosaiTokens.space2,
                runSpacing: ShosaiTokens.space2,
                children: [
                  for (final subject in details.subjects)
                    Chip(label: Text(subject)),
                ],
              ),
              const SizedBox(height: ShosaiTokens.space5),
              Text(
                l10n.catalogChooseEdition,
                style: shellEditorialStyle(22, 28),
              ),
              const SizedBox(height: ShosaiTokens.space3),
              RadioGroup<int>(
                groupValue: model.edition,
                onChanged: (value) {
                  if (value != null) dispatch(BrowseEditionSelected(value));
                },
                child: Column(
                  children: [
                    for (final (index, edition) in details.editions.indexed)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: ShosaiTokens.space3,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: index == model.edition
                                ? palette.surface
                                : null,
                            border: Border.all(
                              color: index == model.edition
                                  ? palette.accent
                                  : palette.lineStrong,
                            ),
                            borderRadius: BorderRadius.circular(
                              ShosaiTokens.radiusMd,
                            ),
                          ),
                          child: RadioListTile<int>(
                            value: index,
                            enabled: !model.acquisition.busy,
                            title: Text(
                              '${edition.sourceName} · ${edition.variant}',
                              style: shellInterfaceStyle(14, 20),
                            ),
                            subtitle: Text(
                              [
                                edition.format.toUpperCase(),
                                edition.language,
                                if (edition.sizeBytes != null)
                                  l10n.catalogBytes(edition.sizeBytes!),
                              ].join(' · '),
                            ),
                            contentPadding: const EdgeInsets.all(
                              ShosaiTokens.space2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (details.editions.isNotEmpty) ...[
                const SizedBox(height: ShosaiTokens.space3),
                Text(
                  details.editions[model.edition].rights,
                  style: shellInterfaceStyle(13, 20),
                ),
                if (details.editions[model.edition].catalogCredit
                    case final credit?)
                  Padding(
                    padding: const EdgeInsets.only(top: ShosaiTokens.space2),
                    child: Text(
                      credit,
                      style: shellInterfaceStyle(
                        12,
                        18,
                      ).copyWith(color: palette.inkMuted),
                    ),
                  ),
                const SizedBox(height: ShosaiTokens.space3),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ShadButton.outline(
                    height: math.max(
                      ShosaiTokens.sizeTouchTarget,
                      shosaiShadButtonHeight(context),
                    ),
                    onPressed: () => dispatch(
                      BrowseLinkRequested(
                        details.editions[model.edition].sourceUrl,
                      ),
                    ),
                    child: Text(l10n.catalogViewSource),
                  ),
                ),
                if (details.editions[model.edition].supportUrl case final url?)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ShadButton.ghost(
                      height: math.max(
                        ShosaiTokens.sizeTouchTarget,
                        shosaiShadButtonHeight(context),
                      ),
                      onPressed: () => dispatch(BrowseLinkRequested(url)),
                      child: Text(l10n.catalogSupportSource),
                    ),
                  ),
                if (model.linkFailed) Text(l10n.catalogLinkFailed),
              ],
              const SizedBox(height: ShosaiTokens.space5),
              if (details.editions.isNotEmpty)
                _CatalogAcquisitionControls(model: model, dispatch: dispatch),
            ],
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) dispatch(const BrowseBackRequested());
      },
      child: ColoredBox(
        color: palette.canvas,
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: EdgeInsets.all(
              phone ? ShosaiTokens.space4 : ShosaiTokens.space6,
            ),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShadButton.ghost(
                  height: math.max(
                    ShosaiTokens.sizeTouchTarget,
                    shosaiShadButtonHeight(context),
                  ),
                  leading: const Icon(LucideIcons.chevronLeft, size: 18),
                  onPressed: () => dispatch(const BrowseBackRequested()),
                  child: Text(l10n.catalogBackToSearch),
                ),
              ),
              const SizedBox(height: ShosaiTokens.space5),
              if (model.detailBusy) Text(l10n.shellSearchSearching),
              if (model.detailFailed) Text(l10n.catalogReadFailed),
              if (details != null)
                if (phone) ...[
                  Center(
                    child: SizedBox(
                      width: 152,
                      child: _CatalogCover(book: details.book),
                    ),
                  ),
                  const SizedBox(height: ShosaiTokens.space5),
                  metadata,
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 200,
                        child: _CatalogCover(book: details.book),
                      ),
                      const SizedBox(width: ShosaiTokens.space6),
                      Expanded(child: metadata),
                    ],
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogAcquisitionControls extends StatelessWidget {
  const _CatalogAcquisitionControls({
    required this.model,
    required this.dispatch,
  });
  final BrowseModel model;
  final ValueChanged<BrowseMessage> dispatch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = model.acquisition;
    final options = model.saveOptions;
    final selected = options?.locations
        .where((g) => g.id == options.selected)
        .firstOrNull;
    final height = math.max(
      ShosaiTokens.sizeTouchTarget,
      shosaiShadButtonHeight(context),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.result case final result?) ...[
          Semantics(
            liveRegion: true,
            child: Text(
              result.existing ? l10n.catalogAlreadyAdded : l10n.catalogAdded,
              style: shellInterfaceStyle(14, 20),
            ),
          ),
          const SizedBox(height: ShosaiTokens.space3),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ShadButton(
              height: height,
              onPressed: () => dispatch(const BrowseReadRequested()),
              child: Text(l10n.catalogRead),
            ),
          ),
        ] else ...[
          Text(l10n.catalogSaveTo, style: shellInterfaceStyle(13, 20)),
          const SizedBox(height: ShosaiTokens.space2),
          if (options == null) ...[
            Text(
              model.optionsBusy
                  ? l10n.catalogLocationsLoading
                  : l10n.catalogLocationsFailed,
            ),
            if (!model.optionsBusy)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShadButton.outline(
                  height: height,
                  onPressed: () => dispatch(const BrowseSaveOptionsRequested()),
                  child: Text(l10n.readerRetry),
                ),
              ),
          ] else ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: PopupMenuButton<String>(
                tooltip: l10n.catalogSaveTo,
                enabled: !state.busy && !model.locationBusy,
                initialValue: options.selected ?? 'private',
                onSelected: (value) => dispatch(
                  BrowseSaveLocationSelected(value == 'private' ? null : value),
                ),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'private',
                    child: Text(l10n.catalogPrivateLibrary),
                  ),
                  for (final g in options.locations)
                    PopupMenuItem(value: g.id, child: Text(g.label)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: ShosaiTokens.space3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          selected?.label ?? l10n.catalogPrivateLibrary,
                          style: shellInterfaceStyle(14, 20),
                        ),
                      ),
                      const SizedBox(width: ShosaiTokens.space2),
                      const Icon(LucideIcons.chevronDown, size: 18),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: ShosaiTokens.space3),
            if (state.busy) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  state.cancelling
                      ? l10n.catalogCancelling
                      : l10n.catalogAdding,
                ),
              ),
              const SizedBox(height: ShosaiTokens.space3),
              LinearProgressIndicator(
                value:
                    state.total != null &&
                        state.total! > 0 &&
                        state.received < state.total!
                    ? state.received / state.total!
                    : null,
              ),
              const SizedBox(height: ShosaiTokens.space3),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShadButton.outline(
                  height: height,
                  onPressed: state.cancelling
                      ? null
                      : () => dispatch(const BrowseAddCancelled()),
                  child: Text(l10n.readerNoteCancel),
                ),
              ),
            ] else ...[
              if (state.failed || state.cancelled) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    state.cancelled
                        ? l10n.catalogCancelled
                        : l10n.catalogAddFailed,
                  ),
                ),
                const SizedBox(height: ShosaiTokens.space3),
              ],
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShadButton(
                  height: height,
                  onPressed: model.locationBusy
                      ? null
                      : () => dispatch(const BrowseAddRequested()),
                  child: Text(l10n.catalogAdd),
                ),
              ),
            ],
          ],
        ],
      ],
    );
  }
}
