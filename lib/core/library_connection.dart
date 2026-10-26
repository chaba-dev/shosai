/// Device-local connection configuration, independent of a storage adapter.
library;

import 'package:shosai_core/shosai_core.dart';

/// Only nonsecret provider configuration belongs here. Credentials must remain
/// in provider-owned secure storage, not preferences, catalogs or book records.
/// Directory keys are opaque to the application and scoped to this connection.
final class LibraryConnection {
  LibraryConnection(
    this.id,
    this.label,
    this.provider,
    Map<String, String> configuration, {
    this.directory,
    this.directoryLabel,
  }) : configuration = Map.unmodifiable(configuration);

  final String id;
  final String label;
  final String provider;
  final Map<String, String> configuration;
  final String? directory;
  final String? directoryLabel;

  LibraryConnection withDirectory(String? key, String? label) =>
      LibraryConnection(
        id,
        this.label,
        provider,
        configuration,
        directory: key,
        directoryLabel: label,
      );

  /// Compact wire order: id, label, provider, configuration, directory, label.
  /// A migrated folder record is 31 bytes smaller than its legacy object, so
  /// even a full preference value needs no migration headroom.
  List<Object?> toJson() => [
    id,
    label,
    provider,
    configuration,
    directory,
    directoryLabel,
  ];

  factory LibraryConnection.fromJson(List<dynamic> value) => LibraryConnection(
    value[0] as String,
    value[1] as String,
    value[2] as String,
    (value[3] as Map).cast<String, String>(),
    directory: value[4] as String?,
    directoryLabel: value[5] as String?,
  );
}

/// Providers own setup and access lifetimes; consumers only use LibraryLocation.
/// Setup is a controller effect, never an effect started by a widget.
abstract interface class ConnectionProvider {
  String get id;
  Future<LibraryConnection?> setup(String connectionId);
  Future<LibraryConnection> refresh(LibraryConnection connection);
  Future<LibraryLocation> open(LibraryConnection connection);
  bool sameAccess(LibraryConnection first, LibraryConnection second);
  Future<void> release(LibraryConnection connection);
}
