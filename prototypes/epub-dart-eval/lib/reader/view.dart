/// Reader chrome and document host for the evaluation prototype.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shosai_epub/shosai_epub.dart';

import 'controller.dart';
import 'message.dart';
import 'model.dart';
import 'theme.dart';
import 'view_document.dart';

class EpubReaderView extends StatelessWidget {
  const EpubReaderView({
    super.key,
    required this.controller,
    required this.model,
    this.documentKey,
  });

  final EpubReaderController controller;
  final EpubReaderModel model;

  /// Optional key for a [RepaintBoundary] around the document surface, used by
  /// capture-based evidence tests.
  final Key? documentKey;

  void _dispatch(EpubReaderMessage message) => controller.dispatch(message);

  @override
  Widget build(BuildContext context) {
    final palette = model.typography.palette;
    return Scaffold(
      backgroundColor: palette.background,
      body: Column(
        children: [
          _ReaderHeader(model: model, dispatch: _dispatch),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.arrowRight,
                      ): () =>
                          _dispatch(const EpubReaderUnitRequested(1)),
                      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                          _dispatch(const EpubReaderUnitRequested(-1)),
                      const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                          _dispatch(const EpubReaderUnitRequested(1)),
                      const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                          _dispatch(const EpubReaderUnitRequested(-1)),
                      const SingleActivator(
                        LogicalKeyboardKey.keyC,
                        control: true,
                      ): () =>
                          _dispatch(const EpubReaderSelectionCopyRequested()),
                      const SingleActivator(LogicalKeyboardKey.escape): () =>
                          _dispatch(const EpubReaderSelectionCancelled()),
                      const SingleActivator(LogicalKeyboardKey.keyH): () =>
                          _dispatch(
                            const EpubReaderHighlightRequested(
                              ReaderHighlightColor.yellow,
                            ),
                          ),
                    },
                    child: Focus(
                      autofocus: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 8,
                        ),
                        child: _DocumentArea(
                          model: model,
                          dispatch: _dispatch,
                          documentKey: documentKey,
                        ),
                      ),
                    ),
                  ),
                ),
                if (model.contentsOpen)
                  _ContentsPanel(model: model, dispatch: _dispatch),
              ],
            ),
          ),
          _ReaderFooter(model: model),
        ],
      ),
    );
  }
}

class _ReaderHeader extends StatelessWidget {
  const _ReaderHeader({required this.model, required this.dispatch});

  final EpubReaderModel model;
  final void Function(EpubReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final palette = model.typography.palette;
    final ink = palette.foreground;
    return Container(
      color: palette.background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              model.title,
              style: TextStyle(color: ink, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (model.status == EpubReaderStatus.ready &&
              (model.relayoutBusy ||
                  model.relayoutPending ||
                  !model.layoutComplete))
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: ink),
              ),
            ),
          _HeaderButton(
            label: model.mode == EpubReaderMode.paginated
                ? 'Continuous'
                : 'Paginated',
            onPressed: () => dispatch(
              EpubReaderModeChanged(
                model.mode == EpubReaderMode.paginated
                    ? EpubReaderMode.continuous
                    : EpubReaderMode.paginated,
              ),
            ),
          ),
          _HeaderButton(
            label: 'A-',
            onPressed: () => dispatch(const EpubReaderFontSizeChanged(-2)),
          ),
          _HeaderButton(
            label: 'A+',
            onPressed: () => dispatch(const EpubReaderFontSizeChanged(2)),
          ),
          _HeaderButton(
            label: model.theme.name,
            onPressed: () => dispatch(
              EpubReaderThemeChanged(switch (model.theme) {
                ReaderTheme.light => ReaderTheme.dark,
                ReaderTheme.dark => ReaderTheme.sepia,
                ReaderTheme.sepia => ReaderTheme.light,
              }),
            ),
          ),
          _HeaderButton(
            label: 'Contents',
            onPressed: () => dispatch(const EpubReaderContentsToggled()),
          ),
          if (model.selection != null) ...[
            _HeaderButton(
              label: 'Copy',
              onPressed: () =>
                  dispatch(const EpubReaderSelectionCopyRequested()),
            ),
            _HeaderButton(
              label: 'Highlight',
              onPressed: () => dispatch(
                const EpubReaderHighlightRequested(ReaderHighlightColor.yellow),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: TextButton(onPressed: onPressed, child: Text(label)),
  );
}

class _ReaderFooter extends StatelessWidget {
  const _ReaderFooter({required this.model});

  final EpubReaderModel model;

  @override
  Widget build(BuildContext context) {
    final palette = model.typography.palette;
    final pages = model.visiblePages;
    // While the progressive layout is still measuring the chapter, the page
    // count is partial: report the durable progress instead of a fabricated
    // total.
    final label = !model.layoutComplete
        ? 'Laying out — ${(model.progress * 100).round()}%'
        : model.mode == EpubReaderMode.paginated
        ? 'Page ${pages.isEmpty ? 0 : pages.first + 1}'
              ' of ${model.paginated?.pages.length ?? 0}'
        : 'Continuous — ${(model.progress * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(color: palette.pageNumber, fontSize: 12),
          ),
          const Spacer(),
          if (model.notice != null)
            Flexible(
              child: Text(
                model.notice!,
                style: TextStyle(color: palette.pageNumber, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

class _DocumentArea extends StatelessWidget {
  const _DocumentArea({
    required this.model,
    required this.dispatch,
    this.documentKey,
  });

  final EpubReaderModel model;
  final void Function(EpubReaderMessage) dispatch;
  final Key? documentKey;

  @override
  Widget build(BuildContext context) {
    if (model.status == EpubReaderStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (model.status == EpubReaderStatus.failed) {
      return Center(
        child: Text(
          model.error ?? 'Failed to open the document',
          style: TextStyle(color: model.typography.palette.foreground),
        ),
      );
    }
    if (model.status == EpubReaderStatus.idle) {
      return const Center(child: Text('Open a book to begin.'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          dispatch(
            EpubReaderViewportChanged(
              constraints.maxWidth,
              constraints.maxHeight,
            ),
          );
        });
        return EpubDocumentSurface(
          model: model,
          dispatch: dispatch,
          repaintKey: documentKey,
        );
      },
    );
  }
}

class _ContentsPanel extends StatelessWidget {
  const _ContentsPanel({required this.model, required this.dispatch});

  final EpubReaderModel model;
  final void Function(EpubReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final book = model.book;
    final palette = model.typography.palette;
    return Container(
      width: 280,
      color: palette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Contents', style: TextStyle(fontSize: 14)),
          ),
          Expanded(
            child: book == null
                ? const SizedBox.shrink()
                : ListView(
                    children: [
                      for (final entry in book.toc) ..._tocRows(entry, 0),
                      if (model.highlights.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Highlights',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        for (final highlight in model.highlights)
                          ListTile(
                            dense: true,
                            title: Text(
                              '${highlight.color.name} '
                              '(${highlight.end - highlight.start} chars)',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => dispatch(
                                EpubReaderHighlightDeleted(highlight.id),
                              ),
                            ),
                            onTap: () => dispatch(
                              EpubReaderScalarJumpRequested(
                                spine: highlight.spine,
                                scalar: highlight.start,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _tocRows(EpubTocEntry entry, int depth) {
    return [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 12.0 + depth * 12, right: 12),
        title: Text(
          entry.title.isEmpty ? 'Untitled' : entry.title,
          style: const TextStyle(fontSize: 13),
        ),
        onTap: () {
          final book = model.book!;
          final spine = book.spine.indexOf(entry.resource);
          if (spine < 0) return;
          final scalar = entry.fragment == null
              ? 0
              : (book.chapters[spine].anchors[entry.fragment!] ?? 0);
          dispatch(
            EpubReaderContentsEntryActivated(spine: spine, scalar: scalar),
          );
        },
      ),
      for (final child in entry.children) ..._tocRows(child, depth + 1),
    ];
  }
}
