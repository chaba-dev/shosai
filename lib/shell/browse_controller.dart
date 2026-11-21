import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shosai_core/shosai_core.dart' show CancellationToken;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:shosai_flutter/shell/search_controller.dart';
import 'package:shosai_flutter/theme_tokens.dart';

enum BrowseFilter { all, yourBooks, notes, freeBooks, authors }

typedef BrowseCriteria = ({
  String query,
  BrowseFilter filter,
  String? category,
  String? language,
  String? source,
  CatalogAuthor? author,
});

/// Unified Search owns local queries; the application, not this screen, owns
/// catalog refreshes. Query/detail revisions prevent late results replacing a
/// newer selection. Every effect reports a typed completion to dispatch.
class BrowseController extends ChangeNotifier {
  BrowseController({
    required FlutterBridge bridge,
    required Future<void> Function(Uri) openLink,
  }) : catalog = bridge is CatalogHost ? (bridge as CatalogHost).catalog : null,
       local = ShellSearchController(
         bridge: bridge,
         includeLibraryTitles: true,
       ),
       _openLink = openLink {
    local.addListener(_localChanged);
  }

  final CatalogClient? catalog;
  final ShellSearchController local;
  final Future<void> Function(Uri) _openLink;
  BrowseModel _model = const BrowseModel();
  BrowseModel get model => _model;
  Timer? _timer;
  CancellationToken? _queryCancellation;
  CancellationToken? _detailCancellation;
  int _revision = 0;
  int _detailRevision = 0;
  bool _disposed = false;
  bool _refreshing = false;

  void _localChanged() {
    if (!_disposed) notifyListeners();
  }

  void _emit(BrowseModel next) {
    _model = next;
    notifyListeners();
  }

  void dispatch(BrowseMessage message) {
    if (_disposed) return;
    switch (message) {
      case BrowseOpened():
        _load();
        if (!_refreshing && catalog != null) {
          _refreshing = true;
          _emit(_model.copyWith(refreshing: true));
          unawaited(() async {
            try {
              final result = await catalog!.refresh();
              dispatch(
                _BrowseRefreshed(false, result == CatalogRefresh.installed),
              );
            } catch (_) {
              dispatch(const _BrowseRefreshed(true, false));
            }
          }());
        }
      case BrowseChanged(:final criteria):
        if (criteria == _model.criteria) return;
        final queryChanged = criteria.query != _model.criteria.query;
        _detailRevision++;
        _detailCancellation?.cancel();
        _emit(
          _model.copyWith(
            criteria: criteria,
            details: () => null,
            detailBusy: false,
            detailFailed: false,
          ),
        );
        _searchLocal();
        _load(debounce: queryChanged);
      case _BrowseDue(:final revision):
        if (revision == _revision) _query(revision);
      case BrowseMoreRequested():
        if (!_model.busy && _model.more) _load(more: true);
      case BrowseLocalMoreRequested():
        local.dispatch(const ShellSearchMoreTitlesRequested());
      case _BrowseLoaded(
        :final revision,
        :final books,
        :final authors,
        :final categories,
        :final filters,
        :final more,
        :final installed,
      ):
        if (revision != _revision) return;
        _emit(
          _model.copyWith(
            books: books,
            authors: authors,
            categories: categories,
            filters: filters,
            busy: false,
            more: more,
            installed: installed,
            failed: false,
          ),
        );
      case _BrowseFailed(:final revision):
        if (revision == _revision) {
          _emit(_model.copyWith(busy: false, failed: true));
        }
      case _BrowseRefreshed(:final failed, :final installed):
        _refreshing = false;
        _emit(_model.copyWith(refreshing: false, offline: failed));
        // Failed and unchanged refreshes leave the current results in place.
        if (installed) _load();
      case BrowseBookRequested(:final id):
        _detailCancellation?.cancel();
        final revision = ++_detailRevision;
        final cancellation = _detailCancellation = CancellationToken();
        _emit(
          _model.copyWith(
            details: () => null,
            detailBusy: true,
            detailFailed: false,
          ),
        );
        unawaited(() async {
          try {
            final details = await catalog?.book(id, cancellation: cancellation);
            dispatch(_BrowseBookLoaded(revision, details));
          } catch (_) {
            dispatch(_BrowseBookLoaded(revision, null));
          }
        }());
      case _BrowseBookLoaded(:final revision, :final details):
        if (revision != _detailRevision) return;
        _emit(
          _model.copyWith(
            details: () => details,
            detailBusy: false,
            detailFailed: details == null,
            edition: 0,
          ),
        );
      case BrowseBackRequested():
        _detailRevision++;
        _detailCancellation?.cancel();
        _emit(
          _model.copyWith(
            details: () => null,
            detailBusy: false,
            detailFailed: false,
          ),
        );
      case BrowseEditionSelected(:final index):
        if (index >= 0 && index < (_model.details?.editions.length ?? 0)) {
          _emit(_model.copyWith(edition: index));
        }
      case BrowseLinkRequested(:final url):
        final uri = Uri.tryParse(url);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return;
        final revision = _detailRevision;
        unawaited(() async {
          try {
            await _openLink(uri);
          } catch (_) {
            dispatch(_BrowseLinkFailed(revision));
          }
        }());
      case _BrowseLinkFailed(:final revision):
        if (revision == _detailRevision) {
          _emit(_model.copyWith(linkFailed: true));
        }
    }
  }

  void _searchLocal() {
    final c = _model.criteria;
    local.dispatch(
      ShellSearchFilterChanged(
        c.filter == BrowseFilter.notes
            ? ShellSearchFilter.notes
            : c.filter == BrowseFilter.yourBooks
            ? ShellSearchFilter.text
            : ShellSearchFilter.everything,
      ),
    );
    local.dispatch(
      ShellSearchQueryChanged(
        c.filter == BrowseFilter.freeBooks || c.filter == BrowseFilter.authors
            ? ''
            : c.query,
      ),
    );
  }

  void _load({bool debounce = false, bool more = false}) {
    _timer?.cancel();
    _queryCancellation?.cancel();
    final revision = ++_revision;
    _emit(
      _model.copyWith(
        busy: true,
        failed: false,
        books: more ? null : const [],
        authors: more ? null : const [],
        more: more,
      ),
    );
    if (debounce) {
      _timer = Timer(
        const Duration(
          milliseconds: ShosaiTokens.layoutLibrarySearchDebounceMs,
        ),
        () => dispatch(_BrowseDue(revision)),
      );
    } else {
      _query(revision);
    }
  }

  void _query(int revision) {
    final c = _model.criteria;
    final previousBooks = _model.books;
    final previousAuthors = _model.authors;
    final cancellation = _queryCancellation = CancellationToken();
    unawaited(() async {
      try {
        final installed = await catalog?.isInstalled ?? false;
        final categories =
            await catalog?.categories(cancellation: cancellation) ??
            const <CatalogCategory>[];
        final filters =
            await catalog?.filters(cancellation: cancellation) ??
            (
              languages: const <String>[],
              sources: const <({String id, String name})>[],
            );
        var books = const <CatalogBook>[];
        var authors = const <CatalogAuthor>[];
        if (c.filter == BrowseFilter.authors) {
          authors =
              await catalog?.authors(
                query: c.query,
                limit: 31,
                offset: previousAuthors.length,
                cancellation: cancellation,
              ) ??
              const [];
        } else if (c.filter == BrowseFilter.all ||
            c.filter == BrowseFilter.freeBooks) {
          if (c.filter == BrowseFilter.all &&
              c.query.trim().isNotEmpty &&
              previousBooks.isEmpty) {
            authors =
                await catalog?.authors(
                  query: c.query,
                  limit: 3,
                  cancellation: cancellation,
                ) ??
                const [];
          }
          books =
              await catalog?.search(
                query: c.query,
                category: c.category,
                language: c.language,
                source: c.source,
                author: c.author?.id,
                limit: 31,
                offset: previousBooks.length,
                cancellation: cancellation,
              ) ??
              const [];
        }
        dispatch(
          _BrowseLoaded(
            revision,
            [...previousBooks, ...books.take(30)],
            [...previousAuthors, ...authors.take(30)],
            categories,
            filters,
            books.length > 30 || authors.length > 30,
            installed,
          ),
        );
      } catch (_) {
        dispatch(_BrowseFailed(revision));
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _detailRevision++;
    _timer?.cancel();
    _queryCancellation?.cancel();
    _detailCancellation?.cancel();
    local.removeListener(_localChanged);
    local.dispose();
    super.dispose();
  }
}

final class BrowseModel {
  const BrowseModel({
    this.criteria = (
      query: '',
      filter: BrowseFilter.all,
      category: null,
      language: null,
      source: null,
      author: null,
    ),
    this.books = const [],
    this.authors = const [],
    this.categories = const [],
    this.filters = (languages: const [], sources: const []),
    this.busy = false,
    this.more = false,
    this.refreshing = false,
    this.offline = false,
    this.installed = false,
    this.failed = false,
    this.details,
    this.detailBusy = false,
    this.detailFailed = false,
    this.edition = 0,
    this.linkFailed = false,
  });
  final BrowseCriteria criteria;
  final List<CatalogBook> books;
  final List<CatalogAuthor> authors;
  final List<CatalogCategory> categories;
  final CatalogFilters filters;
  final bool busy,
      more,
      refreshing,
      offline,
      installed,
      failed,
      detailBusy,
      detailFailed,
      linkFailed;
  final CatalogBookDetails? details;
  final int edition;
  BrowseModel copyWith({
    BrowseCriteria? criteria,
    List<CatalogBook>? books,
    List<CatalogAuthor>? authors,
    List<CatalogCategory>? categories,
    CatalogFilters? filters,
    bool? busy,
    bool? more,
    bool? refreshing,
    bool? offline,
    bool? installed,
    bool? failed,
    CatalogBookDetails? Function()? details,
    bool? detailBusy,
    bool? detailFailed,
    int? edition,
    bool? linkFailed,
  }) => BrowseModel(
    criteria: criteria ?? this.criteria,
    books: books == null ? this.books : List.unmodifiable(books),
    authors: authors == null ? this.authors : List.unmodifiable(authors),
    categories: categories == null
        ? this.categories
        : List.unmodifiable(categories),
    filters: filters ?? this.filters,
    busy: busy ?? this.busy,
    more: more ?? this.more,
    refreshing: refreshing ?? this.refreshing,
    offline: offline ?? this.offline,
    installed: installed ?? this.installed,
    failed: failed ?? this.failed,
    details: details == null ? this.details : details(),
    detailBusy: detailBusy ?? this.detailBusy,
    detailFailed: detailFailed ?? this.detailFailed,
    edition: edition ?? this.edition,
    linkFailed: linkFailed ?? false,
  );
}

sealed class BrowseMessage {
  const BrowseMessage();
}

final class BrowseOpened extends BrowseMessage {
  const BrowseOpened();
}

final class BrowseChanged extends BrowseMessage {
  const BrowseChanged(this.criteria);
  final BrowseCriteria criteria;
}

final class BrowseMoreRequested extends BrowseMessage {
  const BrowseMoreRequested();
}

final class BrowseLocalMoreRequested extends BrowseMessage {
  const BrowseLocalMoreRequested();
}

final class BrowseBookRequested extends BrowseMessage {
  const BrowseBookRequested(this.id);
  final String id;
}

final class BrowseBackRequested extends BrowseMessage {
  const BrowseBackRequested();
}

final class BrowseEditionSelected extends BrowseMessage {
  const BrowseEditionSelected(this.index);
  final int index;
}

final class BrowseLinkRequested extends BrowseMessage {
  const BrowseLinkRequested(this.url);
  final String url;
}

final class _BrowseDue extends BrowseMessage {
  const _BrowseDue(this.revision);
  final int revision;
}

final class _BrowseFailed extends BrowseMessage {
  const _BrowseFailed(this.revision);
  final int revision;
}

final class _BrowseRefreshed extends BrowseMessage {
  const _BrowseRefreshed(this.failed, this.installed);
  final bool failed;
  final bool installed;
}

final class _BrowseLoaded extends BrowseMessage {
  const _BrowseLoaded(
    this.revision,
    this.books,
    this.authors,
    this.categories,
    this.filters,
    this.more,
    this.installed,
  );
  final int revision;
  final List<CatalogBook> books;
  final List<CatalogAuthor> authors;
  final List<CatalogCategory> categories;
  final CatalogFilters filters;
  final bool more;
  final bool installed;
}

final class _BrowseBookLoaded extends BrowseMessage {
  const _BrowseBookLoaded(this.revision, this.details);
  final int revision;
  final CatalogBookDetails? details;
}

final class _BrowseLinkFailed extends BrowseMessage {
  const _BrowseLinkFailed(this.revision);
  final int revision;
}
