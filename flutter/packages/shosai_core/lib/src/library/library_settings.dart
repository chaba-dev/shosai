/// How the library is shown, stored as preferences.
library;

import '../preferences.dart';
import '../store/store.dart';
import 'book.dart';

const _sortKey = 'library.sort';

/// Loads and saves the order the library lists books in.
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
}
