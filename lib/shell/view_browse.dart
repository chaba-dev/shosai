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
        : widget.layout == ShellLayout.tablet
        ? ShosaiTokens.space5
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
    final discovery = browse && c.filter == BrowseFilter.all;
    void chooseLocal(ShellSearchChoice choice) {
      widget.dispatch(const BrowseSearchSubmitted());
      widget.onChosen(choice);
    }

    return ColoredBox(
      color: palette.canvas,
      child: SafeArea(
        bottom: false,
        child: ListView(
          key: const PageStorageKey('catalog-search-scroll'),
          padding: EdgeInsets.all(gutter),
          children: [
            if (widget.layout == ShellLayout.phone) ...[
              Semantics(
                header: true,
                child: Text(
                  l10n.shellPlaceSearch,
                  style: shellEditorialStyle(30, 34),
                ),
              ),
              const SizedBox(height: ShosaiTokens.space4),
            ],
            ShadInput(
              key: const ValueKey('browse-search-field'),
              controller: _query,
              focusNode: widget.searchFocus,
              autofocus: widget.layout != ShellLayout.phone,
              padding: const EdgeInsets.all(ShosaiTokens.space3),
              style: shellInterfaceStyle(16, 24),
              decoration: ShadDecoration(color: palette.surface),
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
              onSubmitted: (_) =>
                  widget.dispatch(const BrowseSearchSubmitted()),
            ),
            if (!discovery) ...[
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
            ],
            const SizedBox(height: ShosaiTokens.space5),
            if (discovery && model.recentSearches.isNotEmpty) ...[
              Text(
                l10n.catalogRecentSearches,
                style: shellInterfaceStyle(
                  12,
                  16,
                  weight: FontWeight.w600,
                ).copyWith(color: palette.inkMuted),
              ),
              const SizedBox(height: ShosaiTokens.space2),
              Wrap(
                spacing: ShosaiTokens.space2,
                runSpacing: ShosaiTokens.space2,
                children: [
                  for (final query in model.recentSearches)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: ShosaiTokens.sizeTouchTarget,
                        maxWidth: math.min(
                          300,
                          MediaQuery.sizeOf(context).width - 2 * gutter,
                        ),
                      ),
                      child: ActionChip(
                        avatar: const Icon(LucideIcons.search, size: 16),
                        label: Text(
                          query,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        backgroundColor: palette.surface,
                        shape: StadiumBorder(
                          side: BorderSide(color: palette.lineStrong),
                        ),
                        onPressed: () => _change(query: query),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: ShosaiTokens.space5),
            ],
            if (model.refreshing) _status(l10n.catalogUpdating),
            if (model.offline) _status(l10n.catalogOffline),
            if (c.filter == BrowseFilter.freeBooks) ...[
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
                        onChosen: chooseLocal,
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
                        onChosen: chooseLocal,
                        embedded: true,
                      ),
                    ),
                  ],
                )
              else
                ShellSearchResults(
                  model: widget.local,
                  onChosen: chooseLocal,
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
            if (discovery && model.categories.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: ShosaiTokens.space4),
                child: Row(
                  children: [
                    Flexible(
                      flex: 5,
                      child: Semantics(
                        header: true,
                        child: Text(
                          l10n.catalogBrowse,
                          style: shellEditorialStyle(22, 28),
                        ),
                      ),
                    ),
                    const SizedBox(width: ShosaiTokens.space3),
                    Expanded(child: Divider(color: palette.line)),
                  ],
                ),
              ),
              if (model.filters.sources.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: ShosaiTokens.space4),
                  child: Text(
                    l10n.catalogFromSources(
                      model.filters.sources.map((s) => s.name).join(', '),
                    ),
                    style: shellInterfaceStyle(
                      12,
                      16,
                    ).copyWith(color: palette.inkMuted),
                  ),
                ),
              LayoutBuilder(
                builder: (_, constraints) {
                  final phone = widget.layout == ShellLayout.phone;
                  final gap = phone ? ShosaiTokens.space3 : ShosaiTokens.space4;
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final columns = math.max(
                    1,
                    ((constraints.maxWidth + gap) /
                            ((phone ? 152 : 220) * scale + gap))
                        .floor(),
                  );
                  final width =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final category in model.categories)
                        SizedBox(
                          key: ValueKey('catalog-category-${category.id}'),
                          width: width,
                          child: _CatalogCategoryCard(
                            category: category,
                            books: model.categoryBooks[category.id] ?? const [],
                            phone: phone,
                            onPressed: () => _change(
                              filter: BrowseFilter.freeBooks,
                              category: () => category.id,
                            ),
                          ),
                        ),
                    ],
                  );
                },
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
            if (catalog && !discovery) ...[
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
            else if ((catalog &&
                    model.books.isEmpty &&
                    (!discovery || !model.installed)) ||
                (c.filter == BrowseFilter.authors && model.authors.isEmpty))
              _status(
                !model.installed
                    ? l10n.catalogFirstDownload
                    : l10n.shellSearchNoMatches(c.query),
              ),
            if (model.more && !discovery)
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

/// Category artwork uses the existing generated-cover grounds, not new chrome
/// colours. Its covers are actual members of the installed category.
class _CatalogCategoryCard extends StatelessWidget {
  const _CatalogCategoryCard({
    required this.category,
    required this.books,
    required this.phone,
    required this.onPressed,
  });
  final CatalogCategory category;
  final List<CatalogBook> books;
  final bool phone;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final count = AppLocalizations.of(context).catalogBookCount(category.books);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return _ShellPressable(
      onPressed: onPressed,
      semanticLabel: '${category.label}, $count',
      radius: ShosaiTokens.radiusMd,
      color: palette.coverGround(category.id),
      shadow: palette.raised,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
        child: SizedBox(
          height: 136 * scale,
          child: LayoutBuilder(
            builder: (_, constraints) {
              final width = constraints.maxWidth;
              return Stack(
                children: [
                  for (var i = 0; i < books.length; i++)
                    Positioned(
                      left: width * (i == 0 ? .68 : .80),
                      bottom: ShosaiTokens.space3,
                      width: width * (i == 0 ? .24 : .17),
                      child: Transform.rotate(
                        angle: i == 0 ? -.20 : .18,
                        child: DecoratedBox(
                          decoration: BoxDecoration(boxShadow: palette.raised),
                          child: _CatalogCover(book: books[i]),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(ShosaiTokens.space3),
                    child: SizedBox(
                      width: books.isEmpty || phone
                          ? null
                          : width * .68 - ShosaiTokens.space3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              category.label,
                              maxLines: phone ? 2 : 3,
                              overflow: TextOverflow.ellipsis,
                              style: shellEditorialStyle(
                                phone ? 18 : 20,
                                phone ? 26 : 28,
                              ).copyWith(color: ShellPalette.coverInk),
                            ),
                          ),
                          const SizedBox(height: ShosaiTokens.space1),
                          SizedBox(
                            width: books.isEmpty
                                ? null
                                : width * .64 - ShosaiTokens.space3,
                            child: Text(
                              count,
                              style: shellInterfaceStyle(
                                12,
                                16,
                              ).copyWith(color: ShellPalette.coverInk),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
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
      builder: (_, constraints) {
        final cover = ShellGeneratedCover(
          title: book.title,
          author: book.authors.firstOrNull,
          type: ShellCoverType.shelf,
        );
        return constraints.maxWidth < 60
            ? FittedBox(child: SizedBox(width: 120, height: 180, child: cover))
            : cover;
      },
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
    final theme = ShadTheme.of(context);
    // Shad paints the 2 px border inside this outward rectangle, leaving
    // the design system's 2 px gap between the control and the focus ring.
    final focusBorder = ShadBorder.all(
      color: palette.accent,
      width: 2,
      offset: 4,
      radius: BorderRadius.circular(ShosaiTokens.radiusSm + 4),
    );
    Widget editionLabel(CatalogEdition edition, {bool selected = false}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${edition.sourceName} · ${edition.variant}',
              style: shellInterfaceStyle(14, 20).copyWith(
                color: selected
                    ? theme.colorScheme.accentForeground
                    : palette.ink,
              ),
            ),
            Text(
              [
                edition.format.toUpperCase(),
                edition.language,
                if (edition.sizeBytes != null)
                  l10n.catalogBytes(edition.sizeBytes!),
              ].join(' · '),
              style: shellInterfaceStyle(13, 20).copyWith(
                color: selected
                    ? theme.colorScheme.accentForeground
                    : palette.inkMuted,
              ),
            ),
          ],
        );
    PopupMenuItem<int> editionOption(int index, CatalogEdition edition) =>
        PopupMenuItem<int>(
          value: index,
          padding: const EdgeInsets.all(ShosaiTokens.space1),
          child: Builder(
            builder: (context) => Focus(
              autofocus: index == model.edition,
              skipTraversal: true,
              includeSemantics: false,
              child: ShadDecorator(
                focused: Focus.of(context).hasFocus,
                decoration: ShadDecoration.none.copyWith(
                  disableSecondaryBorder: false,
                  secondaryFocusedBorder: focusBorder,
                ),
                child: Semantics(
                  selected: index == model.edition,
                  child: Container(
                    padding: const EdgeInsets.all(ShosaiTokens.space3),
                    decoration: BoxDecoration(
                      color: index == model.edition
                          ? theme.colorScheme.accent
                          : null,
                      borderRadius: BorderRadius.circular(
                        ShosaiTokens.radiusSm,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: editionLabel(
                            edition,
                            selected: index == model.edition,
                          ),
                        ),
                        if (index == model.edition) ...[
                          const SizedBox(width: ShosaiTokens.space2),
                          Icon(
                            LucideIcons.check,
                            size: 18,
                            color: theme.colorScheme.accentForeground,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
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
              if (details.editions.isNotEmpty) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Focus(
                        skipTraversal: true,
                        child: Builder(
                          builder: (context) => Semantics(
                            key: const ValueKey('catalog-edition-picker'),
                            button: true,
                            enabled: !model.acquisition.busy,
                            label: l10n.catalogChooseEdition,
                            child: Opacity(
                              opacity: model.acquisition.busy
                                  ? theme.disabledOpacity
                                  : 1,
                              child: ShadDecorator(
                                focused: Focus.of(context).hasFocus,
                                decoration: ShadDecoration(
                                  color: palette.surface,
                                  border: ShadBorder.all(
                                    color: palette.lineStrong,
                                    width: 1,
                                    radius: BorderRadius.circular(
                                      ShosaiTokens.radiusSm,
                                    ),
                                  ),
                                  secondaryFocusedBorder: focusBorder,
                                ),
                                child: Theme(
                                  data: Theme.of(context).copyWith(
                                    focusColor: palette.hover.withValues(
                                      alpha: 0,
                                    ),
                                    highlightColor: palette.hover.withValues(
                                      alpha: 0,
                                    ),
                                  ),
                                  child: PopupMenuButton<int>(
                                    enabled: !model.acquisition.busy,
                                    initialValue: model.edition,
                                    useRootNavigator: true,
                                    tooltip: l10n.catalogChooseEdition,
                                    position: PopupMenuPosition.under,
                                    offset: const Offset(
                                      0,
                                      ShosaiTokens.space1,
                                    ),
                                    constraints: BoxConstraints.tightFor(
                                      width: constraints.maxWidth,
                                    ),
                                    color: palette.surface,
                                    surfaceTintColor: palette.hover.withValues(
                                      alpha: 0,
                                    ),
                                    elevation: 0,
                                    shape: _CatalogEditionMenuShape(
                                      palette.modal,
                                    ),
                                    menuPadding: const EdgeInsets.all(
                                      ShosaiTokens.space1,
                                    ),
                                    onSelected: (value) =>
                                        dispatch(BrowseEditionSelected(value)),
                                    itemBuilder: (_) => [
                                      for (final (index, edition)
                                          in details.editions.indexed)
                                        editionOption(index, edition),
                                    ],
                                    child: Padding(
                                      padding: const EdgeInsets.all(
                                        ShosaiTokens.space3,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: editionLabel(
                                              details.editions[model.edition],
                                            ),
                                          ),
                                          const SizedBox(
                                            width: ShosaiTokens.space2,
                                          ),
                                          Icon(
                                            LucideIcons.chevronDown,
                                            size: 18,
                                            color: palette.inkMuted,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
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
        if (didPop) return;
        dispatch(const BrowseBackRequested());
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

// Paint outside the menu's scroll viewport so it cannot clip the design
// system's layered shadow. Material's single elevation shadow stays disabled.
class _CatalogEditionMenuShape extends RoundedRectangleBorder {
  const _CatalogEditionMenuShape(this.shadows)
    : super(
        borderRadius: const BorderRadius.all(
          Radius.circular(ShosaiTokens.radiusMd),
        ),
      );
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    canvas.save();
    canvas.clipPath(
      ui.Path.combine(
        ui.PathOperation.difference,
        ui.Path()..addRect(canvas.getLocalClipBounds()),
        getOuterPath(rect, textDirection: textDirection),
      ),
    );
    final painter = BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: shadows,
    ).createBoxPainter();
    painter.paint(
      canvas,
      rect.topLeft,
      ImageConfiguration(size: rect.size, textDirection: textDirection),
    );
    painter.dispose();
    canvas.restore();
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
                        : state.locationChanged
                        ? l10n.catalogLocationChanged
                        : l10n.catalogAddFailed,
                  ),
                ),
                const SizedBox(height: ShosaiTokens.space3),
              ],
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShadButton(
                  height: height,
                  enabled: !model.locationBusy && !state.locationChanged,
                  onPressed: () => dispatch(const BrowseAddRequested()),
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
