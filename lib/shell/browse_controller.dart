import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shosai_core/shosai_core.dart' show CancellationToken;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:shosai_flutter/shell/catalog_artwork.dart';
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
    void Function(FlutterLibraryBook)? openBook,
    VoidCallback? libraryChanged,
  }) : catalog = bridge is CatalogHost ? (bridge as CatalogHost).catalog : null,
       _bridge = bridge,
       _acquisition = bridge is CatalogAcquisitionHost
           ? bridge as CatalogAcquisitionHost
           : null,
       _openBook = openBook,
       _libraryChanged = libraryChanged,
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
  final FlutterBridge _bridge;
  final CatalogAcquisitionHost? _acquisition;
  final void Function(FlutterLibraryBook)? _openBook;
  final VoidCallback? _libraryChanged;
  BigInt? _addCancellation;
  int _locationRevision = 0;
  BrowseModel _model = const BrowseModel();
  BrowseModel get model => _model;
  Timer? _timer;
  CancellationToken? _queryCancellation;
  CancellationToken? _detailCancellation;
  int _revision = 0;
  int _detailRevision = 0;
  bool _disposed = false;
  bool _refreshing = false;
  bool _historyRequested = false;
  bool _historyLoaded = false;
  bool _historyDirty = false;
  Future<void> _historyWrite = Future.value();

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
        if (!_historyRequested && _bridge is CatalogHost) {
          _historyRequested = true;
          unawaited(() async {
            try {
              dispatch(
                _BrowseHistoryLoaded(
                  await (_bridge as CatalogHost).recentCatalogSearches(),
                ),
              );
            } catch (_) {
              dispatch(const _BrowseHistoryLoaded([]));
            }
          }());
        }
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
      case _BrowseHistoryLoaded(:final searches):
        _emit(
          _model.copyWith(
            recentSearches: {
              ..._model.recentSearches,
              ...searches.where(
                (query) => query.trim().isNotEmpty && query.length <= 256,
              ),
            }.take(8).toList(),
          ),
        );
        _historyLoaded = true;
        _persistHistory();
      case BrowseSearchSubmitted():
        _rememberSearch();
      case BrowseChanged(:final criteria):
        if (criteria == _model.criteria) {
          // The same author from their own book's details: show their books.
          if (_model.details != null) dispatch(const BrowseBackRequested());
          return;
        }
        _cancelAdd();
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
        :final categoryBooks,
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
            categoryBooks: categoryBooks,
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
        _emit(
          _model.copyWith(
            refreshing: false,
            offline: failed,
            categoryBooks: installed ? const {} : null,
          ),
        );
        // Failed and unchanged refreshes leave the current results in place.
        if (installed) _load();
      case BrowseBookRequested(:final id):
        _rememberSearch();
        _cancelAdd();
        _detailCancellation?.cancel();
        final revision = ++_detailRevision;
        final cancellation = _detailCancellation = CancellationToken();
        _emit(
          _model.copyWith(
            details: () => null,
            detailBusy: true,
            detailFailed: false,
            acquisition: const BrowseAcquisition(),
            saveOptions: () => null,
            locationBusy: false,
          ),
        );
        _loadSaveOptions(revision);
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
            subjectsExpanded: false,
          ),
        );
      case BrowseBackRequested():
        _cancelAdd();
        _detailRevision++;
        _detailCancellation?.cancel();
        _emit(
          _model.copyWith(
            details: () => null,
            detailBusy: false,
            detailFailed: false,
          ),
        );
      case BrowseSubjectsExpanded():
        _emit(_model.copyWith(subjectsExpanded: true));
      case BrowseEditionSelected(:final index):
        if (!_model.acquisition.busy &&
            index >= 0 &&
            index < (_model.details?.editions.length ?? 0)) {
          _emit(
            _model.copyWith(
              edition: index,
              acquisition: BrowseAcquisition(
                failed: _model.acquisition.locationChanged,
                locationChanged: _model.acquisition.locationChanged,
              ),
            ),
          );
        }
      case BrowseSaveOptionsRequested():
        _loadSaveOptions(_detailRevision);
      case _BrowseSaveOptionsLoaded(:final revision, :final options):
        if (revision == _detailRevision) {
          _emit(
            _model.copyWith(saveOptions: () => options, optionsBusy: false),
          );
        }
      case BrowseSaveLocationSelected(:final id):
        if (_model.acquisition.busy ||
            _model.locationBusy ||
            _acquisition == null) {
          return;
        }
        final revision = _detailRevision;
        final locationRevision = ++_locationRevision;
        _emit(_model.copyWith(locationBusy: true));
        unawaited(() async {
          try {
            await _acquisition.selectCatalogSaveLocation(id);
            dispatch(
              _BrowseSaveLocationSaved(revision, locationRevision, id, false),
            );
          } catch (_) {
            dispatch(
              _BrowseSaveLocationSaved(revision, locationRevision, id, true),
            );
          }
        }());
      case _BrowseSaveLocationSaved(
        :final revision,
        :final locationRevision,
        :final id,
        :final failed,
      ):
        if (revision != _detailRevision ||
            locationRevision != _locationRevision) {
          return;
        }
        final options = _model.saveOptions;
        _emit(
          _model.copyWith(
            locationBusy: false,
            saveOptions: () => failed || options == null
                ? options
                : (locations: options.locations, selected: id),
            acquisition: failed
                ? BrowseAcquisition(
                    failed: true,
                    locationChanged: _model.acquisition.locationChanged,
                  )
                : const BrowseAcquisition(),
          ),
        );
      case BrowseAddRequested():
        final details = _model.details;
        if (_acquisition == null ||
            details == null ||
            details.editions.isEmpty ||
            _model.saveOptions == null ||
            _model.acquisition.busy ||
            _model.acquisition.locationChanged ||
            _model.locationBusy) {
          return;
        }
        final edition = details.editions[_model.edition];
        final locationId = _model.saveOptions!.selected;
        final location = _model.saveOptions!.locations
            .where((option) => option.id == locationId)
            .firstOrNull;
        final revision = _detailRevision;
        final id = _addCancellation = _bridge.createCancellation();
        _emit(
          _model.copyWith(acquisition: const BrowseAcquisition(busy: true)),
        );
        unawaited(() async {
          try {
            final result = await _acquisition.addCatalogBook(
              bookId: details.book.id,
              sourceId: edition.sourceId,
              editionId: edition.editionId,
              locationId: locationId,
              destination: location == null
                  ? null
                  : (
                      generation: location.generation,
                      directory: location.directory,
                    ),
              cancellationId: id,
              progress: (received, total) =>
                  dispatch(_BrowseAddProgress(revision, id, received, total)),
            );
            dispatch(_BrowseAdded(revision, id, result));
          } catch (error) {
            dispatch(
              _BrowseAddFailed(
                revision,
                id,
                locationChanged: error is CatalogDestinationChanged,
              ),
            );
          } finally {
            _bridge.releaseCancellation(id: id);
          }
        }());
      case _BrowseAddProgress(
        :final revision,
        :final id,
        :final received,
        :final total,
      ):
        if (revision == _detailRevision && id == _addCancellation) {
          _emit(
            _model.copyWith(
              acquisition: BrowseAcquisition(
                busy: true,
                cancelling: _model.acquisition.cancelling,
                received: received,
                total: total,
              ),
            ),
          );
        }
      case BrowseAddCancelled():
        final id = _addCancellation;
        if (id != null) {
          _bridge.cancel(id: id);
          _emit(
            _model.copyWith(
              acquisition: const BrowseAcquisition(
                busy: true,
                cancelling: true,
              ),
            ),
          );
        }
      case _BrowseAdded(:final revision, :final id, :final result):
        // A committed save still belongs on the shelf after leaving details.
        _libraryChanged?.call();
        local.dispatch(const ShellSearchRefreshed());
        if (revision == _detailRevision && id == _addCancellation) {
          _addCancellation = null;
          _emit(
            _model.copyWith(acquisition: BrowseAcquisition(result: result)),
          );
        }
      case _BrowseAddFailed(:final revision, :final id, :final locationChanged):
        if (revision == _detailRevision && id == _addCancellation) {
          _addCancellation = null;
          _emit(
            _model.copyWith(
              saveOptions: locationChanged ? () => null : null,
              acquisition: BrowseAcquisition(
                cancelled: _model.acquisition.cancelling,
                failed: !_model.acquisition.cancelling,
                locationChanged: locationChanged,
              ),
            ),
          );
          if (locationChanged) _loadSaveOptions(revision);
        }
      case BrowseReadRequested():
        final result = _model.acquisition.result;
        if (result != null && !_model.acquisition.busy) {
          _openBook?.call(result.book);
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

  void _cancelAdd() {
    final id = _addCancellation;
    if (id != null) _bridge.cancel(id: id);
    _addCancellation = null;
  }

  void _rememberSearch() {
    final query = _model.criteria.query.trim();
    if (query.isEmpty || query.length > 256) return;
    final searches = [
      query,
      ..._model.recentSearches.where((s) => s != query),
    ].take(8).toList();
    _emit(_model.copyWith(recentSearches: searches));
    _historyDirty = true;
    _persistHistory();
  }

  void _persistHistory() {
    if (!_historyLoaded || !_historyDirty) return;
    _historyDirty = false;
    if (_bridge case final CatalogHost host) {
      final searches = _model.recentSearches;
      _historyWrite = _historyWrite.then((_) async {
        try {
          await host.saveRecentCatalogSearches(searches);
        } catch (_) {
          // History is best-effort; personal and catalog search remain usable.
        }
      });
      unawaited(_historyWrite);
    }
  }

  void _loadSaveOptions(int revision) {
    if (_acquisition == null) return;
    _emit(_model.copyWith(optionsBusy: true));
    unawaited(() async {
      try {
        final options = await _acquisition.catalogSaveOptions();
        dispatch(_BrowseSaveOptionsLoaded(revision, options));
      } catch (_) {
        dispatch(_BrowseSaveOptionsLoaded(revision, null));
      }
    }());
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
        var categoryBooks = _model.categoryBooks;
        if (categoryBooks.isEmpty &&
            c.filter == BrowseFilter.all &&
            c.query.trim().isEmpty &&
            c.category == null &&
            c.author == null) {
          categoryBooks =
              await catalog?.categoryPreviews(
                categoryIds: [
                  for (final category in categories)
                    if (!catalogCategoryArtwork.containsKey(category.id))
                      category.id,
                ],
                cancellation: cancellation,
              ) ??
              const {};
        }
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
            categoryBooks,
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
    _cancelAdd();
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

/// Subject tags a phone details page shows before its "+N more" chip.
const catalogPhoneSubjectLimit = 5;

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
    this.categoryBooks = const {},
    this.recentSearches = const [],
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
    this.subjectsExpanded = false,
    this.linkFailed = false,
    this.saveOptions,
    this.optionsBusy = false,
    this.locationBusy = false,
    this.acquisition = const BrowseAcquisition(),
  });
  final CatalogSaveOptions? saveOptions;
  final bool optionsBusy;
  final bool locationBusy;
  final BrowseAcquisition acquisition;
  final BrowseCriteria criteria;
  final List<CatalogBook> books;
  final List<CatalogAuthor> authors;
  final List<CatalogCategory> categories;
  final Map<String, List<CatalogBook>> categoryBooks;
  final List<String> recentSearches;
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

  /// Whether the phone details page shows every subject tag, not just the
  /// first [catalogPhoneSubjectLimit].
  final bool subjectsExpanded;
  BrowseModel copyWith({
    BrowseCriteria? criteria,
    List<CatalogBook>? books,
    List<CatalogAuthor>? authors,
    List<CatalogCategory>? categories,
    Map<String, List<CatalogBook>>? categoryBooks,
    List<String>? recentSearches,
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
    bool? subjectsExpanded,
    bool? linkFailed,
    CatalogSaveOptions? Function()? saveOptions,
    bool? optionsBusy,
    bool? locationBusy,
    BrowseAcquisition? acquisition,
  }) => BrowseModel(
    criteria: criteria ?? this.criteria,
    books: books == null ? this.books : List.unmodifiable(books),
    authors: authors == null ? this.authors : List.unmodifiable(authors),
    categories: categories == null
        ? this.categories
        : List.unmodifiable(categories),
    categoryBooks: categoryBooks == null
        ? this.categoryBooks
        : Map.unmodifiable(categoryBooks),
    recentSearches: recentSearches == null
        ? this.recentSearches
        : List.unmodifiable(recentSearches),
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
    subjectsExpanded: subjectsExpanded ?? this.subjectsExpanded,
    linkFailed: linkFailed ?? false,
    saveOptions: saveOptions == null ? this.saveOptions : saveOptions(),
    optionsBusy: optionsBusy ?? this.optionsBusy,
    locationBusy: locationBusy ?? this.locationBusy,
    acquisition: acquisition ?? this.acquisition,
  );
}

final class BrowseAcquisition {
  const BrowseAcquisition({
    this.busy = false,
    this.cancelling = false,
    this.received = 0,
    this.total,
    this.result,
    this.failed = false,
    this.cancelled = false,
    this.locationChanged = false,
  });
  final bool busy, cancelling, failed, cancelled, locationChanged;
  final int received;
  final int? total;
  final CatalogAddedBook? result;
}

sealed class BrowseMessage {
  const BrowseMessage();
}

final class BrowseOpened extends BrowseMessage {
  const BrowseOpened();
}

final class BrowseSearchSubmitted extends BrowseMessage {
  const BrowseSearchSubmitted();
}

final class _BrowseHistoryLoaded extends BrowseMessage {
  const _BrowseHistoryLoaded(this.searches);
  final List<String> searches;
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

final class BrowseSubjectsExpanded extends BrowseMessage {
  const BrowseSubjectsExpanded();
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
    this.categoryBooks,
    this.filters,
    this.more,
    this.installed,
  );
  final int revision;
  final List<CatalogBook> books;
  final List<CatalogAuthor> authors;
  final List<CatalogCategory> categories;
  final Map<String, List<CatalogBook>> categoryBooks;
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

final class BrowseSaveOptionsRequested extends BrowseMessage {
  const BrowseSaveOptionsRequested();
}

final class BrowseSaveLocationSelected extends BrowseMessage {
  const BrowseSaveLocationSelected(this.id);
  final String? id;
}

final class BrowseAddRequested extends BrowseMessage {
  const BrowseAddRequested();
}

final class BrowseAddCancelled extends BrowseMessage {
  const BrowseAddCancelled();
}

final class BrowseReadRequested extends BrowseMessage {
  const BrowseReadRequested();
}

final class _BrowseSaveOptionsLoaded extends BrowseMessage {
  const _BrowseSaveOptionsLoaded(this.revision, this.options);
  final int revision;
  final CatalogSaveOptions? options;
}

final class _BrowseSaveLocationSaved extends BrowseMessage {
  const _BrowseSaveLocationSaved(
    this.revision,
    this.locationRevision,
    this.id,
    this.failed,
  );
  final int revision, locationRevision;
  final String? id;
  final bool failed;
}

final class _BrowseAddProgress extends BrowseMessage {
  const _BrowseAddProgress(this.revision, this.id, this.received, this.total);
  final int revision, received;
  final BigInt id;
  final int? total;
}

final class _BrowseAdded extends BrowseMessage {
  const _BrowseAdded(this.revision, this.id, this.result);
  final int revision;
  final BigInt id;
  final CatalogAddedBook result;
}

final class _BrowseAddFailed extends BrowseMessage {
  const _BrowseAddFailed(
    this.revision,
    this.id, {
    this.locationChanged = false,
  });
  final int revision;
  final BigInt id;
  final bool locationChanged;
}
