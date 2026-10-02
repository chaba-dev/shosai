import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

import '../support/epub_navigation_fixture.dart';

/// The CRLF-in-code-block canonical divergence, pinned with a minimal
/// self-authored fixture (no real-book content).
///
/// Real EPUBs commonly carry CRLF line endings inside `<pre>`/`<code>`
/// blocks. Observed against real books (private corpus pass): the Dart
/// engine's canonical stream keeps the U+000D U+000A pair inside the
/// preformatted block, while the retained Rust parser's `epub_canonical_text`
/// stream emits U+000A — so the chapter fails the production routing gate's
/// canonical-parity comparison (`_epubUnitMatchesRetained`) and every such
/// chapter stays on the retained renderer. On one measured technical book,
/// 15 of 29 chapters were refused for exactly this reason.
///
/// This test pins the divergence as it is today. When the engine's
/// normalization is aligned, this test must be updated to assert stream
/// parity instead — a failure here means the divergence closed, not that the
/// fixture broke.
///
/// Run (host bridge built): `cd flutter && flutter test test/corpus/`.
const _bridgeDebugLibrary = '../target/debug/libshosai_flutter_bridge.so';

void main() {
  final supported = Platform.isLinux || Platform.isMacOS;

  test(
    'CRLF inside pre/code diverges between the engine and retained canonical '
    'streams',
    () async {
      if (!supported) return;
      final directory = await Directory.systemTemp.createTemp(
        'shosai-epub-crlf-',
      );
      try {
        final library = Platform.isMacOS
            ? '../target/debug/libshosai_flutter_bridge.dylib'
            : _bridgeDebugLibrary;
        await RustLib.init(externalLibrary: ExternalLibrary.open(library));
        final bridge = FlutterBridge.withDatabasePath(
          databasePath: '${directory.path}/crlf.sqlite3',
        );
        try {
          final file = File('${directory.path}/crlf.epub');
          await file.writeAsBytes(crlfPreEpub(), flush: true);
          final cancellation = bridge.createCancellation();
          FlutterDocumentSummary? document;
          try {
            document = await bridge.openDocument(
              request: FlutterOpenRequest(
                localId: file.path,
                pathKey: file.path,
              ),
              cancellationId: cancellation,
            );
            expect(document.format, FlutterBookFormat.epub);
            final bytes = await bridge.epubSourceBytes(
              document: document.handle,
              cancellationId: cancellation,
            );
            final book = openEpubBytes(bytes);
            final engine = book.chapters.single.canonicalText;
            final retained = await bridge.epubCanonicalText(
              document: document.handle,
              unit: BigInt.zero,
              cancellationId: cancellation,
            );

            // The engine keeps the carriage returns inside the code block.
            expect(
              engine.contains('\r\n'),
              isTrue,
              reason:
                  'the engine canonical stream keeps CRLF inside <pre> code',
            );
            // The retained parser normalizes them away.
            expect(
              retained.contains('\r'),
              isFalse,
              reason:
                  'the retained epub_canonical_text stream normalizes CRLF to '
                  'U+000A',
            );
            // The streams therefore differ in length and content — the exact
            // comparison the routing gate runs, so the chapter is refused.
            expect(engine, isNot(retained));
            expect(engine.runes.length, greaterThan(retained.runes.length));
            // CRLF must be the ONLY divergence: normalizing the engine stream
            // yields the retained stream exactly. (Without this, a retained
            // parser that dropped unrelated content would still pass the checks
            // above.) The retained stream must also actually carry the block
            // content.
            expect(
              engine.replaceAll('\r\n', '\n'),
              retained,
              reason: 'CRLF normalization is the whole divergence',
            );
            expect(
              retained.contains('second command') &&
                  retained.contains('third command'),
              isTrue,
              reason: 'the retained stream carries the code-block content',
            );
            final crCount = '\r'.allMatches(engine).length;
            expect(
              crCount,
              2,
              reason: 'one per interior code-block line break',
            );
          } finally {
            if (document != null) {
              bridge.releaseDocument(handle: document.handle);
            }
            bridge.releaseCancellation(id: cancellation);
          }
        } finally {
          // Dispose the bridge before the temporary directory (and its
          // SQLite file) is deleted.
          bridge.dispose();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
