/// Device-owned capabilities for the places where books live.
library;

import '../cancellation.dart';

/// Expected failures from a location, independent of its transport.
enum LocationFailure { offline, revoked, missing }

final class LocationException implements Exception {
  const LocationException(this.failure);

  final LocationFailure failure;

  @override
  String toString() => 'LocationException(${failure.name})';
}

/// A device-local locator, not a book identity or a portable file path.
/// [key] is opaque to the core and meaningful only to [locationId]'s adapter.
typedef BookLocator = ({String locationId, String key});

/// Metadata returned without downloading a book's contents.
final class LocationEntry {
  const LocationEntry({
    required this.key,
    required this.name,
    required this.isDirectory,
    this.size,
    this.revision,
  });

  final String key;
  final String name;
  final bool isDirectory;
  final int? size;

  /// Provider version/ETag, for detecting replacement, never content identity.
  final String? revision;
}

/// One bounded, nonrecursive directory listing.
final class LocationPage {
  LocationPage(Iterable<LocationEntry> entries, {this.nextCursor})
    : entries = List.unmodifiable(entries);

  final List<LocationEntry> entries;
  final String? nextCursor;
}

/// Metadata in a recursive scan. Depth is the containing directory's depth
/// relative to the selected root: immediate children have depth zero.
typedef LocationTreeEntry = ({LocationEntry entry, int depth});

/// Optional server-side recursive metadata discovery. Directory pickers still
/// use [LibraryLocation.list], whose nonrecursive contract is unchanged.
/// Implementations own pagination, reject repeated cursors, and check
/// cancellation between pages. No file contents are read. Pages may be empty.
abstract interface class RecursiveLibraryLocation {
  Stream<List<LocationTreeEntry>> listRecursive({
    String? directory,
    CancellationToken? cancellation,
  });
}

/// A folder grant or direct provider connection owned by this device.
///
/// Implementations keep credentials outside records, in platform credential
/// storage. They throw [LocationException] for offline/revoked/missing, and
/// CoreException for cancellation, invalid input and resource limits. Listing
/// and stat never download files. Reads stream with backpressure; [end] is an
/// exclusive byte offset. A null end reads through EOF. A range past EOF ends
/// at EOF; an offset at or beyond EOF yields an empty stream. Negative offsets
/// and end < start are invalid. A provider without ranged reads must report
/// unsupported rather than silently download the whole file.
///
/// Write creates/replaces one file, and returns its provider-assigned key.
/// Adapters must not publish partial writes as successful results. Pickers,
/// grant lifetimes, OAuth and transport belong to adapters, not widgets.
abstract interface class LibraryLocation {
  String get id;

  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  });

  Future<LocationEntry> stat(String key, {CancellationToken? cancellation});

  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  });

  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  });
}
