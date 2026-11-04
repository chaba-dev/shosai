part of 'view.dart';

/// Original page pixels on paper, with navigation furniture outside the crop.
class _ReaderColumns extends StatelessWidget {
  const _ReaderColumns({required this.model});
  final ReaderModel model;

  @override
  Widget build(BuildContext context) {
    final screen = model.pdfColumns;
    final image = model.pageImage;
    final colors = pageColors(model.typography.theme);
    if (screen == null || image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final l10n = AppLocalizations.of(context);
    final label = l10n.readerQuietPageOf(
      screen.topPage + 1,
      model.document!.logicalUnitCount.toInt(),
    );
    final filter = _pdfPageColorFilter(colors.background, colors.foreground);
    final raster = RawImage(
      key: const ValueKey('reader-columns-raster'),
      image: image,
      width: screen.width,
      height: screen.height,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
    return ColoredBox(
      color: colors.background,
      child: Column(
        children: [
          SizedBox(
            height: pdfStripHeaderHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CustomPaint(
                  key: const ValueKey('reader-columns-outline'),
                  size: const Size(12, 15),
                  painter: _ColumnsOutlinePainter(screen, colors.foreground),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  key: const ValueKey('reader-columns-folio'),
                  style: _readerFolioStyle(
                    model,
                    color: colors.foreground.withValues(alpha: .6),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: pdfStripSideInset,
              ),
              child: ClipRect(
                child: SingleChildScrollView(
                  // Each new screen starts at its fitted band/column edge,
                  // not at a horizontal pan inherited from the last column.
                  key: ValueKey(screen),
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: screen.width,
                    height: screen.height,
                    child: Semantics(
                      label: label,
                      image: true,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: filter == null
                                ? raster
                                : ColorFiltered(
                                    colorFilter: filter,
                                    child: raster,
                                  ),
                          ),
                          for (final separator in screen.separators)
                            Positioned(
                              top: separator.top,
                              left: 0,
                              right: 0,
                              height: separator.page == null ? 16 : 28,
                              child: separator.page == null
                                  ? Center(
                                      child: SizedBox(
                                        width: 32,
                                        child: Divider(
                                          height: 1,
                                          color: colors.foreground.withValues(
                                            alpha: .25,
                                          ),
                                        ),
                                      ),
                                    )
                                  : ColoredBox(
                                      color: colors.foreground.withValues(
                                        alpha: .04,
                                      ),
                                      child: Center(
                                        child: Text(
                                          l10n.readerPageNumber(
                                            separator.page! + 1,
                                          ),
                                          style: _readerFolioStyle(
                                            model,
                                            color: colors.foreground.withValues(
                                              alpha: .6,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnsOutlinePainter extends CustomPainter {
  const _ColumnsOutlinePainter(this.screen, this.ink);
  final PdfStripScreen screen;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Rect.fromLTWH(.5, .5, size.width - 1, size.height - 1);
    canvas.drawRect(
      page,
      Paint()
        ..color = ink.withValues(alpha: .4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.save();
    canvas.clipRect(page);
    for (final piece in screen.pieces.where((p) => p.page == screen.topPage)) {
      final source = piece.source;
      canvas.drawRect(
        Rect.fromLTRB(
          page.left + source.left / screen.pageWidth * page.width,
          page.top + source.top / screen.pageHeight * page.height,
          page.left + source.right / screen.pageWidth * page.width,
          page.top + source.bottom / screen.pageHeight * page.height,
        ),
        Paint()..color = ink.withValues(alpha: .45),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ColumnsOutlinePainter oldDelegate) =>
      screen != oldDelegate.screen || ink != oldDelegate.ink;
}
