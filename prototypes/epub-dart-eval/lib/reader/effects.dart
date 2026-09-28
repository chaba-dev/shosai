/// Controller-owned adapters: platform effects the widgets never await.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Reads a document's bytes. The prototype uses local files.
abstract class EpubDocumentSource {
  Future<Uint8List> read(String path);
}

class EpubFileDocumentSource implements EpubDocumentSource {
  const EpubFileDocumentSource();

  @override
  Future<Uint8List> read(String path) async =>
      Uint8List.fromList(await File(path).readAsBytes());
}

/// Clipboard effect.
abstract class EpubClipboard {
  Future<void> setText(String text);
}

class EpubSystemClipboard implements EpubClipboard {
  const EpubSystemClipboard();

  @override
  Future<void> setText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

/// A durable new-session location.
///
/// Production persistence is SQLite (`reading_state`: page + nullable offset);
/// the prototype stores a JSON map so "reopening" can be demonstrated without
/// a database. Old-schema compatibility is explicitly not a gate here.
class EpubStoredPosition {
  const EpubStoredPosition({required this.spine, required this.scalar});

  final int spine;
  final int scalar;

  Map<String, Object> toJson() => {'spine': spine, 'scalar': scalar};

  static EpubStoredPosition? fromJson(Object? json) {
    if (json is! Map) return null;
    final spine = json['spine'];
    final scalar = json['scalar'];
    if (spine is! int || scalar is! int) return null;
    return EpubStoredPosition(spine: spine, scalar: scalar);
  }
}

abstract class EpubPositionStore {
  Future<EpubStoredPosition?> read(String documentPath);

  Future<void> write(String documentPath, EpubStoredPosition position);
}

/// In-memory store used by tests and by the measurement harness.
class EpubMemoryPositionStore implements EpubPositionStore {
  final Map<String, EpubStoredPosition> _positions = {};

  @override
  Future<EpubStoredPosition?> read(String documentPath) async =>
      _positions[documentPath];

  @override
  Future<void> write(String documentPath, EpubStoredPosition position) async {
    _positions[documentPath] = position;
  }
}

/// Bounded JSON-file store: one file per document path hash.
class EpubFilePositionStore implements EpubPositionStore {
  EpubFilePositionStore(this.directory);

  final Directory directory;

  File _fileFor(String documentPath) {
    var hash = 0x811c9dc5;
    for (final unit in documentPath.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return File('${directory.path}/position-$hash.json');
  }

  @override
  Future<EpubStoredPosition?> read(String documentPath) async {
    final file = _fileFor(documentPath);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return EpubStoredPosition.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String documentPath, EpubStoredPosition position) async {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    await _fileFor(documentPath).writeAsString(jsonEncode(position.toJson()));
  }
}

/// Registers an embedded font family with the Flutter engine.
abstract class EpubFontRegistrar {
  Future<void> register(String family, Uint8List bytes);
}

class EpubEngineFontRegistrar implements EpubFontRegistrar {
  const EpubEngineFontRegistrar();

  @override
  Future<void> register(String family, Uint8List bytes) async {
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

/// Decodes an image resource.
abstract class EpubImageDecoder {
  Future<ui.Image?> decode(Uint8List bytes);
}

class EpubEngineImageDecoder implements EpubImageDecoder {
  const EpubEngineImageDecoder();

  @override
  Future<ui.Image?> decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }
}
