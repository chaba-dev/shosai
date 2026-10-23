/// How the library is shown, stored as preferences.
library;

import '../preferences.dart';
import '../store/store.dart';
import 'book.dart';

const _sortKey = 'library.sort';
const _openBooksKey = 'shell.openBooks';

/// Loads and saves the order the library lists books in, and the books left
/// open, which come back when the application starts again (RFD 4, outcome
/// 4).
final class LibrarySettingsStore {
  LibrarySettingsStore(Store store) : _preferences = Preferences(store);

  final Preferences _preferences;

  /// The saved order, or [LibrarySort.recent] when none is saved or the
  /// saved one is unknown.
  Future<LibrarySort> loadSort() async =>
      LibrarySort.values.asNameMap()[await _preferences.get(_sortKey)] ??
      LibrarySort.recent;

  Future<void> saveSort(LibrarySort sort) =>
      _preferences.set(_sortKey, sort.name);

  /// The open books as the application last saved them, or null. The value
  /// is the application's own encoding; the core keeps it as it is.
  Future<String?> loadOpenBooks() => _preferences.get(_openBooksKey);

  Future<void> saveOpenBooks(String session) =>
      _preferences.set(_openBooksKey, session);
}
