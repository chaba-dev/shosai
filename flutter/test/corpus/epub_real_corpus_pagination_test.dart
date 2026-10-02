import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

/// Opt-in real-book pagination-invariant sweep.
///
/// For every EPUB listed in the manifest it lays out every chapter with the
/// production Dart flow/pagination (`layoutChapterFlow` + `paginateFlow`, the
/// same path the reader's page-step controller drives) and checks the
/// invariants page stepping relies on: page canonical starts are ordered, and
/// every page resolves its own canonical start via `pageOfCanonical`. It
/// *records* violations per book instead of failing on real books — the
/// known regression (table rows whose cells carry no mapped canonical content
/// anchor mid-chapter pages to scalar 0; see
/// `test/reader/epub_table_page_anchor_repro_test.dart`) is expected to
/// violate them — and writes one JSON line per book to
/// `SHOSAI_EPUB_CORPUS_OUT`.
///
/// Opt-in because it reads real user books:
/// `SHOSAI_EPUB_REAL_CORPUS=<manifest.json>` with anonymous ids; per-unit
/// detail (private-derived scalars) goes to the output file, which must be a
/// private path with real books. Without the variables the file registers a
/// skip and touches nothing.
///
/// A self-authored synthetic control must pass the invariants, so harness
/// drift that would turn violations into passes fails the run.
void main() {
  final manifestPath = Platform.environment['SHOSAI_EPUB_REAL_CORPUS'];
  final outPath = Platform.environment['SHOSAI_EPUB_CORPUS_OUT'];

  test(
    'real-book EPUB pagination-invariant sweep',
    // Opt-in: registered as a skip without a manifest so a default suite run
    // neither touches anything nor reports a false pass.
    skip: manifestPath == null
        ? 'opt-in: set SHOSAI_EPUB_REAL_CORPUS to run against a manifest'
        : null,
    () async {
      final manifest =
          jsonDecode(File(manifestPath!).readAsStringSync())
              as Map<String, Object?>;
      final books = (manifest['books'] as List<Object?>)
          .cast<Map<String, Object?>>();
      _validateManifest(books);
      // Calibrate the classifier before opening the output sink so a
      // calibration failure cannot bypass the try/finally that closes it.
      const typography = ReaderEpubTypography(
        fontFamily: 'Inter',
        fontFamilyFallback: ['Noto Sans JP'],
        fontSize: 18,
        lineHeight: 1.5,
        palette: ReaderEpubPalette(
          background: ui.Color(0xFFFFFFFF),
          foreground: ui.Color(0xFF1A1A1A),
          link: ui.Color(0xFF174EA6),
          tableHeaderBackground: ui.Color(0xFFE8EEF8),
          tableHeaderBorder: ui.Color(0xFF596B89),
        ),
      );

      // Calibration control: the same classifier the sweep records with must
      // report zero violations on a fully canonical-mapped synthetic chapter
      // (self-authored content spanning several pages, including a table).
      expect(
        _chapterInvariants(_syntheticControlChapter(), typography),
        (zeroStartRegressions: 0, misresolvedPages: 0),
        reason:
            'pagination-invariant drift: the control chapter must violate '
            'nothing',
      );

      final out = outPath == null ? null : File(outPath);
      IOSink? sink;
      if (out != null) {
        sink = out.openWrite(mode: FileMode.write);
      }

      var booksWithViolations = 0;
      var chaptersChecked = 0;
      var chaptersWithViolations = 0;
      var infraErrors = 0;
      try {
        for (final entry in books) {
          final id = entry['id']! as String;
          final path = entry['path']! as String;
          final record = <String, Object?>{'id': id};
          try {
            final book = openEpubBytes(await File(path).readAsBytes());
            final offenders = <int>[];
            var zeroStartRegressions = 0;
            var misresolved = 0;
            for (final chapter in book.chapters) {
              chaptersChecked += 1;
              final result = _chapterInvariants(chapter, typography);
              if (result.zeroStartRegressions == 0 &&
                  result.misresolvedPages == 0) {
                continue;
              }
              chaptersWithViolations += 1;
              offenders.add(chapter.spine);
              zeroStartRegressions += result.zeroStartRegressions;
              misresolved += result.misresolvedPages;
            }
            record['chapters'] = book.chapters.length;
            record['chaptersWithViolations'] = offenders.length;
            record['offenderUnits'] = offenders;
            record['zeroStartRegressions'] = zeroStartRegressions;
            record['misresolvedPages'] = misresolved;
            if (offenders.isNotEmpty) booksWithViolations += 1;
          } catch (error) {
            // Infrastructure failures (a missing input file, a parse defect,
            // a limit refusal) are not reader outcomes: record them and fail
            // the run after every book has been attempted.
            record['error'] = '${error.runtimeType}: $error';
            infraErrors += 1;
          }
          final line = jsonEncode(record);
          if (sink != null) {
            sink.writeln(line);
            await sink.flush();
          } else {
            // ignore: avoid_print
            print(line);
          }
        }
      } finally {
        await sink?.close();
      }
      // The sweep records invariant violations, it does not assert on real
      // books; infrastructure errors are failures.
      // ignore: avoid_print
      print(
        'pagination sweep: books=${books.length} '
        'booksWithViolations=$booksWithViolations '
        'chaptersChecked=$chaptersChecked '
        'chaptersWithViolations=$chaptersWithViolations',
      );
      expect(
        infraErrors,
        0,
        reason:
            'infrastructure errors (missing/unreadable input, parse '
            'refusal) are harness failures, not reader outcomes',
      );
    },
    timeout: const Timeout(Duration(hours: 8)),
  );
}

/// Manifest validation, mirroring the routing sweep's policy: a nonempty
/// list of books with unique anonymous ids and existing input paths.
void _validateManifest(List<Map<String, Object?>> books) {
  if (books.isEmpty) {
    fail('manifest lists no books');
  }
  final seen = <String>{};
  for (final entry in books) {
    final id = entry['id']! as String;
    if (!seen.add(id)) {
      fail('duplicate manifest id: $id');
    }
    final path = entry['path']! as String;
    if (!File(path).existsSync()) {
      fail('manifest book file does not exist: $path');
    }
  }
}

({int zeroStartRegressions, int misresolvedPages}) _chapterInvariants(
  EpubChapter chapter,
  ReaderEpubTypography typography,
) {
  var zeroStartRegressions = 0;
  var misresolved = 0;
  final flow = layoutChapterFlow(
    chapter: chapter,
    spec: ChapterLayoutSpec(width: 895, height: 640, typography: typography),
    images: const {},
  );
  final paginated = paginateFlow(flow: flow, pageHeight: 640, pageWidth: 895);
  final pages = paginated.pages;
  for (var index = 0; index < pages.length; index += 1) {
    final page = pages[index];
    // Counted as a *regression transition*: a page whose start moves
    // downward into scalar 0 relative to the previous page. Consecutive
    // zero-start pages after the first are not counted again — this is a
    // lower bound on zero-anchored pages, not a census.
    if (index > 0 && page.canonicalStart < pages[index - 1].canonicalStart) {
      if (page.canonicalStart == 0) zeroStartRegressions += 1;
    }
    if (paginated.pageOfCanonical(page.canonicalStart) != page.index) {
      misresolved += 1;
    }
  }
  return (
    zeroStartRegressions: zeroStartRegressions,
    misresolvedPages: misresolved,
  );
}

/// A self-authored control chapter: paragraphs plus a table whose rows all
/// carry canonical-mapped text, spanning several pages. Canonical mapping is
/// produced by the engine's own `CanonicalTextBuilder`.
EpubChapter _syntheticControlChapter() {
  final blocks = <EpubContentNode>[
    for (var index = 0; index < 40; index += 1)
      EpubParagraph([
        EpubTextSpan(text: 'Leading paragraph ${index * 7} of the control.'),
      ], const EpubNodeStyle()),
    EpubTable(
      caption: [],
      rowGroups: [
        EpubTableRowGroup(
          kind: EpubTableRowGroupKind.body,
          rows: [
            EpubTableRow(
              cells: [
                EpubTableCell(
                  children: [
                    EpubParagraph([
                      EpubTextSpan(text: 'Control cell one.'),
                    ], const EpubNodeStyle()),
                  ],
                ),
                EpubTableCell(
                  children: [
                    EpubParagraph([
                      EpubTextSpan(text: 'Control cell two.'),
                    ], const EpubNodeStyle()),
                  ],
                ),
              ],
            ),
            EpubTableRow(
              cells: [
                EpubTableCell(
                  children: [
                    EpubParagraph([
                      EpubTextSpan(text: 'Control cell three.'),
                    ], const EpubNodeStyle()),
                  ],
                ),
                EpubTableCell(
                  children: [
                    EpubParagraph([
                      EpubTextSpan(text: 'Control cell four.'),
                    ], const EpubNodeStyle()),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    for (var index = 0; index < 40; index += 1)
      EpubParagraph([
        EpubTextSpan(text: 'Trailing paragraph ${index * 11} of the control.'),
      ], const EpubNodeStyle()),
  ];
  final built = CanonicalTextBuilder(maxScalars: 100000).build(blocks);
  return EpubChapter(
    spine: 0,
    resource: 'chapter.xhtml',
    title: 'Pagination control',
    blocks: blocks,
    canonicalText: built.text,
    anchors: const {},
    scalarCount: built.scalarCount,
  );
}
