import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

import '../support/epub_navigation_fixture.dart';

/// Opt-in real-book EPUB routing sweep.
///
/// Classifies, for every EPUB listed in an opt-in manifest, whether the
/// production reader's routing gate would serve each chapter from the Dart
/// engine or keep it on the retained renderer, and records the *reason*
/// (canonical mismatch, retained stream ceiling, retained-side errors,
/// bundled-font coverage, indivisible-unit ceilings, engine admission).
///
/// The sweep mirrors the production gate in
/// `lib/reader/controller.dart` (`_epubRelayout` / `_epubUnitMatchesRetained`):
/// a unit is servable only when the engine's canonical stream equals the
/// retained `epub_canonical_text` stream, the bundled faces cover the text,
/// and the chapter's indivisible units fit the bounded-work ceilings. The
/// retained streams come from the real Rust bridge; the retained parse
/// (`openDocument`) is the production one.
///
/// Opt-in because it reads real user books: set
/// `SHOSAI_EPUB_REAL_CORPUS=<manifest.json>` where the manifest is
/// `{"books":[{"id":"book-01","path":"/abs/path.epub"}, ...]}` with *anonymous*
/// stable ids (public reports quote ids, never titles or paths). Detailed
/// per-unit output — including private-derived offsets — goes to
/// `SHOSAI_EPUB_CORPUS_OUT` (a private path when used with real books).
/// Without the environment variables the file registers a skip and touches
/// nothing.
///
/// Calibration controls run before the corpus: the checked-in synthetic
/// parity fixture must route through the same real bridge (the retained
/// parser's stream equals the engine's), and an over-deep admission fixture
/// must be classified as an engine-admission refusal, so a harness drift that
/// would turn refusals into passes or vice versa fails the run.
///
/// Run:
/// ```sh
/// cd flutter && flutter test test/corpus/epub_real_corpus_sweep_test.dart
/// ```
/// with the host bridge built (`cargo build -p shosai-flutter-bridge`).

const _bridgeDebugLibrary = '../target/debug/libshosai_flutter_bridge.so';

void main() {
  final manifestPath = Platform.environment['SHOSAI_EPUB_REAL_CORPUS'];
  final outPath = Platform.environment['SHOSAI_EPUB_CORPUS_OUT'];
  final supported = Platform.isLinux || Platform.isMacOS;

  test('real-book EPUB routing sweep', () async {
    if (!supported) {
      return;
    }
    if (manifestPath == null) {
      // Opt-in: silently skip without a manifest.
      return;
    }
    final manifest =
        jsonDecode(File(manifestPath).readAsStringSync())
            as Map<String, Object?>;
    final books = (manifest['books'] as List<Object?>)
        .cast<Map<String, Object?>>();
    _validateManifest(books);
    IOSink? sink;
    if (outPath != null) {
      sink = File(outPath).openWrite(mode: FileMode.write);
    }
    final directory = await Directory.systemTemp.createTemp(
      'shosai-epub-corpus-',
    );
    var failures = 0;
    try {
      final library = Platform.isMacOS
          ? '../target/debug/libshosai_flutter_bridge.dylib'
          : _bridgeDebugLibrary;
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final bridge = FlutterBridge.withDatabasePath(
        databasePath: '${directory.path}/corpus.sqlite3',
      );
      try {
        await _calibrate(bridge, sink);
        for (final entry in books) {
          final id = entry['id']! as String;
          final path = entry['path']! as String;
          try {
            final record = await _classifyBook(bridge, id, path);
            sink?.writeln(jsonEncode(record));
            await sink?.flush();
            final reasonText = (record['reasons'] as Map<String, Object?>)
                .entries
                .where((e) => e.key != 'routed')
                .map((e) => '${e.key}=${e.value}')
                .join(' ');
            stdout.writeln(
              '${record['outcome']} $id '
              'units=${record['retainedUnits']} '
              'routed=${record['routedUnits']} '
              '$reasonText',
            );
            await stdout.flush();
          } catch (error) {
            // A FlutterBridgeError at open is a reader-side outcome (the
            // production app would show the same refusal), recorded
            // transparently with its kind; anything else is a harness
            // failure and fails the run.
            final refused = error is FlutterBridgeError;
            if (!refused) failures += 1;
            sink?.writeln(
              jsonEncode({
                'id': id,
                'outcome': refused ? 'open-refused' : 'harness-error',
                'detail': refused
                    ? '${error.kind.name}: ${error.message}'
                    : error.toString(),
              }),
            );
            stdout.writeln(
              '${refused ? 'open-refused' : 'harness-error'} $id $error',
            );
            await stdout.flush();
          }
        }
      } finally {
        bridge.dispose();
      }
    } finally {
      await sink?.flush();
      await sink?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
    expect(failures, 0, reason: 'harness errors are infrastructure failures');
  }, timeout: const Timeout(Duration(hours: 3)));
}

/// Manifest sanity: an empty or malformed manifest must fail the run instead
/// of producing a vacuous pass.
void _validateManifest(List<Map<String, Object?>> books) {
  if (books.isEmpty) {
    throw ArgumentError('corpus manifest lists no books');
  }
  final seen = <String>{};
  for (final entry in books) {
    final id = entry['id'];
    final path = entry['path'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('corpus manifest entry has no non-empty id');
    }
    if (!seen.add(id)) {
      throw ArgumentError('corpus manifest has duplicate id: $id');
    }
    if (path is! String || path.isEmpty) {
      throw ArgumentError('corpus manifest entry $id has no path');
    }
  }
}

/// Calibration controls over the checked-in synthetic fixtures.
///
/// The parity fixture must route through the real bridge (retained stream ==
/// engine stream), and the over-deep admission fixture must be refused by the
/// engine's admission ceiling. A harness that classified these wrongly would
/// misclassify the whole corpus.
Future<void> _calibrate(FlutterBridge bridge, IOSink? sink) async {
  final parity = canonicalParityEpub();
  final parityFile = File(
    '${(await Directory.systemTemp.createTemp('shosai-epub-calib-')).path}/'
    'parity.epub',
  );
  try {
    await parityFile.writeAsBytes(parity, flush: true);
    final record = await _classifyBook(
      bridge,
      'calibration-parity',
      parityFile.path,
    );
    expect(
      record['outcome'],
      'classified',
      reason:
          'calibration: the parity fixture must be classified, not refused '
          'at open or admission',
    );
    final routed = record['routedUnits'] as int;
    final units = record['retainedUnits'] as int;
    expect(
      units,
      greaterThan(0),
      reason: 'calibration: the parity fixture must produce at least one unit',
    );
    expect(
      routed,
      units,
      reason:
          'calibration: the synthetic parity fixture must route through the '
          'real bridge (engine stream == retained stream)',
    );
    sink?.writeln(jsonEncode(record));
  } finally {
    await parityFile.delete();
  }

  final admissionFile = File(
    '${(await Directory.systemTemp.createTemp('shosai-epub-calib-')).path}/'
    'admission.epub',
  );
  try {
    await admissionFile.writeAsBytes(
      admissionEpub(spanNesting: 65),
      flush: true,
    );
    final record = await _classifyBook(
      bridge,
      'calibration-admission',
      admissionFile.path,
    );
    expect(
      record['outcome'],
      'engine-limit-error',
      reason:
          'calibration: the over-deep admission fixture must be refused at '
          'engine admission, not routed and not a book failure',
    );
    sink?.writeln(jsonEncode(record));
  } finally {
    await admissionFile.delete();
  }
}

Future<Map<String, Object?>> _classifyBook(
  FlutterBridge bridge,
  String id,
  String path,
) async {
  final cancellation = bridge.createCancellation();
  FlutterDocumentSummary? document;
  try {
    document = await bridge.openDocument(
      request: FlutterOpenRequest(localId: path, pathKey: path),
      cancellationId: cancellation,
    );
    if (document.format != FlutterBookFormat.epub) {
      return {
        'id': id,
        'outcome': 'not-epub',
        'format': document.format.name,
        'retainedUnits': 0,
        'routedUnits': 0,
        'reasons': <String, Object?>{},
      };
    }
    final retainedUnits = document.logicalUnitCount.toInt();
    final Uint8List sourceBytes;
    try {
      sourceBytes = await bridge.epubSourceBytes(
        document: document.handle,
        cancellationId: cancellation,
      );
    } catch (error) {
      return {
        'id': id,
        'outcome': 'retained-source-error',
        'detail': error is FlutterBridgeError
            ? '${error.kind.name}: ${error.message}'
            : error.toString(),
        'retainedUnits': retainedUnits,
        'routedUnits': 0,
        'reasons': <String, Object?>{},
      };
    }
    final EpubBook book;
    try {
      book = openEpubBytes(sourceBytes);
    } on EpubLimitError catch (error) {
      return {
        'id': id,
        'outcome': 'engine-limit-error',
        'detail': error.toString(),
        'retainedUnits': retainedUnits,
        'routedUnits': 0,
        'reasons': <String, Object?>{},
      };
    } on EpubFormatError catch (error) {
      return {
        'id': id,
        'outcome': 'engine-format-error',
        'detail': error.toString(),
        'retainedUnits': retainedUnits,
        'routedUnits': 0,
        'reasons': <String, Object?>{},
      };
    }
    if (book.chapters.length != retainedUnits) {
      // The production reader indexes chapters by the retained summary's
      // logical units; a count divergence keeps chapters on the retained
      // renderer (the gate indexes by unit and compares per unit).
      return {
        'id': id,
        'outcome': 'unit-count-mismatch',
        'retainedUnits': retainedUnits,
        'engineChapters': book.chapters.length,
        'routedUnits': 0,
        'reasons': <String, Object?>{},
      };
    }

    final coverage = await _bundledCoverage();
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: sourceBytes,
    );
    try {
      var routedUnits = 0;
      final reasons = <String, int>{};
      final details = <Map<String, Object?>>[];
      for (var unit = 0; unit < retainedUnits; unit += 1) {
        final reason = await _classifyUnit(
          bridge,
          document,
          source,
          cancellation,
          unit,
          coverage,
        );
        if (reason == null) {
          routedUnits += 1;
          reasons['routed'] = (reasons['routed'] ?? 0) + 1;
        } else {
          final kind = reason['reason']! as String;
          reasons[kind] = (reasons[kind] ?? 0) + 1;
          details.add(reason);
        }
      }
      final fallbackCount = reasons.entries
          .where((e) => e.key != 'routed')
          .fold<int>(0, (n, e) => n + e.value);
      final classified = routedUnits + fallbackCount;
      if (classified != retainedUnits) {
        throw StateError(
          'classification accounting broken: $classified classified units '
          'for $retainedUnits retained units ($reasons)',
        );
      }
      return {
        'id': id,
        'outcome': 'classified',
        'retainedUnits': retainedUnits,
        'routedUnits': routedUnits,
        'reasons': reasons,
        'unitDetails': details,
        'tocEntries': _countTocLeaves(book.toc),
        'engineScalars': book.chapters.fold<int>(
          0,
          (n, ch) => n + ch.scalarCount,
        ),
      };
    } finally {
      source.dispose();
    }
  } finally {
    if (document != null) {
      bridge.releaseDocument(handle: document.handle);
    }
    bridge.releaseCancellation(id: cancellation);
  }
}

/// The production routing decision for one unit, mirroring `_epubRelayout`.
///
/// Returns null when the chapter would be served from the Dart engine, or the
/// refusal reason otherwise. The canonical comparison follows
/// `_epubUnitMatchesRetained`: a retained-side failure (stream ceiling) is a
/// decided refusal; the engine's canonical stream is compared byte-exact.
Future<Map<String, Object?>?> _classifyUnit(
  FlutterBridge bridge,
  FlutterDocumentSummary document,
  EpubContentSource source,
  BigInt cancellation,
  int unit,
  EpubFontCoverage? coverage,
) async {
  String retained;
  try {
    retained = await bridge.epubCanonicalText(
      document: document.handle,
      unit: BigInt.from(unit),
      cancellationId: cancellation,
    );
  } on FlutterBridgeError catch (error) {
    // The retained-side stream ceiling is a decided refusal only when the
    // bridge reports a real limit: BufferLimit from
    // `bounded_epub_selection_text`. Cancellations and other backend errors
    // are recorded as their own reasons so a harness or backend failure can
    // never inflate the ceiling count.
    final reason = switch (error.kind) {
      FlutterBridgeErrorKind.limitExceeded => 'retained-ceiling',
      FlutterBridgeErrorKind.cancelled => 'retained-cancelled',
      _ => 'retained-error',
    };
    return {
      'unit': unit,
      'reason': reason,
      'errorKind': error.kind.name,
      'detail': error.message,
    };
  } catch (error) {
    return {
      'unit': unit,
      'reason': 'retained-error',
      'detail': error.toString(),
    };
  }
  if (retained != source.book.chapters[unit].canonicalText) {
    return {
      'unit': unit,
      'reason': 'canonical-mismatch',
      'retainedScalars': retained.runes.length,
      'engineScalars': source.book.chapters[unit].scalarCount,
    };
  }
  if (coverage == null) {
    return {'unit': unit, 'reason': 'font-coverage-unavailable'};
  }
  if (!source.fontCovered(unit, coverage)) {
    final uncovered = _firstUncovered(
      source.book.chapters[unit].canonicalText,
      coverage,
    );
    return {
      'unit': unit,
      'reason': 'font-uncovered',
      'firstUncoveredRune': uncovered,
    };
  }
  if (!source.indivisibleUnitsBounded(unit)) {
    return {'unit': unit, 'reason': 'indivisible-unbounded'};
  }
  return null;
}

int? _firstUncovered(String text, EpubFontCoverage coverage) {
  for (final rune in text.runes) {
    if (rune == 0x0A || rune == 0x0D || rune == 0x09) continue;
    if (!coverage.covers(rune)) return rune;
  }
  return null;
}

int _countTocLeaves(List<EpubTocEntry> entries) {
  var count = 0;
  for (final entry in entries) {
    if (entry.resource.isNotEmpty) count += 1;
    count += _countTocLeaves(entry.children);
  }
  return count;
}

EpubFontCoverage? _coverageCache;
Future<EpubFontCoverage?> _bundledCoverage() async {
  final cached = _coverageCache;
  if (cached != null) return cached;
  final coverage = EpubFontCoverage.fromFonts([
    Uint8List.fromList(
      File('../assets/fonts/InterVariable.ttf').readAsBytesSync(),
    ),
    Uint8List.fromList(
      File('../assets/fonts/NotoSansJP-Variable.ttf').readAsBytesSync(),
    ),
  ]);
  return _coverageCache = coverage;
}
