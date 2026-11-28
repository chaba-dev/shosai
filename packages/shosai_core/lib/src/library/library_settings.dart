/// How the library is shown, stored as preferences.
library;

import '../preferences.dart';
import '../store/store.dart';
import 'book.dart';

const _sortKey = 'library.sort';
const _layoutKey = 'library.layout';

/// How the library shows its books: a shelf of covers, or rows.
enum LibraryLayout { grid, list }

/// Loads and saves the order the library lists books in and its layout.
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

  /// The saved layout, or [LibraryLayout.grid] when none is saved or the
  /// saved one is unknown.
  Future<LibraryLayout> loadLayout() async =>
      LibraryLayout.values.asNameMap()[await _preferences.get(_layoutKey)] ??
      LibraryLayout.grid;

  Future<void> saveLayout(LibraryLayout layout) =>
      _preferences.set(_layoutKey, layout.name);
}
