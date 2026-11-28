/// ComicInfo.xml, the de facto metadata file of comic archives.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// The `Manga` field: whether the book is a manga, and whether it reads
/// right to left.
enum CbzManga {
  unknown,
  no,
  yes,
  yesAndRightToLeft;

  /// Whether the book carries the manga mark, which opens it right to left.
  /// `Yes` and `YesAndRightToLeft` both carry it: tools that write `Yes`
  /// predate the second value and mean a right-to-left manga by it.
  bool get rightToLeft => this == yes || this == yesAndRightToLeft;
}

/// The fields of a ComicInfo.xml the library and reader use.
final class CbzComicInfo {
  const CbzComicInfo({
    this.title,
    this.series,
    this.number,
    this.volume,
    this.writers = const [],
    this.language,
    this.manga = CbzManga.unknown,
  });

  final String? title;
  final String? series;
  final String? number;
  final String? volume;
  final List<String> writers;

  /// The `LanguageISO` field, such as `ja`.
  final String? language;
  final CbzManga manga;

  /// The book's display title: its own title, else its series and number.
  String? get displayTitle {
    if (title case final title?) return title;
    final series = this.series;
    if (series == null) return null;
    final number = this.number;
    return number == null ? series : '$series $number';
  }
}

/// Parse a ComicInfo.xml. An unreadable file yields empty metadata: a comic
/// with broken metadata is still a readable comic.
CbzComicInfo parseComicInfo(Uint8List bytes) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  } on XmlException {
    return const CbzComicInfo();
  }
  final root = document.rootElement;
  String? field(String name) {
    for (final element in root.childElements) {
      if (element.name.local.toLowerCase() == name.toLowerCase()) {
        final value = element.innerText.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  final manga = switch (field('Manga')?.toLowerCase()) {
    'yes' => CbzManga.yes,
    'yesandrighttoleft' => CbzManga.yesAndRightToLeft,
    'no' => CbzManga.no,
    _ => CbzManga.unknown,
  };
  return CbzComicInfo(
    title: field('Title'),
    series: field('Series'),
    number: field('Number'),
    volume: field('Volume'),
    writers: [
      for (final writer in (field('Writer') ?? '').split(','))
        if (writer.trim().isNotEmpty) writer.trim(),
    ],
    language: field('LanguageISO'),
    manga: manga,
  );
}
