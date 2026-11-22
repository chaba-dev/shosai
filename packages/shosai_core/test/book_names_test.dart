import 'dart:convert';
import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'portable native-script names retain graphemes within the byte budget',
    () {
      expect(bookFileName(' 吾輩は猫である ', '夏目漱石', 'epub'), '吾輩は猫である - 夏目漱石.epub');
      expect(bookFileName('CON', null, 'pdf'), '_CON.pdf');
      expect(
        bookFileName(' a/b:c? . ', 'd*e', 'epub', number: 2),
        'a b c - d e (2).epub',
      );
      final name = bookFileName(
        '👨‍👩‍👧‍👦' * 100,
        'é' * 100,
        'epub',
        number: 123456,
      );
      expect(utf8.encode(name).length, lessThanOrEqualTo(255));
      expect(name.split(' - ').first, '👨‍👩‍👧‍👦' * 5);
      expect(bookNameKey('STRASSE.EPUB'), bookNameKey('Straße.epub'));
      expect(bookNameKey('École.epub'), bookNameKey('E\u0301COLE.epub'));
    },
  );
}
