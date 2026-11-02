part of 'controller.dart';

/// What decides how many pages a chapter takes: everything in an EPUB layout
/// key except the chapter itself (whose writing mode the chapter carries) and
/// the theme (which colours pages without moving a line).
typedef _EpubPagesKey = ({
  int generation,
  double pageWidth,
  double height,
  double fontSize,
  double lineSpacing,
});

/// How many pages each chapter of the open EPUB takes at one layout, so a
/// page can be numbered from the start of the book (decided 2026-10-30).
///
/// Chapters are counted in the background, the ones before the page being
/// read first, each laid out in full in its own session and released once
/// counted. Counts are kept for every layout the book has been read at while
/// open, so going back to a text size reuses them.
final class _EpubBookPages {
  _EpubBookPages(int chapters) : counts = List<int?>.filled(chapters, null);
  final List<int?> counts;

  /// The pages before [unit], or null until every earlier chapter is counted.
  int? before(int unit) {
    var pages = 0;
    for (var index = 0; index < unit && index < counts.length; index++) {
      final count = counts[index];
      if (count == null) return null;
      pages += count;
    }
    return pages;
  }
}

extension on ReaderController {
  _EpubPagesKey? get _epubPagesKey {
    final key = _epubSessionKey;
    if (key == null || key.continuous) return null;
    return (
      generation: key.generation,
      pageWidth: key.pageWidth,
      height: key.height,
      fontSize: key.fontSize,
      lineSpacing: key.lineSpacing,
    );
  }

  /// The page number, from the start of the book, of [page]'s first page.
  int? _epubBookOrdinal(ReaderEpubPage page) {
    final key = _epubPagesKey;
    // The first chapter's pages are numbered before anything is counted.
    final before = page.unit == 0
        ? 0
        : key == null
        ? null
        : _epubBookPages[key]?.before(page.unit);
    return before == null ? null : before + page.pageIndex + 1;
  }

  /// Starts counting the chapters at the current layout, unless they are
  /// counted or being counted already.
  void _countEpubBookPages() {
    final key = _epubPagesKey;
    final source = _epubSource;
    if (key == null || source == null || key == _epubPagesCounting) return;
    final chapters = source.book.chapters.length;
    final pages = _epubBookPages.putIfAbsent(
      key,
      () => _EpubBookPages(chapters),
    );
    if (!pages.counts.contains(null)) return;
    _epubPagesCounting = key;
    final effect = _countEpubChapters(key, source, pages);
    unawaited(
      effect.whenComplete(() {
        if (_epubPagesCounting == key) _epubPagesCounting = null;
      }),
    );
  }

  /// A real event-loop turn for the reader's own layout, frames and input.
  /// Releasing the book ends it at once, so the count stops and disposes its
  /// session instead of leaving a timer behind.
  Future<void> _pauseCountingEpubPages() {
    final resume = Completer<void>();
    _epubPagesResume = resume;
    _epubPagesPause = Timer(const Duration(milliseconds: 1), () {
      if (!resume.isCompleted) resume.complete();
    });
    return resume.future;
  }

  void _stopCountingEpubPages() {
    _epubPagesCounting = null;
    _epubPagesPause?.cancel();
    _epubPagesPause = null;
    final resume = _epubPagesResume;
    _epubPagesResume = null;
    if (resume != null && !resume.isCompleted) resume.complete();
  }

  Future<void> _countEpubChapters(
    _EpubPagesKey key,
    EpubContentSource source,
    _EpubBookPages pages,
  ) async {
    bool current() =>
        _epubPagesCounting == key &&
        _isCurrent(key.generation) &&
        identical(_epubSource, source) &&
        _epubPagesKey == key;
    // Chapters are counted in reading order: the ones before the page being
    // read number it, and they come first.
    final typography = _epubTypography(_model.layout, source);
    for (var unit = 0; unit < pages.counts.length; unit++) {
      if (pages.counts[unit] != null) continue;
      await _pauseCountingEpubPages();
      if (!current()) return;
      if (_model.relayoutBusy || _model.busy) {
        // Count again once the reader's own layout settles.
        _epubPagesCounting = null;
        return;
      }
      final chapter = source.book.chapters[unit];
      int count;
      if (source.layoutLimitExceeded(unit) != null) {
        // A refused chapter shows one page saying so.
        count = 1;
      } else {
        try {
          await source.ensureImages(chapter, _epubImageDecoder);
        } catch (_) {
          // Images that fail to decode are laid out as they are shown.
        }
        if (!current()) return;
        final vertical = chapter.writingMode == EpubWritingMode.verticalRl;
        final pageSize = ui.Size(key.pageWidth, key.height);
        final box = epubPageBoxFor(pageSize, vertical: vertical);
        final session = ChapterLayoutSession(
          chapter: chapter,
          spec: ChapterLayoutSpec(
            width: box.inlineExtent,
            height: box.blockExtent,
            typography: typography,
            vertical: vertical,
          ),
          images: source.images,
          clock: _layoutClock,
        );
        try {
          session.layoutWindowAt(0, maxMicros: 4000);
          while (!session.complete) {
            await _pauseCountingEpubPages();
            if (!current()) return;
            if (session.layoutForward(maxNodes: 24, maxMicros: 4000) == 0) {
              break;
            }
          }
          count = paginateWindow(
            session.snapshot(),
            pageSize,
            vertical: vertical,
          ).pages.length;
        } catch (_) {
          // A chapter that cannot be measured is numbered as one page rather
          // than leaving every later page unnumbered.
          count = 1;
        } finally {
          session.dispose();
        }
      }
      pages.counts[unit] = math.max(1, count);
      // Numbers appear as soon as the chapters before the page are counted.
      if (unit < _model.unit) _emit(_model);
    }
  }
}
