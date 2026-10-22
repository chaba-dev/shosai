/// The reader and library's bridge: the seam the controllers reach documents
/// and records through, and the request and result types they exchange.
///
/// The application implements it over the Dart application core and the
/// document engines (`core_records.dart`); tests implement it with
/// deterministic fakes. The types keep the shapes of the former Rust bridge
/// (RFD 4, M3.0), so ordinals and offsets are still [BigInt]s.
library;

import 'dart:typed_data';

import 'package:shosai_epub/shosai_epub.dart' show EpubBook;

abstract interface class FlutterBridge {
  /// A new cancellation id for one operation; [cancel] cancels it and
  /// [releaseCancellation] forgets it.
  BigInt createCancellation();

  bool cancel({required BigInt id});

  bool releaseCancellation({required BigInt id});

  // Documents.

  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  });

  /// Open library book [bookId] after checking that its file still holds
  /// the book.
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  });

  /// The parsed book behind an open EPUB [document].
  Future<EpubBook> epubBook({
    required FlutterDocumentHandle document,
    required BigInt cancellationId,
  });

  bool releaseDocument({required FlutterDocumentHandle handle});

  // Library.

  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  });

  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  });

  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  });

  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({required int bookId});

  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  });

  Future<void> saveReaderSettings({required FlutterReaderSettings value});

  // Reading.

  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<void> saveReadingState({
    required int bookId,
    required FlutterReadingState value,
    required BigInt unitCount,
  });

  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
    String? note,
  });

  Future<void> updateBookmark({required int id, String? title, String? note});

  Future<void> updateBookmarkNote({required int id, String? note});

  Future<void> deleteBookmark({required int id});

  Future<String> exportBookmarks({required int bookId});

  // Annotations and search over an open document.

  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  });

  Future<FlutterAnnotation> createAnnotation({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required BigInt start,
    required BigInt end,
    required double displayScale,
    required FlutterHighlightColor color,
    String? body,
    required BigInt cancellationId,
  });

  Future<bool> updateAnnotation({
    required FlutterDocumentHandle document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  });

  Future<bool> deleteAnnotation({
    required FlutterDocumentHandle document,
    required String id,
  });

  Future<FlutterAnnotationAssociationSourcePage>
  listAnnotationAssociationSources({
    required FlutterDocumentHandle target,
    String? cursor,
    required BigInt limit,
    required BigInt cancellationId,
  });

  Future<FlutterAnnotationAssociationOutcome> associateAnnotationVersion({
    required String sourceVersionId,
    required FlutterDocumentHandle target,
    required BigInt cancellationId,
  });

  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  });

  /// Release everything the bridge holds; [isDisposed] is then true.
  void dispose();

  bool get isDisposed;
}

class FlutterAnnotation {
  final String id;
  final BigInt unit;
  final FlutterAnnotationResolution resolution;
  final FlutterAnnotationTextRange? textRange;
  final String? quote;
  final List<FlutterSelectionRect>? rectangles;
  final FlutterHighlightColor color;
  final String? body;

  const FlutterAnnotation({
    required this.id,
    required this.unit,
    required this.resolution,
    this.textRange,
    this.quote,
    this.rectangles,
    required this.color,
    this.body,
  });

  @override
  int get hashCode =>
      id.hashCode ^
      unit.hashCode ^
      resolution.hashCode ^
      textRange.hashCode ^
      quote.hashCode ^
      rectangles.hashCode ^
      color.hashCode ^
      body.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterAnnotation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          unit == other.unit &&
          resolution == other.resolution &&
          textRange == other.textRange &&
          quote == other.quote &&
          rectangles == other.rectangles &&
          color == other.color &&
          body == other.body;
}

enum FlutterAnnotationAssociationOutcome { associated, alreadyAssociated }

class FlutterAnnotationAssociationSource {
  final String versionId;
  final FlutterBookFormat format;
  final String localPath;
  final String fingerprintAlgorithm;
  final int fingerprintVersion;
  final Uint8List fingerprint;
  final BigInt liveAnnotations;

  const FlutterAnnotationAssociationSource({
    required this.versionId,
    required this.format,
    required this.localPath,
    required this.fingerprintAlgorithm,
    required this.fingerprintVersion,
    required this.fingerprint,
    required this.liveAnnotations,
  });

  @override
  int get hashCode =>
      versionId.hashCode ^
      format.hashCode ^
      localPath.hashCode ^
      fingerprintAlgorithm.hashCode ^
      fingerprintVersion.hashCode ^
      fingerprint.hashCode ^
      liveAnnotations.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterAnnotationAssociationSource &&
          runtimeType == other.runtimeType &&
          versionId == other.versionId &&
          format == other.format &&
          localPath == other.localPath &&
          fingerprintAlgorithm == other.fingerprintAlgorithm &&
          fingerprintVersion == other.fingerprintVersion &&
          fingerprint == other.fingerprint &&
          liveAnnotations == other.liveAnnotations;
}

class FlutterAnnotationAssociationSourcePage {
  final List<FlutterAnnotationAssociationSource> sources;
  final String? nextCursor;
  final String? previousCursor;

  const FlutterAnnotationAssociationSourcePage({
    required this.sources,
    this.nextCursor,
    this.previousCursor,
  });

  @override
  int get hashCode =>
      sources.hashCode ^ nextCursor.hashCode ^ previousCursor.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterAnnotationAssociationSourcePage &&
          runtimeType == other.runtimeType &&
          sources == other.sources &&
          nextCursor == other.nextCursor &&
          previousCursor == other.previousCursor;
}

enum FlutterAnnotationResolution { exact, recovered, ambiguous, orphaned }

class FlutterAnnotationTextRange {
  final BigInt start;
  final BigInt end;

  const FlutterAnnotationTextRange({required this.start, required this.end});

  @override
  int get hashCode => start.hashCode ^ end.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterAnnotationTextRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;
}

enum FlutterBookFormat { pdf, epub }

class FlutterBookmark {
  final int id;
  final int? bookId;
  final BigInt unit;
  final BigInt? offset;
  final String? title;
  final String? note;
  final String color;
  final String createdAt;

  const FlutterBookmark({
    required this.id,
    this.bookId,
    required this.unit,
    this.offset,
    this.title,
    this.note,
    required this.color,
    required this.createdAt,
  });

  @override
  int get hashCode =>
      id.hashCode ^
      bookId.hashCode ^
      unit.hashCode ^
      offset.hashCode ^
      title.hashCode ^
      note.hashCode ^
      color.hashCode ^
      createdAt.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterBookmark &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          bookId == other.bookId &&
          unit == other.unit &&
          offset == other.offset &&
          title == other.title &&
          note == other.note &&
          color == other.color &&
          createdAt == other.createdAt;
}

/// A failure the bridge reports, with the kind the reader presents.
class FlutterBridgeError implements Exception {
  final FlutterBridgeErrorKind kind;
  final String message;

  const FlutterBridgeError({required this.kind, required this.message});

  @override
  String toString() => 'FlutterBridgeError(${kind.name}): $message';

  @override
  int get hashCode => kind.hashCode ^ message.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterBridgeError &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          message == other.message;
}

enum FlutterBridgeErrorKind {
  cancelled,
  notFound,
  inaccessible,
  unsupported,
  invalidRequest,
  malformed,
  limitExceeded,
  backendUnavailable,
  renderFailed,
}

class FlutterDocumentHandle {
  final BigInt registry;
  final BigInt id;

  const FlutterDocumentHandle({required this.registry, required this.id});

  @override
  int get hashCode => registry.hashCode ^ id.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterDocumentHandle &&
          runtimeType == other.runtimeType &&
          registry == other.registry &&
          id == other.id;
}

class FlutterDocumentSummary {
  final FlutterDocumentHandle handle;
  final int? bookId;
  final FlutterBookFormat format;
  final String? title;
  final BigInt logicalUnitCount;

  /// The file the document's engines read while it is open, when that is
  /// not the path it was opened from: the private, verified snapshot of a
  /// PDF, which stays until the document is released. Null when the
  /// document needs no file after opening (an EPUB) or its opener reads the
  /// opened path (test fakes).
  final String? contentPath;

  const FlutterDocumentSummary({
    required this.handle,
    this.bookId,
    required this.format,
    this.title,
    required this.logicalUnitCount,
    this.contentPath,
  });

  @override
  int get hashCode =>
      Object.hash(handle, bookId, format, title, logicalUnitCount, contentPath);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterDocumentSummary &&
          runtimeType == other.runtimeType &&
          handle == other.handle &&
          bookId == other.bookId &&
          format == other.format &&
          title == other.title &&
          logicalUnitCount == other.logicalUnitCount &&
          contentPath == other.contentPath;
}

enum FlutterHighlightColor { yellow, green, blue, pink, purple }

class FlutterImportItem {
  final String pathKey;
  final FlutterLibraryBook? book;
  final String? error;
  final String? warning;

  const FlutterImportItem({
    required this.pathKey,
    this.book,
    this.error,
    this.warning,
  });

  @override
  int get hashCode =>
      pathKey.hashCode ^ book.hashCode ^ error.hashCode ^ warning.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterImportItem &&
          runtimeType == other.runtimeType &&
          pathKey == other.pathKey &&
          book == other.book &&
          error == other.error &&
          warning == other.warning;
}

class FlutterImportReport {
  final BigInt imported;
  final BigInt failed;
  final bool cancelled;
  final List<FlutterImportItem> items;

  const FlutterImportReport({
    required this.imported,
    required this.failed,
    required this.cancelled,
    required this.items,
  });

  @override
  int get hashCode =>
      imported.hashCode ^ failed.hashCode ^ cancelled.hashCode ^ items.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterImportReport &&
          runtimeType == other.runtimeType &&
          imported == other.imported &&
          failed == other.failed &&
          cancelled == other.cancelled &&
          items == other.items;
}

class FlutterLibraryBook {
  final int bookId;
  final String title;
  final String? author;
  final FlutterBookFormat format;
  final String pathKey;
  final bool managed;
  final Uint8List? cover;
  final double progress;
  final String dateAdded;
  final String? lastRead;

  const FlutterLibraryBook({
    required this.bookId,
    required this.title,
    this.author,
    required this.format,
    required this.pathKey,
    required this.managed,
    this.cover,
    required this.progress,
    required this.dateAdded,
    this.lastRead,
  });

  @override
  int get hashCode =>
      bookId.hashCode ^
      title.hashCode ^
      author.hashCode ^
      format.hashCode ^
      pathKey.hashCode ^
      managed.hashCode ^
      cover.hashCode ^
      progress.hashCode ^
      dateAdded.hashCode ^
      lastRead.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterLibraryBook &&
          runtimeType == other.runtimeType &&
          bookId == other.bookId &&
          title == other.title &&
          author == other.author &&
          format == other.format &&
          pathKey == other.pathKey &&
          managed == other.managed &&
          cover == other.cover &&
          progress == other.progress &&
          dateAdded == other.dateAdded &&
          lastRead == other.lastRead;
}

/// The order a library page lists books in.
enum FlutterLibrarySort { recent, title, author }

/// A book's notes at a glance: how many there are, and the words of the
/// latest one (its quote, or its note when it quotes nothing).
class FlutterNotesSummary {
  final int count;
  final String? latest;

  const FlutterNotesSummary({required this.count, this.latest});

  @override
  int get hashCode => count.hashCode ^ latest.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterNotesSummary &&
          count == other.count &&
          latest == other.latest;
}

class FlutterLibraryPage {
  final List<FlutterLibraryBook> books;
  final bool hasMore;

  /// How many books the whole library holds, or null when the source does
  /// not say.
  final int? bookCount;

  /// The book last opened for reading and not yet finished, whatever the
  /// page's query, format and order.
  final FlutterLibraryBook? continueReading;

  /// [continueReading]'s notes, for the Continue reading hero.
  final FlutterNotesSummary? continueReadingNotes;

  const FlutterLibraryPage({
    required this.books,
    required this.hasMore,
    this.bookCount,
    this.continueReading,
    this.continueReadingNotes,
  });

  @override
  int get hashCode =>
      books.hashCode ^
      hasMore.hashCode ^
      bookCount.hashCode ^
      continueReading.hashCode ^
      continueReadingNotes.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterLibraryPage &&
          runtimeType == other.runtimeType &&
          books == other.books &&
          hasMore == other.hasMore &&
          bookCount == other.bookCount &&
          continueReading == other.continueReading &&
          continueReadingNotes == other.continueReadingNotes;
}

class FlutterLibraryRemoveOutcome {
  final bool removed;
  final bool managedFileDeletionPending;

  const FlutterLibraryRemoveOutcome({
    required this.removed,
    required this.managedFileDeletionPending,
  });

  @override
  int get hashCode => removed.hashCode ^ managedFileDeletionPending.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterLibraryRemoveOutcome &&
          runtimeType == other.runtimeType &&
          removed == other.removed &&
          managedFileDeletionPending == other.managedFileDeletionPending;
}

class FlutterOpenRequest {
  final String localId;
  final String pathKey;
  final FlutterBookFormat? formatHint;

  const FlutterOpenRequest({
    required this.localId,
    required this.pathKey,
    this.formatHint,
  });

  @override
  int get hashCode => localId.hashCode ^ pathKey.hashCode ^ formatHint.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterOpenRequest &&
          runtimeType == other.runtimeType &&
          localId == other.localId &&
          pathKey == other.pathKey &&
          formatHint == other.formatHint;
}

class FlutterReaderSettings {
  final bool continuous;
  final String theme;
  final double epubFontSize;
  final double epubLineSpacing;
  final double pdfZoom;

  const FlutterReaderSettings({
    required this.continuous,
    required this.theme,
    required this.epubFontSize,
    required this.epubLineSpacing,
    required this.pdfZoom,
  });

  @override
  int get hashCode =>
      continuous.hashCode ^
      theme.hashCode ^
      epubFontSize.hashCode ^
      epubLineSpacing.hashCode ^
      pdfZoom.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterReaderSettings &&
          runtimeType == other.runtimeType &&
          continuous == other.continuous &&
          theme == other.theme &&
          epubFontSize == other.epubFontSize &&
          epubLineSpacing == other.epubLineSpacing &&
          pdfZoom == other.pdfZoom;
}

class FlutterReadingState {
  final BigInt unit;
  final BigInt? offset;
  final double zoom;

  const FlutterReadingState({
    required this.unit,
    this.offset,
    required this.zoom,
  });

  @override
  int get hashCode => unit.hashCode ^ offset.hashCode ^ zoom.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterReadingState &&
          runtimeType == other.runtimeType &&
          unit == other.unit &&
          offset == other.offset &&
          zoom == other.zoom;
}

class FlutterSearchMatch {
  final BigInt unit;
  final BigInt offset;
  final BigInt length;
  final String context;

  const FlutterSearchMatch({
    required this.unit,
    required this.offset,
    required this.length,
    required this.context,
  });

  @override
  int get hashCode =>
      unit.hashCode ^ offset.hashCode ^ length.hashCode ^ context.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterSearchMatch &&
          runtimeType == other.runtimeType &&
          unit == other.unit &&
          offset == other.offset &&
          length == other.length &&
          context == other.context;
}

class FlutterSelectionCaret {
  final BigInt offset;
  final double x;
  final double alongLine;
  final bool vertical;
  final double top;
  final double bottom;

  const FlutterSelectionCaret({
    required this.offset,
    required this.x,
    required this.alongLine,
    required this.vertical,
    required this.top,
    required this.bottom,
  });

  @override
  int get hashCode =>
      offset.hashCode ^
      x.hashCode ^
      alongLine.hashCode ^
      vertical.hashCode ^
      top.hashCode ^
      bottom.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterSelectionCaret &&
          runtimeType == other.runtimeType &&
          offset == other.offset &&
          x == other.x &&
          alongLine == other.alongLine &&
          vertical == other.vertical &&
          top == other.top &&
          bottom == other.bottom;
}

class FlutterSelectionEndpoint {
  final BigInt offset;
  final BigInt rangeStart;
  final BigInt rangeEnd;
  final FlutterSelectionRect rect;

  const FlutterSelectionEndpoint({
    required this.offset,
    required this.rangeStart,
    required this.rangeEnd,
    required this.rect,
  });

  @override
  int get hashCode =>
      offset.hashCode ^ rangeStart.hashCode ^ rangeEnd.hashCode ^ rect.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterSelectionEndpoint &&
          runtimeType == other.runtimeType &&
          offset == other.offset &&
          rangeStart == other.rangeStart &&
          rangeEnd == other.rangeEnd &&
          rect == other.rect;
}

class FlutterSelectionRect {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const FlutterSelectionRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  @override
  int get hashCode =>
      left.hashCode ^ top.hashCode ^ right.hashCode ^ bottom.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterSelectionRect &&
          runtimeType == other.runtimeType &&
          left == other.left &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom;
}

class FlutterSelectionSurface {
  final double width;
  final double height;
  final String text;
  final bool copyEligible;
  final String? resourcePath;
  final List<FlutterSelectionEndpoint> endpoints;
  final Uint32List graphemeBoundaries;
  final Uint32List wordBoundaries;
  final List<FlutterSelectionVisualLine> visualLines;

  const FlutterSelectionSurface({
    required this.width,
    required this.height,
    required this.text,
    required this.copyEligible,
    this.resourcePath,
    required this.endpoints,
    required this.graphemeBoundaries,
    required this.wordBoundaries,
    required this.visualLines,
  });

  @override
  int get hashCode =>
      width.hashCode ^
      height.hashCode ^
      text.hashCode ^
      copyEligible.hashCode ^
      resourcePath.hashCode ^
      endpoints.hashCode ^
      graphemeBoundaries.hashCode ^
      wordBoundaries.hashCode ^
      visualLines.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterSelectionSurface &&
          runtimeType == other.runtimeType &&
          width == other.width &&
          height == other.height &&
          text == other.text &&
          copyEligible == other.copyEligible &&
          resourcePath == other.resourcePath &&
          endpoints == other.endpoints &&
          graphemeBoundaries == other.graphemeBoundaries &&
          wordBoundaries == other.wordBoundaries &&
          visualLines == other.visualLines;
}

class FlutterSelectionVisualLine {
  final List<FlutterSelectionCaret> carets;

  const FlutterSelectionVisualLine({required this.carets});

  @override
  int get hashCode => carets.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlutterSelectionVisualLine &&
          runtimeType == other.runtimeType &&
          carets == other.carets;
}
