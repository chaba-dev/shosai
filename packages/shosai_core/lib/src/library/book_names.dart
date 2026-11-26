/// Portable names for new books; never rename the reader's existing files.
library;

import 'dart:convert';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../annotations/graphemes.dart';
import '../search/case_fold.dart';

String bookNameKey(String name) => unorm.nfd(caseFold(unorm.nfd(name)));

String bookFileName(
  String title,
  String? author,
  String extension, {
  int number = 1,
}) {
  final writer = _cut(_clean(author ?? ''), 100);
  final tail = '${writer.isEmpty ? '' : ' - $writer'}.$extension';
  final heading = _cut(_clean(title), 239 - utf8.encode(tail).length);
  var name = '${heading.isEmpty ? 'Untitled' : heading}$tail';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]) *($|\.)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return number == 1
      ? name
      : '${name.substring(0, name.length - extension.length - 1)} ($number).$extension';
}

String _clean(String text) => unorm.nfc(
  text
      .replaceAll(RegExp(r'[\/\\:*?"<>|\x00-\x1f\x7f-\x9f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[ .]+|[ .]+$'), ''),
);

String _cut(String value, int budget) {
  final breaker = GraphemeBreaker();
  final result = StringBuffer();
  final cluster = StringBuffer();
  var bytes = 0;
  bool flush() {
    final text = cluster.toString();
    final length = utf8.encode(text).length;
    if (bytes + length > budget) return false;
    result.write(text);
    bytes += length;
    cluster.clear();
    return true;
  }

  for (final scalar in value.runes) {
    if (breaker.next(scalar) && !flush()) break;
    cluster.writeCharCode(scalar);
  }
  flush();
  return result.toString().replaceAll(RegExp(r'[ .]+$'), '');
}
