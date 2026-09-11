import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Storage Access Framework adapter. Provider bytes never cross Dart.
abstract interface class AndroidDocumentImportChannel {
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]);
}

final class MethodAndroidDocumentImportChannel
    implements AndroidDocumentImportChannel {
  const MethodAndroidDocumentImportChannel();

  static const MethodChannel _channel = MethodChannel(
    'dev.shosai/document_import',
  );

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      _channel.invokeMethod<Object?>(method, arguments);
}

enum DocumentImportError {
  unavailable,
  busy,
  permissionDenied,
  tooLarge,
  readFailed,
  cancelled,
  invalidRequest,
}

@immutable
final class DocumentImportCapabilities {
  const DocumentImportCapabilities({
    required this.files,
    required this.multipleFiles,
    required this.folders,
    required this.referencedImports,
    required this.managedImports,
    required this.maximumAcquisitions,
    required this.maximumBytesPerFile,
  });

  final bool files;
  final bool multipleFiles;
  final bool folders;
  final bool referencedImports;
  final bool managedImports;
  final int maximumAcquisitions;
  final int maximumBytesPerFile;
}

sealed class DocumentSelectionResult {
  const DocumentSelectionResult();
}

final class DocumentSelectionCancelled extends DocumentSelectionResult {
  const DocumentSelectionCancelled();
}

final class DocumentSelectionFailure extends DocumentSelectionResult {
  const DocumentSelectionFailure(this.error);
  final DocumentImportError error;
}

final class DocumentSelection extends DocumentSelectionResult {
  const DocumentSelection(this.documents);
  final List<SelectedProviderDocument> documents;
}

@immutable
final class SelectedProviderDocument {
  const SelectedProviderDocument({required this.token, required this.name});
  final String token;
  final String name;
}

sealed class DocumentAcquisitionResult {
  const DocumentAcquisitionResult();
}

final class DocumentAcquisitionFailure extends DocumentAcquisitionResult {
  const DocumentAcquisitionFailure(this.error);
  final DocumentImportError error;
}

/// A bounded app-owned temporary file. It is valid only for a managed import.
/// [releaseToken] must be released after the core has copied or rejected it.
final class AcquiredProviderDocument extends DocumentAcquisitionResult {
  const AcquiredProviderDocument({
    required this.path,
    required this.releaseToken,
  });
  final String path;
  final String releaseToken;
  bool get managedOnly => true;
}

final class AndroidDocumentImportAdapter {
  AndroidDocumentImportAdapter({
    AndroidDocumentImportChannel channel =
        const MethodAndroidDocumentImportChannel(),
  }) : _channel = channel;

  final AndroidDocumentImportChannel _channel;

  Future<DocumentImportCapabilities> capabilities() async {
    final value = _map(await _channel.invoke('capabilities'));
    return DocumentImportCapabilities(
      files: value['files'] == true,
      multipleFiles: value['multipleFiles'] == true,
      folders: value['folders'] == true,
      referencedImports: value['referencedImports'] == true,
      managedImports: value['managedImports'] == true,
      maximumAcquisitions: _integer(value['maximumAcquisitions']),
      maximumBytesPerFile: _integer(value['maximumBytesPerFile']),
    );
  }

  Future<DocumentSelectionResult> selectFiles() async {
    try {
      final value = _map(await _channel.invoke('selectFiles'));
      if (value['cancelled'] == true) return const DocumentSelectionCancelled();
      final documents = (value['documents'] as List<Object?>? ?? const [])
          .map(_map)
          .map(
            (item) => SelectedProviderDocument(
              token: item['token'] as String,
              name: item['name'] as String? ?? 'Document',
            ),
          )
          .toList(growable: false);
      return DocumentSelection(documents);
    } on PlatformException catch (error) {
      return DocumentSelectionFailure(_error(error.code));
    }
  }

  Future<DocumentAcquisitionResult> acquire({
    required SelectedProviderDocument document,
    required String operationId,
  }) async {
    try {
      final value = _map(
        await _channel.invoke('acquire', {
          'token': document.token,
          'operationId': operationId,
        }),
      );
      return AcquiredProviderDocument(
        path: value['path'] as String,
        releaseToken: value['releaseToken'] as String,
      );
    } on PlatformException catch (error) {
      return DocumentAcquisitionFailure(_error(error.code));
    }
  }

  Future<void> discardSelection(String token) =>
      _channel.invoke('discardSelection', {'token': token});

  Future<void> cancel(String operationId) =>
      _channel.invoke('cancel', {'operationId': operationId});

  Future<void> release(String releaseToken) =>
      _channel.invoke('release', {'releaseToken': releaseToken});

  static Map<Object?, Object?> _map(Object? value) =>
      value as Map<Object?, Object?>;
  static int _integer(Object? value) => (value as num?)?.toInt() ?? 0;
  static DocumentImportError _error(String code) => switch (code) {
    'busy' => DocumentImportError.busy,
    'permission_denied' => DocumentImportError.permissionDenied,
    'too_large' => DocumentImportError.tooLarge,
    'read_failed' => DocumentImportError.readFailed,
    'cancelled' => DocumentImportError.cancelled,
    'invalid_request' => DocumentImportError.invalidRequest,
    _ => DocumentImportError.unavailable,
  };
}
