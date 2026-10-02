/// EPUB container parsing: ZIP admission, OPF/spine/TOC, resources and
/// per-chapter normalization.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:xml/xml.dart';

import 'canonical.dart';
import 'css.dart';
import 'limits.dart';
import 'model.dart';
import 'normalize.dart';
import 'paths.dart';

/// Open an EPUB from bytes.
EpubBook openEpubBytes(
  Uint8List bytes, {
  EpubLimits limits = const EpubLimits(),
}) {
  final warnings = <String>[];
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw EpubFormatError('failed to read EPUB archive: $error');
  }
  if (archive.files.length > limits.maxArchiveEntries) {
    throw EpubLimitError(
      'archive entries',
      limits.maxArchiveEntries,
      archive.files.length,
    );
  }
  final entries = <String, ArchiveFile>{};
  _detectDuplicateEntries(bytes, limits, warnings);
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    if (entries.containsKey(name)) {
      throw EpubFormatError('duplicate EPUB archive entry: $name');
    }
    if (file.size > limits.maxEntryBytes) {
      throw EpubLimitError(
        'archive entry bytes',
        limits.maxEntryBytes,
        file.size,
      );
    }
    entries[name] = file;
  }
  final totalUncompressed = entries.values.fold<int>(
    0,
    (sum, file) => sum + file.size,
  );
  if (totalUncompressed > limits.maxTotalUncompressedBytes) {
    throw EpubLimitError(
      'archive uncompressed bytes',
      limits.maxTotalUncompressedBytes,
      totalUncompressed,
    );
  }
  if (bytes.isNotEmpty &&
      totalUncompressed > bytes.length * limits.maxCompressionRatio) {
    throw EpubLimitError(
      'archive compression ratio',
      limits.maxCompressionRatio,
      totalUncompressed ~/ bytes.length,
    );
  }

  final mimetype = entries['mimetype'];
  if (mimetype == null) {
    warnings.add('EPUB archive has no mimetype entry');
  } else if (utf8.decode(mimetype.content, allowMalformed: true).trim() !=
      'application/epub+zip') {
    warnings.add('EPUB mimetype entry is not application/epub+zip');
  }

  final containerFile = entries['META-INF/container.xml'];
  if (containerFile == null) {
    throw const EpubFormatError('EPUB archive has no META-INF/container.xml');
  }
  final container = _parseXml(containerFile.content, 'META-INF/container.xml');
  final rootfile = container.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'rootfile')
      .firstOrNull;
  final opfPath = rootfile?.getAttribute('full-path');
  if (opfPath == null) {
    throw const EpubFormatError('EPUB container has no rootfile');
  }
  final canonicalOpfPath = canonicalEpubPath(opfPath);
  final opfFile = entries[canonicalOpfPath];
  if (opfFile == null) {
    throw EpubFormatError(
      'EPUB package document is missing: $canonicalOpfPath',
    );
  }
  final opf = _parseXml(opfFile.content, canonicalOpfPath);
  final opfDirectory = directoryOf(canonicalOpfPath);

  final metadata = opf.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'metadata')
      .firstOrNull;
  String? metadataValue(String localName) => metadata?.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == localName)
      .map((element) => element.innerText.trim())
      .firstOrNull;

  final manifestItems = <String, _ManifestItem>{};
  final manifest = opf.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'manifest')
      .firstOrNull;
  if (manifest != null) {
    for (final item in manifest.children.whereType<XmlElement>()) {
      if (item.name.local != 'item') continue;
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifestItems[id] = _ManifestItem(
        id: id,
        href: href,
        mediaType: item.getAttribute('media-type') ?? '',
      );
    }
  }
  final spineElement = opf.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'spine')
      .firstOrNull;
  final spineItems = <String>[];
  if (spineElement != null) {
    for (final itemref in spineElement.children.whereType<XmlElement>()) {
      if (itemref.name.local != 'itemref') continue;
      final idref = itemref.getAttribute('idref');
      if (idref == null) continue;
      spineItems.add(idref);
    }
  }
  if (spineItems.isEmpty) {
    throw const EpubFormatError('EPUB package has an empty spine');
  }

  // Admit every manifest resource except content documents (which are parsed
  // separately) and the package document itself.
  final resources = <String, EpubResource>{};
  final stylesheets = <(String, CssStylesheet)>[];
  for (final item in manifestItems.values) {
    final resolved = _tryResolve(opfDirectory, item.href);
    if (resolved == null) {
      warnings.add('manifest item has an unusable href: ${item.href}');
      continue;
    }
    if (resolved == canonicalOpfPath) continue;
    final isContentDocument =
        item.mediaType == 'application/xhtml+xml' ||
        resolved.toLowerCase().endsWith('.xhtml') ||
        resolved.toLowerCase().endsWith('.html');
    final file = entries[resolved];
    if (file == null) {
      warnings.add('manifest item is missing from the archive: $resolved');
      continue;
    }
    if (item.mediaType == 'text/css') {
      if (file.size > limits.maxStyleSheetBytes) {
        throw EpubLimitError(
          'stylesheet bytes',
          limits.maxStyleSheetBytes,
          file.size,
        );
      }
      final source = utf8.decode(file.content, allowMalformed: true);
      stylesheets.add((resolved, CssStylesheet.parse(source, limits)));
      continue;
    }
    if (isContentDocument) continue;
    if (resources.length >= limits.maxResources) {
      throw EpubLimitError('admitted resources', limits.maxResources);
    }
    resources[resolved] = EpubResource(
      path: resolved,
      mediaType: item.mediaType,
      bytes: file.content,
    );
  }

  final allWarnings = [
    ...warnings,
    for (final (_, sheet) in stylesheets) ...sheet.warnings,
  ];

  final embeddedFonts = _resolveEmbeddedFonts(
    stylesheets,
    resources,
    allWarnings,
  );

  final toc = _parseToc(
    manifestItems: manifestItems,
    entries: entries,
    opfDirectory: opfDirectory,
    warnings: allWarnings,
  );
  final tocTitles = <String, String>{};
  void collectTitles(List<EpubTocEntry> entries) {
    for (final entry in entries) {
      // A title-only entry (a part heading with no target) contributes no
      // chapter title; an empty resource is not a chapter path.
      if (entry.resource.isNotEmpty) {
        tocTitles.putIfAbsent(entry.resource, () => entry.title);
      }
      collectTitles(entry.children);
    }
  }

  collectTitles(toc);

  final chapters = <EpubChapter>[];
  for (var spineIndex = 0; spineIndex < spineItems.length; spineIndex++) {
    final idref = spineItems[spineIndex];
    final item = manifestItems[idref];
    if (item == null) {
      throw EpubFormatError(
        'EPUB spine references unknown manifest id: $idref',
      );
    }
    final resolved = _tryResolve(opfDirectory, item.href);
    if (resolved == null) {
      throw EpubFormatError(
        'EPUB spine item has an unusable href: ${item.href}',
      );
    }
    final file = entries[resolved];
    if (file == null) {
      throw EpubFormatError('failed to read chapter: $resolved');
    }
    if (file.size > limits.maxChapterBytes) {
      throw EpubLimitError('chapter bytes', limits.maxChapterBytes, file.size);
    }
    final xhtml = utf8.decode(file.content, allowMalformed: true);
    final normalized = normalizeChapter(
      xhtml: xhtml,
      chapterPath: resolved,
      stylesheets: [for (final (_, sheet) in stylesheets) sheet],
      limits: limits,
    );
    allWarnings.addAll(normalized.warnings);
    final canonicalText = extractCanonicalText(normalized.nodes);
    final index = CanonicalIndex(canonicalText);
    _populateImageMetadata(normalized.nodes, resources, limits);
    chapters.add(
      EpubChapter(
        spine: spineIndex,
        resource: resolved,
        title: tocTitles[resolved] ?? '',
        blocks: normalized.nodes,
        canonicalText: canonicalText,
        anchors: normalized.anchors,
        scalarCount: index.scalarCount,
      ),
    );
  }

  return EpubBook(
    title: metadataValue('title') ?? '',
    author: metadataValue('creator'),
    language: metadataValue('language'),
    spine: [for (final chapter in chapters) chapter.resource],
    toc: toc,
    resources: resources,
    chapters: chapters,
    embeddedFonts: embeddedFonts,
    warnings: allWarnings,
  );
}

/// Bounded ZIP central-directory scan that rejects duplicate entry names.
///
/// The `archive` package de-duplicates entries while decoding, so the
/// admission rule must be enforced from the raw bytes, as the production Rust
/// reader does. ZIP64 end-of-central-directory records are supported; an
/// unreadable directory is reported as a warning rather than guessed at.
void _detectDuplicateEntries(
  Uint8List bytes,
  EpubLimits limits,
  List<String> warnings,
) {
  final eocd = _findEndOfCentralDirectory(bytes);
  if (eocd < 0) {
    warnings.add('ZIP end-of-central-directory record not found');
    return;
  }
  int u16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
  int u32(int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
  var entryCount = u16(eocd + 10);
  var directoryOffset = u32(eocd + 16);
  if (entryCount == 0xFFFF || directoryOffset == 0xFFFFFFFF) {
    final locator = _findZip64Locator(bytes, eocd);
    if (locator < 0) {
      warnings.add('ZIP64 directory without a locator; duplicate scan skipped');
      return;
    }
    final zip64 = _u64(bytes, locator + 8);
    if (zip64 == null || zip64 + 56 > bytes.length) {
      warnings.add('ZIP64 end-of-central-directory is out of range');
      return;
    }
    entryCount = _u64(bytes, zip64 + 32) ?? entryCount;
    directoryOffset = _u64(bytes, zip64 + 48) ?? directoryOffset;
  }
  if (entryCount > limits.maxArchiveEntries) {
    throw EpubLimitError(
      'archive entries',
      limits.maxArchiveEntries,
      entryCount,
    );
  }
  final names = <String>{};
  var offset = directoryOffset;
  for (var index = 0; index < entryCount; index++) {
    if (offset + 46 > bytes.length ||
        bytes[offset] != 0x50 ||
        bytes[offset + 1] != 0x4B ||
        bytes[offset + 2] != 0x01 ||
        bytes[offset + 3] != 0x02) {
      warnings.add('ZIP central directory ended early; duplicate scan partial');
      return;
    }
    final nameLength = u16(offset + 28);
    final extraLength = u16(offset + 30);
    final commentLength = u16(offset + 32);
    final nameStart = offset + 46;
    if (nameStart + nameLength > bytes.length) {
      warnings.add('ZIP central directory name is out of range');
      return;
    }
    final name = utf8.decode(
      bytes.sublist(nameStart, nameStart + nameLength),
      allowMalformed: true,
    );
    if (!names.add(name)) {
      throw EpubFormatError('duplicate EPUB archive entry: $name');
    }
    offset = nameStart + nameLength + extraLength + commentLength;
  }
}

int _findEndOfCentralDirectory(Uint8List bytes) {
  if (bytes.length < 22) return -1;
  final start = bytes.length - 22 - 0xFFFF;
  for (
    var offset = bytes.length - 22;
    offset >= (start < 0 ? 0 : start);
    offset--
  ) {
    if (bytes[offset] == 0x50 &&
        bytes[offset + 1] == 0x4B &&
        bytes[offset + 2] == 0x05 &&
        bytes[offset + 3] == 0x06) {
      return offset;
    }
  }
  return -1;
}

int _findZip64Locator(Uint8List bytes, int eocd) {
  final offset = eocd - 20;
  if (offset < 0) return -1;
  if (bytes[offset] == 0x50 &&
      bytes[offset + 1] == 0x4B &&
      bytes[offset + 2] == 0x06 &&
      bytes[offset + 3] == 0x07) {
    return offset;
  }
  return -1;
}

int? _u64(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) return null;
  var value = 0;
  for (var index = 7; index >= 0; index--) {
    value = value * 256 + bytes[offset + index];
  }
  return value;
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
  });

  final String id;
  final String href;
  final String mediaType;
}

String? _tryResolve(String baseDirectory, String reference) {
  try {
    return resolveEpubReference(baseDirectory, reference).path;
  } on EpubPathError {
    return null;
  }
}

XmlDocument _parseXml(List<int> bytes, String path) {
  final source = utf8.decode(bytes, allowMalformed: true);
  try {
    return XmlDocument.parse(source);
  } on XmlException catch (error) {
    throw EpubFormatError(
      'failed to parse EPUB XML at $path: ${error.message}',
    );
  }
}

Map<String, String> _resolveEmbeddedFonts(
  List<(String, CssStylesheet)> stylesheets,
  Map<String, EpubResource> resources,
  List<String> warnings,
) {
  final fonts = <String, String>{};
  for (final (path, sheet) in stylesheets) {
    final directory = directoryOf(path);
    for (final face in sheet.fontFaces) {
      for (final source in face.sources) {
        final resolved = _tryResolve(directory, source);
        if (resolved == null) continue;
        final resource = resources[resolved];
        if (resource == null) {
          warnings.add('embedded font is missing: $resolved');
          continue;
        }
        final lower = resolved.toLowerCase();
        if (lower.endsWith('.woff') || lower.endsWith('.woff2')) {
          warnings.add(
            'embedded font format is not loadable by Flutter: $resolved '
            '(WOFF/WOFF2 are not supported; TTF/OTF are)',
          );
          continue;
        }
        fonts.putIfAbsent(face.family, () => resolved);
        break;
      }
    }
  }
  return fonts;
}

void _populateImageMetadata(
  List<EpubContentNode> nodes,
  Map<String, EpubResource> resources,
  EpubLimits limits,
) {
  void visit(EpubContentNode node) {
    switch (node) {
      case EpubImage image:
        final resource = resources[image.src];
        if (resource == null) return;
        final size = _imageIntrinsicSize(resource, limits);
        if (size != null) {
          image.intrinsicSize = size;
        }
      case EpubBlockQuote(:final children):
      case EpubFigure(:final children):
        for (final child in children) {
          visit(child);
        }
      case EpubTable(:final rowGroups):
        for (final group in rowGroups) {
          for (final row in group.rows) {
            for (final cell in row.cells) {
              for (final child in cell.children) {
                visit(child);
              }
            }
          }
        }
      case EpubHeading() ||
          EpubParagraph() ||
          EpubMathNode() ||
          EpubUnorderedList() ||
          EpubOrderedList() ||
          EpubCodeBlock() ||
          EpubHorizontalRule():
        break;
    }
  }

  for (final node in nodes) {
    visit(node);
  }
}

EpubImageSize? _imageIntrinsicSize(EpubResource resource, EpubLimits limits) {
  final bytes = Uint8List.fromList(resource.bytes);
  if (bytes.length > limits.maxImageBytes) return null;
  try {
    final decoder = image.findDecoderForData(bytes);
    if (decoder != null) {
      final info = decoder.startDecode(bytes);
      if (info != null) {
        final width = info.width;
        final height = info.height;
        if (width <= 0 || height <= 0) return null;
        if (width * height > limits.maxImagePixels) {
          throw EpubLimitError(
            'image pixels',
            limits.maxImagePixels,
            width * height,
          );
        }
        return EpubImageSize(width, height);
      }
    }
  } catch (error) {
    if (error is EpubLimitError) rethrow;
    return null;
  }
  // SVG: read width/height or viewBox from the root element.
  final text = utf8.decode(bytes, allowMalformed: true);
  if (!text.contains('<svg')) return null;
  try {
    final document = XmlDocument.parse(text);
    final root = document.rootElement;
    double? dimension(String name) {
      final raw = root.getAttribute(name);
      if (raw == null) return null;
      return _svgLength(raw);
    }

    var width = dimension('width');
    var height = dimension('height');
    final viewBox = root.getAttribute('viewBox');
    List<double>? box;
    if (viewBox != null) {
      final parts = viewBox
          .split(RegExp(r'[\s,]+'))
          .where((value) => value.isNotEmpty)
          .map(double.tryParse)
          .toList();
      if (parts.length == 4 && parts.every((value) => value != null)) {
        box = [for (final value in parts) value!];
      }
    }
    if (width != null && height == null && box != null) {
      height = box[3] * width / box[2];
    } else if (height != null && width == null && box != null) {
      width = box[2] * height / box[3];
    } else if (width == null && height == null && box != null) {
      width = box[2];
      height = box[3];
    }
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    if (width * height > limits.maxImagePixels) {
      throw EpubLimitError(
        'image pixels',
        limits.maxImagePixels,
        (width * height).round(),
      );
    }
    return EpubImageSize(width.round(), height.round());
  } on XmlException {
    return null;
  }
}

double? _svgLength(String raw) {
  final value = raw.trim().toLowerCase();
  final match = RegExp(r'^([0-9.]+)(px|pt|in|cm|mm|pc)?$').firstMatch(value);
  if (match == null) return null;
  final number = double.tryParse(match.group(1)!);
  if (number == null) return null;
  return switch (match.group(2)) {
    null || 'px' => number,
    'pt' => number * 96.0 / 72.0,
    'in' => number * 96.0,
    'cm' => number * 96.0 / 2.54,
    'mm' => number * 96.0 / 25.4,
    'pc' => number * 16.0,
    _ => null,
  };
}

List<EpubTocEntry> _parseToc({
  required Map<String, _ManifestItem> manifestItems,
  required Map<String, ArchiveFile> entries,
  required String opfDirectory,
  required List<String> warnings,
}) {
  // The production parser tries an NCX first (EPUB 2): the manifest item whose
  // media type is the NCX type — there is no `.ncx` suffix rule — and only
  // then an EPUB 3 nav document. A book whose two navigation documents
  // disagree therefore shows the NCX's table of contents, like the retained
  // reader. The production manifest is a HashMap, so its candidate is an
  // arbitrary one; this port takes the first in manifest order, a documented
  // deterministic superset of that behaviour.
  final ncxItem = manifestItems.values
      .where((item) => item.mediaType == 'application/x-dtbncx+xml')
      .firstOrNull;
  if (ncxItem != null) {
    final path = _tryResolve(opfDirectory, ncxItem.href);
    final file = path == null ? null : entries[path];
    if (path != null && file != null) {
      // Non-null means the NCX is usable XML with a `<navMap>`, even when it
      // has no points: the production `parse_ncx_toc` returns its (possibly
      // empty) entries and never falls back. `null` — unparseable XML here,
      // or a missing `<navMap>` — falls through to the nav document, like the
      // production `if let Ok(entries)` guard. (The retained TOC reader
      // validates a selected NCX's UTF-8 and lexically inspectable XML — a
      // tolerant shape walk under byte/depth/text limits — and fails the whole
      // book on that read; structural mismatches that pass the inspection only
      // fail the candidate's own parse and fall through. This package reads
      // the NCX without that gate, so an unparseable one reaches this fallback
      // with a warning instead.)
      final toc = _parseNcx(file.content, path, warnings);
      if (toc != null) return toc;
    }
  }
  // The production nav heuristic is the manifest id containing "nav"
  // (case-sensitive substring), not the `properties="nav"` attribute.
  final navItem = manifestItems.values
      .where(
        (item) =>
            item.mediaType == 'application/xhtml+xml' &&
            item.id.contains('nav'),
      )
      .firstOrNull;
  if (navItem != null) {
    final path = _tryResolve(opfDirectory, navItem.href);
    final file = path == null ? null : entries[path];
    if (path != null && file != null) {
      return _parseNavDocument(file.content, path, warnings);
    }
  }
  return const [];
}

List<EpubTocEntry> _parseNavDocument(
  List<int> bytes,
  String path,
  List<String> warnings,
) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  } on XmlException catch (error) {
    warnings.add(
      'failed to parse EPUB nav document at $path: ${error.message}',
    );
    return const [];
  }
  final directory = directoryOf(path);
  // The production parser takes the first `<nav>` element in document order;
  // it does not prefer one by `epub:type`, `type` or `role`.
  final tocNav = document.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'nav')
      .firstOrNull;
  if (tocNav == null) return const [];
  // The `<ol>` is the first one among the nav's descendants, not only its
  // direct children.
  final list = tocNav.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'ol')
      .firstOrNull;
  if (list == null) return const [];
  return _parseNavList(list, directory, warnings);
}

/// One level of an EPUB 3 nav list.
///
/// The shape follows the production `parse_nav_ol`: a part heading keeps its
/// own entry (a `<span>` title with no `<a>`, an empty target) and its nested
/// list becomes its children, so the authored depth survives into the contents
/// rows. The title is the link's own first text child, falling back to the
/// list item's `<span>`, matching the production extraction.
List<EpubTocEntry> _parseNavList(
  XmlElement list,
  String directory,
  List<String> warnings,
) {
  final entries = <EpubTocEntry>[];
  for (final item in list.children.whereType<XmlElement>()) {
    if (item.name.local != 'li') continue;
    final anchor = item.children
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'a')
        .firstOrNull;
    final nested = item.children
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'ol')
        .firstOrNull;
    final children = nested == null
        ? const <EpubTocEntry>[]
        : _parseNavList(nested, directory, warnings);
    final span = item.children
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'span')
        .firstOrNull;
    final title = (_firstTextChild(anchor) ?? _firstTextChild(span) ?? '')
        .trim();
    final href = anchor?.getAttribute('href');
    var resource = '';
    String? fragment;
    if (href != null) {
      try {
        final resolved = resolveEpubReference(directory, href);
        resource = resolved.path;
        fragment = resolved.fragment;
      } on EpubPathError {
        warnings.add('nav entry has an unusable href: $href');
      }
    }
    if (title.isEmpty && resource.isEmpty && children.isEmpty) continue;
    entries.add(
      EpubTocEntry(
        title: title,
        resource: resource,
        fragment: fragment,
        children: children,
      ),
    );
  }
  return entries;
}

/// The first text child of [element], or null.
///
/// The production parser reads a nav entry's title from its link's own text
/// child (not the concatenated descendant text), so a nested element inside the
/// link does not contribute to the title. A CDATA section is text to the
/// production parser, so it counts here too.
String? _firstTextChild(XmlElement? element) {
  if (element == null) return null;
  for (final child in element.children) {
    if (child is XmlText) return child.value;
    if (child is XmlCDATA) return child.value;
  }
  return null;
}

/// Parses an NCX table of contents.
///
/// Returns `null` — never a non-null empty list — when the NCX is unusable and
/// the caller must fall back to a nav document: XML this package cannot parse
/// or a document without a `<navMap>`. (The retained parser reaches this state
/// differently: structural mismatches that pass its tolerant shape inspection
/// fail only the candidate's own `roxmltree` parse and fall through, while a
/// read its inspection rejects — non-UTF-8 bytes, lexical errors or limit
/// violations — fails the whole book before any TOC parse. This package has
/// no such read gate.) A `<navMap>` with no
/// points parses to an empty list on purpose: the production `parse_ncx_toc`
/// succeeds there and no
/// nav fallback happens.
List<EpubTocEntry>? _parseNcx(
  List<int> bytes,
  String path,
  List<String> warnings,
) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  } on XmlException catch (error) {
    warnings.add('failed to parse EPUB NCX at $path: ${error.message}');
    return null;
  }
  final directory = directoryOf(path);
  final map = document.descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'navMap')
      .firstOrNull;
  if (map == null) return null;
  List<EpubTocEntry> parsePoints(XmlElement parent) {
    final entries = <EpubTocEntry>[];
    for (final point in parent.children.whereType<XmlElement>()) {
      if (point.name.local != 'navPoint') continue;
      // The production parser reads the first `<text>` descendant's own text
      // child; the label element's nesting is not part of the contract.
      final label = point.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'text')
          .firstOrNull;
      final content = point.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'content')
          .firstOrNull;
      final src = content?.getAttribute('src');
      final children = parsePoints(point);
      var resource = '';
      String? fragment;
      if (src != null) {
        try {
          final resolved = resolveEpubReference(directory, src);
          resource = resolved.path;
          fragment = resolved.fragment;
        } on EpubPathError {
          warnings.add('NCX entry has an unusable src: $src');
        }
      }
      entries.add(
        EpubTocEntry(
          title: (_firstTextChild(label) ?? '').trim(),
          resource: resource,
          fragment: fragment,
          children: children,
        ),
      );
    }
    return entries;
  }

  return parsePoints(map);
}
