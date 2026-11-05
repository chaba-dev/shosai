part of 'view.dart';

/// Original page pixels on paper, with navigation furniture outside the crop.
class _ReaderColumns extends StatefulWidget {
  const _ReaderColumns({
    required this.model,
    required this.dispatch,
    required this.contentKey,
  });
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final Key contentKey;

  @override
  State<_ReaderColumns> createState() => _ReaderColumnsState();
}

class _ReaderColumnsState extends State<_ReaderColumns> {
  Offset _pan = Offset.zero;

  @override
  void didUpdateWidget(_ReaderColumns oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model.pdfColumns != widget.model.pdfColumns) {
      _pan = Offset.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final screen = model.pdfColumns;
    final image = model.pageImage;
    final colors = pageColors(model.typography.theme);
    if (screen == null || image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final l10n = AppLocalizations.of(context);
    final first = screen.topPage + 1;
    final last = screen.pieces.last.page + 1;
    final total = model.document!.logicalUnitCount.toInt();
    final label = first == last
        ? l10n.readerQuietPageOf(first, total)
        : l10n.readerQuietPagesOf(first, last, total);
    final filter = _pdfPageColorFilter(colors.background, colors.foreground);
    final raster = RawImage(
      key: const ValueKey('reader-columns-raster'),
      image: image,
      width: screen.width,
      height: screen.height,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
    final detail = screen.strip != null;
    return ColoredBox(
      color: _pdfSheetColor(model.typography.theme),
      child: Column(
        children: [
          Container(
            color: colors.background,
            height: detail ? pdfStripDetailHeaderHeight : pdfStripHeaderHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (model.typography.progress != FlutterReaderProgress.off)
                  Row(
                    key: const ValueKey('reader-columns-folio'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (model.typography.progress ==
                          FlutterReaderProgress.page) ...[
                        CustomPaint(
                          key: const ValueKey('reader-columns-outline'),
                          size: const Size(12, 15),
                          painter: _ColumnsOutlinePainter(
                            screen,
                            colors.foreground,
                            _pan,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      _ReaderFolio(
                        model: model,
                        ordinal: first,
                        lastOrdinal: last,
                      ),
                    ],
                  ),
                if (detail)
                  Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox.square(
                      dimension: pdfStripDetailHeaderHeight,
                      child: _ReaderEdgeButton(
                        semanticsKey: const ValueKey(
                          'reader-columns-detail-close',
                        ),
                        icon: LucideIcons.x,
                        semanticsLabel: l10n.readerReferenceClose,
                        color: colors.foreground,
                        onPressed: model.relayoutBusy
                            ? null
                            : () => widget.dispatch(
                                ReaderColumnsDetailRequested(
                                  screen,
                                  screen.pieces.single,
                                  1,
                                ),
                              ),
                      ),
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
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    final metrics = notification.metrics;
                    final pan = metrics.axis == Axis.horizontal
                        ? Offset(metrics.pixels, _pan.dy)
                        : Offset(_pan.dx, metrics.pixels);
                    if (pan != _pan) setState(() => _pan = pan);
                    return false;
                  },
                  child: _ReaderPageGestures(
                    // Each new screen starts at its fitted band/column edge,
                    // not at a horizontal pan inherited from the last column.
                    key: ValueKey(screen),
                    model: model,
                    dispatch: widget.dispatch,
                    fittedZoom: null,
                    columnsScreen: screen,
                    builder: (horizontal, vertical) => SingleChildScrollView(
                      controller: horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: screen.width,
                        child: SingleChildScrollView(
                          controller: vertical,
                          child: SizedBox(
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
                                                  color: colors.foreground
                                                      .withValues(alpha: .25),
                                                ),
                                              ),
                                            )
                                          : ColoredBox(
                                              color: colors.foreground
                                                  .withValues(alpha: .04),
                                              child: Center(
                                                child: Text(
                                                  l10n.readerPageNumber(
                                                    separator.page! + 1,
                                                  ),
                                                  style: _readerFolioStyle(
                                                    model,
                                                    color: colors.foreground
                                                        .withValues(alpha: .6),
                                                  ),
                                                ),
                                              ),
                                            ),
                                    ),
                                  Positioned.fill(
                                    child: _SelectableSurface(
                                      key: widget.contentKey,
                                      surface: model.selectionSurface!,
                                      image: null,
                                      epubPage: null,
                                      model: model,
                                      fit: BoxFit.fill,
                                      dispatch: widget.dispatch,
                                      paintContent: false,
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
  const _ColumnsOutlinePainter(this.screen, this.ink, this.pan);
  final PdfStripScreen screen;
  final Color ink;
  final Offset pan;

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
      final strip = screen.strip ?? screen;
      final visible = Rect.fromLTWH(
        piece.left,
        piece.top,
        piece.width,
        piece.height,
      ).intersect(pan & Size(strip.width, strip.height));
      if (visible.isEmpty) continue;
      final first = piece.toPage(visible.left, visible.top);
      final last = piece.toPage(visible.right, visible.bottom);
      canvas.drawRect(
        Rect.fromLTRB(
          page.left + first.x / screen.pageWidth * page.width,
          page.top + first.y / screen.pageHeight * page.height,
          page.left + last.x / screen.pageWidth * page.width,
          page.top + last.y / screen.pageHeight * page.height,
        ),
        Paint()..color = ink.withValues(alpha: .45),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ColumnsOutlinePainter oldDelegate) =>
      screen != oldDelegate.screen ||
      ink != oldDelegate.ink ||
      pan != oldDelegate.pan;
}
