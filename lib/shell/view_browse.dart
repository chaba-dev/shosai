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
                  final categories = [
                    for (final id in _catalogFeatured.keys)
                      for (final category in model.categories)
                        if (category.id == id) category,
                    for (final category in model.categories)
                      if (!_catalogFeatured.containsKey(category.id)) category,
                  ];
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final category in categories)
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
                    itemBuilder: (_, index) => _CatalogShelfCard(
                      book: model.books[index],
                      onPressed: () => widget.dispatch(
                        BrowseBookRequested(model.books[index].id),
                      ),
                    ),
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
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: ShosaiTokens.space3,
                ),
                child: _CatalogError(l10n.catalogReadFailed),
              )
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

/// Precomposed member-cover artwork is bundled for the published categories.
/// New categories retain member previews until their artwork is generated.
/// Only categories present in the installed catalog are featured.
const _catalogFeatured = {
  'gutenberg:Classics of Literature': 'Classics of\nLiterature',
  'gutenberg:Science-Fiction & Fantasy': 'Science\nFiction &\nFantasy',
  'gutenberg:Crime, Thrillers and Mystery': 'Crime &\nMystery',
  'gutenberg:Children & Young Adult Reading': 'Children &\nYoung Adult',
  'gutenberg:Philosophy & Ethics': 'Philosophy &\nEthics',
  'gutenberg:Poetry': 'Poetry',
  'gutenberg:Romance': 'Romance',
  'gutenberg:Adventure': 'Adventure',
};

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
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final featured = _catalogFeatured[category.id];
    final artwork = catalogCategoryArtwork[category.id];
    return _ShellPressable(
      onPressed: onPressed,
      semanticLabel: '${category.label}, $count',
      radius: ShosaiTokens.radiusMd,
      color: switch (category.id) {
        'gutenberg:Classics of Literature' ||
        'gutenberg:Adventure' => ShosaiTokens.colorBrandCharcoal,
        'gutenberg:Science-Fiction & Fantasy' => ShosaiTokens.colorLightSuccess,
        'gutenberg:Children & Young Adult Reading' =>
          ShosaiTokens.colorLightAccent,
        'gutenberg:Poetry' => ShosaiTokens.colorLightVermilion,
        'gutenberg:Crime, Thrillers and Mystery' ||
        'gutenberg:Romance' => Color.lerp(
          ShosaiTokens.colorLightVermilion,
          ShosaiTokens.colorBrandCharcoal,
          .4,
        ),
        'gutenberg:Philosophy & Ethics' => Color.lerp(
          ShosaiTokens.colorSwatchPurple,
          ShosaiTokens.colorBrandCharcoal,
          .5,
        ),
        _ => palette.coverGround(category.id),
      },
      shadow: palette.raised,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
        child: SizedBox(
          height: (phone ? 112 : 128) * scale,
          child: LayoutBuilder(
            builder: (_, constraints) {
              final width = constraints.maxWidth;
              // Keep the mock's composition at its normal size, but give
              // counts breathing room on narrower two-column phones.
              final artInset = featured == null
                  ? width * .2
                  : phone
                  ? math.max(0.0, 192 - width) / 2
                  : 0.0;
              final artWidth = width - artInset;
              final preview = Stack(
                children: [
                  for (var i = 0; i < books.length; i++)
                    Positioned(
                      left: artWidth * (i == 0 ? .68 : .80),
                      bottom: ShosaiTokens.space3,
                      width: artWidth * (i == 0 ? .24 : .17),
                      child: Transform.rotate(
                        angle: i == 0 ? -.20 : .18,
                        child: DecoratedBox(
                          decoration: BoxDecoration(boxShadow: palette.raised),
                          child: _CatalogCover(book: books[i]),
                        ),
                      ),
                    ),
                ],
              );
              return Stack(
                children: [
                  Positioned.fill(
                    left: artInset,
                    child: artwork == null
                        ? preview
                        : Image.asset(
                            artwork,
                            fit: BoxFit.fitWidth,
                            alignment: Alignment.bottomRight,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) => preview,
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(ShosaiTokens.space3),
                    child: SizedBox(
                      width: featured == null
                          ? width * .8 - ShosaiTokens.space3
                          : phone
                          ? null
                          : width * .72 - ShosaiTokens.space3,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            featured ?? category.label,
                            maxLines: featured == null ? 2 : 3,
                            overflow: featured == null
                                ? TextOverflow.fade
                                : TextOverflow.ellipsis,
                            style: shellEditorialStyle(
                              phone
                                  ? (width * 18 / 191).clamp(16, 18)
                                  : featured == null
                                  ? 18
                                  : 20,
                              featured == null ? 26 : (phone ? 22 : 24),
                            ).copyWith(color: ShellPalette.coverInk),
                          ),
                          const SizedBox(height: ShosaiTokens.space1),
                          SizedBox(
                            width:
                                (books.isEmpty && artwork == null) ||
                                    featured == null
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

/// A 136 px cover with its title and author, on result and author shelves.
class _CatalogShelfCard extends StatelessWidget {
  const _CatalogShelfCard({required this.book, required this.onPressed});
  final CatalogBook book;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 136,
    child: InkWell(
      borderRadius: BorderRadius.circular(ShosaiTokens.radiusSm),
      onTap: onPressed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 204, child: _CatalogCover(book: book)),
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
            ).copyWith(color: ShellPalette.of(context).inkMuted),
          ),
        ],
      ),
    ),
  );
}

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
    Widget remote(Uri uri, Widget onFailure) => Image.network(
      uri.toString(),
      headers: const {'User-Agent': catalogUserAgent},
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => onFailure,
      loadingBuilder: (_, child, loading) => loading == null ? child : fallback,
    );
    final mirror =
        url != null &&
            (url.host == 'www.gutenberg.org' || url.host == 'gutenberg.org') &&
            RegExp(
              r'^/cache/epub/[0-9]+/pg[0-9]+\.cover\.(small|medium)\.jpg$',
            ).hasMatch(url.path)
        ? Uri.https('gutenberg.pglaf.org', url.path)
        : null;
    return ExcludeSemantics(
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: url?.scheme == 'https'
              ? remote(
                  url!,
                  mirror == null ? fallback : remote(mirror, fallback),
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
    Widget editionLabel(
      CatalogEdition edition, {
      bool selected = false,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${edition.sourceName} · ${edition.variant}',
          style: shellInterfaceStyle(14, 20).copyWith(
            color: selected ? theme.colorScheme.accentForeground : palette.ink,
          ),
        ),
        Text(
          [
            edition.format.toUpperCase(),
            edition.language,
            // Decimal units, as the platforms' file managers show them.
            if (edition.sizeBytes case final size?)
              size < 100000
                  ? l10n.catalogKilobytes(math.max(1, (size / 1000).round()))
                  : l10n.catalogMegabytes(size / 1000000),
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
    void browseAuthor(CatalogBookAuthor author) => dispatch(
      BrowseChanged((
        query: '',
        filter: BrowseFilter.freeBooks,
        category: null,
        language: null,
        source: null,
        author: (id: author.id, name: author.name, books: author.books),
      )),
    );
    String year(int value) =>
        value < 0 ? l10n.catalogYearBce(-value) : '$value';
    final muted = shellInterfaceStyle(16, 24).copyWith(color: palette.inkMuted);
    final bookFacts = details == null
        ? const <String>[]
        : [
            if (details.editions.isNotEmpty)
              details.editions[model.edition].language
                  .split(';')
                  .map((code) => l10n.catalogLanguageName(code.trim()))
                  .join(', '),
            if (details.readingEase case final ease?)
              l10n.catalogReadingEase(ease),
          ];
    final header = details == null
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (details.book.sources.isNotEmpty) ...[
                _CatalogEyebrow(details.book.sources.join(' · ')),
                const SizedBox(height: ShosaiTokens.space2),
              ],
              Text(details.book.title, style: shellScreenTitleStyle(layout)),
              const SizedBox(height: ShosaiTokens.space1),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: ShosaiTokens.space2,
                children: [
                  for (final (index, author) in details.authors.indexed) ...[
                    ShellLink(
                      label: author.name,
                      onPressed: () => browseAuthor(author),
                      style: shellInterfaceStyle(
                        16,
                        24,
                        weight: FontWeight.w500,
                      ),
                    ),
                    if ([
                          if (author.birthYear != null ||
                              author.deathYear != null)
                            '${author.birthYear == null ? '' : year(author.birthYear!)}'
                                '–${author.deathYear == null ? '' : year(author.deathYear!)}',
                          if (index == details.authors.length - 1) ...bookFacts,
                        ]
                        case final facts when facts.isNotEmpty)
                      Text(facts.join(' · '), style: muted),
                  ],
                  // Book facts do not depend on an author being catalogued.
                  if (details.authors.isEmpty && bookFacts.isNotEmpty)
                    Text(bookFacts.join(' · '), style: muted),
                ],
              ),
            ],
          );
    final body = details == null
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (details.summary case final summary?) ...[
                const SizedBox(height: ShosaiTokens.space4),
                Text(
                  summary,
                  style: shellEditorialStyle(18, 28, weight: FontWeight.w400),
                ),
              ],
              if (details.subjects.isNotEmpty) ...[
                const SizedBox(height: ShosaiTokens.space4),
                Wrap(
                  spacing: ShosaiTokens.space2,
                  runSpacing: ShosaiTokens.space2,
                  children: [
                    for (final (label, heading) in _subjectTags(
                      details.subjects,
                    ))
                      Semantics(
                        label: heading,
                        excludeSemantics: true,
                        child: Chip(
                          label: Text(label),
                          labelStyle: shellInterfaceStyle(
                            14,
                            20,
                          ).copyWith(color: palette.ink),
                          backgroundColor: palette.surface,
                          shape: StadiumBorder(
                            side: BorderSide(color: palette.lineStrong),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: ShosaiTokens.space5),
              Text(
                l10n.catalogEdition,
                style: shellInterfaceStyle(14, 20, weight: FontWeight.w600),
              ),
              const SizedBox(height: ShosaiTokens.space2),
              if (details.editions.isNotEmpty) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SizedBox(
                    width: double.infinity,
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
                Wrap(
                  spacing: ShosaiTokens.space5,
                  children: [
                    ShellLink(
                      label: l10n.catalogViewSource,
                      onPressed: () => dispatch(
                        BrowseLinkRequested(
                          details.editions[model.edition].sourceUrl,
                        ),
                      ),
                    ),
                    if (details.editions[model.edition].supportUrl
                        case final url?)
                      ShellLink(
                        label: l10n.catalogSupportSource(
                          details.editions[model.edition].sourceName,
                        ),
                        onPressed: () => dispatch(BrowseLinkRequested(url)),
                      ),
                  ],
                ),
                if (model.linkFailed) _CatalogError(l10n.catalogLinkFailed),
              ],
              if (phone && details.editions.isNotEmpty) ...[
                const SizedBox(height: ShosaiTokens.space5),
                _CatalogAcquisitionControls(
                  model: model,
                  dispatch: dispatch,
                  phone: phone,
                ),
              ],
              _CatalogAboutBook(details),
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
              if (model.detailFailed) _CatalogError(l10n.catalogReadFailed),
              if (details != null)
                if (phone) ...[
                  Row(
                    children: [
                      SizedBox(
                        width: 112,
                        child: _CatalogCover(book: details.book),
                      ),
                      const SizedBox(width: ShosaiTokens.space4),
                      Expanded(child: header),
                    ],
                  ),
                  body,
                ] else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cover = SizedBox(
                        width: 200,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _CatalogCover(book: details.book),
                            if (details.editions.isNotEmpty) ...[
                              const SizedBox(height: ShosaiTokens.space5),
                              _CatalogAcquisitionControls(
                                model: model,
                                dispatch: dispatch,
                                phone: phone,
                              ),
                            ],
                          ],
                        ),
                      );
                      if (constraints.maxWidth < 560) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(child: cover),
                            const SizedBox(height: ShosaiTokens.space5),
                            header,
                            body,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          cover,
                          const SizedBox(width: ShosaiTokens.space6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [header, body],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              if (details != null && details.moreByAuthor.isNotEmpty) ...[
                const SizedBox(height: ShosaiTokens.space7),
                LayoutBuilder(
                  builder: (context, constraints) {
                    // The rule runs behind the heading, so a long or enlarged
                    // heading wraps across the full width instead of sharing it.
                    final heading = Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: [
                        Positioned.fill(
                          child: Center(
                            child: Divider(height: 1, color: palette.line),
                          ),
                        ),
                        ColoredBox(
                          color: palette.canvas,
                          child: Padding(
                            padding: const EdgeInsetsDirectional.only(
                              end: ShosaiTokens.space4,
                            ),
                            child: Semantics(
                              header: true,
                              child: Text(
                                l10n.catalogMoreByAuthor(
                                  details.authors.first.name,
                                ),
                                style: shellEditorialStyle(24, 30),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                    final all = ShellLink(
                      label: l10n.catalogAllByAuthor(
                        details.authors.first.books,
                      ),
                      trailing: LucideIcons.chevronRight,
                      onPressed: () => browseAuthor(details.authors.first),
                    );
                    if (constraints.maxWidth < 560) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [heading, all],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: ShosaiTokens.space2),
                        all,
                      ],
                    );
                  },
                ),
                const SizedBox(height: ShosaiTokens.space3),
                SizedBox(
                  height: 302 * MediaQuery.textScalerOf(context).scale(1),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: details.moreByAuthor.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: ShosaiTokens.space5),
                    itemBuilder: (_, index) => _CatalogShelfCard(
                      book: details.moreByAuthor[index],
                      onPressed: () => dispatch(
                        BrowseBookRequested(details.moreByAuthor[index].id),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Subject tags as the mock shows them: each Library of Congress heading by
/// its first term ("England -- Fiction" reads "England"), once per term, in
/// catalog order. The full heading stays the tag's accessible label.
List<(String, String)> _subjectTags(List<String> subjects) {
  final seen = <String>{};
  return [
    for (final heading in subjects)
      if (heading.split(' -- ').first.trim() case final label
          when label.isNotEmpty && seen.add(label))
        (label, heading),
  ];
}

/// The sources above a book title, in the sidebar's small-caps label style.
class _CatalogEyebrow extends StatelessWidget {
  const _CatalogEyebrow(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final japanese =
        shosaiInterfaceFontForText(label) == shosaiJapaneseInterfaceFontFamily;
    final style = shellInterfaceStyle(
      japanese ? 12 : 11,
      japanese ? 16 : 14,
      weight: FontWeight.w600,
    ).copyWith(color: ShellPalette.of(context).inkMuted);
    return Text(
      japanese ? label : label.toUpperCase(),
      style: shosaiInterfaceStyleForText(
        japanese ? style : style.copyWith(letterSpacing: .88),
        label,
      ),
    );
  }
}

/// The book's long description and its facts, below the acquisition actions.
/// Each part is omitted when the catalog lacks it, and the section with them.
class _CatalogAboutBook extends StatelessWidget {
  const _CatalogAboutBook(this.details);
  final CatalogBookDetails details;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    // SQLite's trim admits newlines and tabs, so blank values can arrive.
    final series = [
      for (final s in details.series)
        if (s.name.trim() case final name when name.isNotEmpty)
          s.position == null
              ? name
              : l10n.catalogSeriesPosition(name, s.position!),
    ];
    final facts = [
      if (series.isNotEmpty) (l10n.catalogSeries, series.join('\n')),
      if (details.wordCount case final words?)
        (l10n.catalogLength, l10n.catalogWordCount(words)),
      // The release date of a source's edition; never shown as a publication
      // year. It is a calendar date, read as UTC so no time zone shifts its
      // day.
      if (details.released case final released?)
        (
          l10n.catalogReleased,
          l10n.catalogReleasedOn(DateTime.parse('${released}T00:00:00Z')),
        ),
    ];
    final description = switch (details.description?.trim()) {
      final text? when text.isNotEmpty => text,
      _ => null,
    };
    if (description == null && facts.isEmpty) return const SizedBox.shrink();
    final value = shellInterfaceStyle(15, 24).copyWith(color: palette.ink);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: ShosaiTokens.space6),
        Divider(height: 1, color: palette.line),
        const SizedBox(height: ShosaiTokens.space5),
        Semantics(
          header: true,
          child: Text(
            l10n.catalogAboutBook,
            style: shellEditorialStyle(22, 26),
          ),
        ),
        if (description != null)
          for (final paragraph in description.split(RegExp(r'\n\s*\n')))
            if (paragraph.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: ShosaiTokens.space3),
                child: Text(
                  paragraph.trim(),
                  style: shellEditorialStyle(18, 28, weight: FontWeight.w400),
                ),
              ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: ShosaiTokens.space4),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            children: [
              for (final (label, text) in facts)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: ShosaiTokens.space5,
                        bottom: ShosaiTokens.space1,
                      ),
                      child: Text(
                        label,
                        style: value.copyWith(color: palette.inkMuted),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: ShosaiTokens.space1,
                      ),
                      child: Text(text, style: value),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
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

class _CatalogError extends StatelessWidget {
  const _CatalogError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: shellInterfaceStyle(
        14,
        20,
      ).copyWith(color: ShadTheme.of(context).colorScheme.destructive),
    ),
  );
}

class _CatalogAcquisitionControls extends StatelessWidget {
  const _CatalogAcquisitionControls({
    required this.model,
    required this.dispatch,
    required this.phone,
  });
  final BrowseModel model;
  final ValueChanged<BrowseMessage> dispatch;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = model.acquisition;
    final options = model.saveOptions;
    final selected = options?.locations
        .where((g) => g.id == options.selected)
        .firstOrNull;
    final buttonConstraints = BoxConstraints(
      minWidth: phone ? 0 : double.infinity,
      minHeight: math.max(
        ShosaiTokens.sizeTouchTarget,
        shosaiShadButtonHeight(context),
      ),
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
            child: ConstrainedBox(
              constraints: buttonConstraints,
              child: ShadButton(
                height: 0,
                onPressed: () => dispatch(const BrowseReadRequested()),
                child: Flexible(child: Text(l10n.catalogRead)),
              ),
            ),
          ),
        ] else ...[
          Text(l10n.catalogSaveTo, style: shellInterfaceStyle(13, 20)),
          const SizedBox(height: ShosaiTokens.space2),
          if (options == null) ...[
            if (model.optionsBusy)
              Text(l10n.catalogLocationsLoading)
            else
              _CatalogError(l10n.catalogLocationsFailed),
            if (!model.optionsBusy)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: buttonConstraints,
                  child: ShadButton.outline(
                    height: 0,
                    onPressed: () =>
                        dispatch(const BrowseSaveOptionsRequested()),
                    child: Flexible(child: Text(l10n.readerRetry)),
                  ),
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
                child: ConstrainedBox(
                  constraints: buttonConstraints,
                  child: ShadButton.outline(
                    height: 0,
                    onPressed: state.cancelling
                        ? null
                        : () => dispatch(const BrowseAddCancelled()),
                    child: Flexible(child: Text(l10n.readerNoteCancel)),
                  ),
                ),
              ),
            ] else ...[
              if (state.failed || state.cancelled) ...[
                if (state.cancelled)
                  Semantics(
                    liveRegion: true,
                    child: Text(l10n.catalogCancelled),
                  )
                else
                  _CatalogError(
                    state.locationChanged
                        ? l10n.catalogLocationChanged
                        : l10n.catalogAddFailed,
                  ),
                const SizedBox(height: ShosaiTokens.space3),
              ],
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: buttonConstraints,
                  child: ShadButton(
                    height: 0,
                    enabled: !model.locationBusy && !state.locationChanged,
                    onPressed: () => dispatch(const BrowseAddRequested()),
                    child: Flexible(child: Text(l10n.catalogAdd)),
                  ),
                ),
              ),
            ],
          ],
        ],
      ],
    );
  }
}
