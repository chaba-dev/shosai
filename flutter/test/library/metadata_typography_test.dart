import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// The interface face a metadata string selects.
///
/// `crates/shosai-app/src/typography.rs` selects the same bundled faces for the
/// same strings, so these cases are the Flutter half of that policy: user
/// metadata must be rendered with the bundled face that covers its script
/// instead of through the fallback chain.
final _japaneseBook = FlutterLibraryBook(
  bookId: 2,
  title: '海辺の図書館 — 失われた書架をめぐる長い旅路',
  author: '紫式部',
  format: FlutterBookFormat.epub,
  pathKey: '/books/umibe.epub',
  managed: true,
  progress: 0.07,
  dateAdded: '2026-09-11',
);

final _latinBook = FlutterLibraryBook(
  bookId: 7,
  title: 'A Book',
  author: 'Ada',
  format: FlutterBookFormat.pdf,
  pathKey: '/books/a.pdf',
  managed: false,
  progress: 0.42,
  dateAdded: '2026-09-10',
);

Widget _app(Widget child) => productionShell(home: Scaffold(body: child));

LibraryCollection _collection(LibraryModel model) => LibraryCollection(
  model: model,
  openBook: (_) {},
  removeBook: (_) {},
  loadMore: () {},
  loadCover: (_) => false,
);

RenderParagraph _paragraph(WidgetTester tester, String text, {double? size}) =>
    tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == text &&
            (size == null || widget.style?.fontSize == size),
        description: 'card text "$text"${size == null ? '' : ' at $size px'}',
      ),
    );

void main() {
  setUpAll(loadHarnessFonts);

  group('interface font selection', () {
    test('keeps the Latin face for text without Japanese', () {
      expect(shosaiInterfaceFontForText('Settings'), shosaiInterfaceFontFamily);
      expect(
        shosaiInterfaceFontForText('EPUB 16 px'),
        shosaiInterfaceFontFamily,
      );
      expect(shosaiInterfaceFontForText(''), shosaiInterfaceFontFamily);
    });

    test('selects the Japanese face for Japanese text', () {
      expect(
        shosaiInterfaceFontForText('設定'),
        shosaiJapaneseInterfaceFontFamily,
      );
      expect(
        shosaiInterfaceFontForText('Shosai フォルダー'),
        shosaiJapaneseInterfaceFontFamily,
      );
      // Halfwidth katakana, compatibility ideographs and extension B are in the
      // same ranges the Rust rule covers.
      expect(
        shosaiInterfaceFontForText('ﾎﾝ'),
        shosaiJapaneseInterfaceFontFamily,
      );
      expect(
        shosaiInterfaceFontForText('神'),
        shosaiJapaneseInterfaceFontFamily,
      );
      expect(
        shosaiInterfaceFontForText('𠮟'),
        shosaiJapaneseInterfaceFontFamily,
      );
    });

    test('a style keeps its own family for non-Japanese text', () {
      const style = TextStyle(fontFamily: 'Inter', fontSize: 16);
      expect(
        shosaiInterfaceStyleForText(style, 'Settings').fontFamily,
        'Inter',
      );
      final japanese = shosaiInterfaceStyleForText(style, '設定');
      expect(japanese.fontFamily, shosaiJapaneseInterfaceFontFamily);
      expect(japanese.fontFamilyFallback, [shosaiInterfaceFontFamily]);
      expect(japanese.fontSize, 16);
    });

    test('Japanese text keeps the Latin face as its bundled fallback', () {
      // Noto Sans JP does not cover Cyrillic, so the Latin face has to stay in
      // the chain for mixed user metadata.
      final mixed = shosaiInterfaceStyleForText(
        const TextStyle(fontFamily: 'Inter'),
        '日本語 — Україна',
      );
      expect(mixed.fontFamily, shosaiJapaneseInterfaceFontFamily);
      expect(mixed.fontFamilyFallback, [shosaiInterfaceFontFamily]);
    });
  });

  group('card metadata typography', () {
    testWidgets('Japanese titles and authors use the bundled Japanese face', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(_collection(LibraryModel(books: [_japaneseBook], loaded: true))),
      );

      final title = _paragraph(
        tester,
        _japaneseBook.title,
        size: ShosaiTokens.typeSize13,
      );
      expect(title.text.style?.fontFamily, shosaiJapaneseInterfaceFontFamily);
      expect(title.text.style?.fontFamilyFallback, [shosaiInterfaceFontFamily]);
      final author = _paragraph(
        tester,
        _japaneseBook.author!,
        size: ShosaiTokens.typeSize11,
      );
      expect(author.text.style?.fontFamily, shosaiJapaneseInterfaceFontFamily);
      expect(author.text.style?.fontFamilyFallback, [
        shosaiInterfaceFontFamily,
      ]);
    });

    testWidgets('Latin titles and authors keep the Latin face', (tester) async {
      await tester.pumpWidget(
        _app(_collection(LibraryModel(books: [_latinBook], loaded: true))),
      );

      final title = _paragraph(
        tester,
        _latinBook.title,
        size: ShosaiTokens.typeSize13,
      );
      expect(title.text.style?.fontFamily, shosaiInterfaceFontFamily);
      expect(
        title.text.style?.fontFamilyFallback,
        contains(shosaiJapaneseInterfaceFontFamily),
      );
      final author = _paragraph(
        tester,
        _latinBook.author!,
        size: ShosaiTokens.typeSize11,
      );
      expect(author.text.style?.fontFamily, shosaiInterfaceFontFamily);
    });
  });
}
