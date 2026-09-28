/// Typed reader intents for the evaluation prototype.
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';

import 'effects.dart';
import 'layout/flow.dart';
import 'layout/pages.dart';
import 'model.dart';
import 'theme.dart';

sealed class EpubReaderMessage {
  const EpubReaderMessage();
}

class EpubReaderOpenRequested extends EpubReaderMessage {
  const EpubReaderOpenRequested(this.path);

  final String path;
}

class EpubReaderViewportChanged extends EpubReaderMessage {
  const EpubReaderViewportChanged(this.width, this.height);

  final double width;
  final double height;
}

class EpubReaderModeChanged extends EpubReaderMessage {
  const EpubReaderModeChanged(this.mode);

  final EpubReaderMode mode;
}

class EpubReaderFontSizeChanged extends EpubReaderMessage {
  const EpubReaderFontSizeChanged(this.delta);

  final double delta;
}

class EpubReaderThemeChanged extends EpubReaderMessage {
  const EpubReaderThemeChanged(this.theme);

  final ReaderTheme theme;
}

class EpubReaderUnitRequested extends EpubReaderMessage {
  const EpubReaderUnitRequested(this.delta);

  final int delta;
}

class EpubReaderScalarJumpRequested extends EpubReaderMessage {
  const EpubReaderScalarJumpRequested({
    required this.spine,
    required this.scalar,
  });

  final int spine;
  final int scalar;
}

class EpubReaderContinuousOffsetChanged extends EpubReaderMessage {
  const EpubReaderContinuousOffsetChanged(this.offset);

  final double offset;
}

class EpubReaderContentsToggled extends EpubReaderMessage {
  const EpubReaderContentsToggled();
}

class EpubReaderContentsEntryActivated extends EpubReaderMessage {
  const EpubReaderContentsEntryActivated({
    required this.spine,
    required this.scalar,
  });

  final int spine;
  final int scalar;
}

class EpubReaderTapRequested extends EpubReaderMessage {
  const EpubReaderTapRequested(this.position);

  final Offset position;
}

class EpubReaderSelectionStarted extends EpubReaderMessage {
  const EpubReaderSelectionStarted(this.position);

  final Offset position;
}

class EpubReaderSelectionExtended extends EpubReaderMessage {
  const EpubReaderSelectionExtended(this.position);

  final Offset position;
}

class EpubReaderSelectionEnded extends EpubReaderMessage {
  const EpubReaderSelectionEnded();
}

class EpubReaderSelectionCancelled extends EpubReaderMessage {
  const EpubReaderSelectionCancelled();
}

class EpubReaderSelectionCopyRequested extends EpubReaderMessage {
  const EpubReaderSelectionCopyRequested();
}

class EpubReaderHighlightRequested extends EpubReaderMessage {
  const EpubReaderHighlightRequested(this.color);

  final ReaderHighlightColor color;
}

class EpubReaderHighlightDeleted extends EpubReaderMessage {
  const EpubReaderHighlightDeleted(this.id);

  final String id;
}

class EpubReaderLinkActivated extends EpubReaderMessage {
  const EpubReaderLinkActivated(this.href);

  final String href;
}

class EpubReaderNoticeDismissed extends EpubReaderMessage {
  const EpubReaderNoticeDismissed();
}

class EpubReaderDisposed extends EpubReaderMessage {
  const EpubReaderDisposed();
}

// ---------------------------------------------------------------------------
// Effect completions
// ---------------------------------------------------------------------------

class EpubReaderDocumentLoaded extends EpubReaderMessage {
  const EpubReaderDocumentLoaded({
    required this.generation,
    required this.book,
    required this.images,
    required this.embeddedFamilies,
    required this.elapsedMicros,
    this.storedPosition,
  });

  final int generation;
  final EpubBook book;
  final Map<String, ui.Image> images;
  final Map<String, String> embeddedFamilies;
  final EpubStoredPosition? storedPosition;
  final int elapsedMicros;
}

class EpubReaderOpenFailed extends EpubReaderMessage {
  const EpubReaderOpenFailed({required this.generation, required this.error});

  final int generation;
  final String error;
}

/// A partial layout install: the requested location is usable, but the
/// chapter is not fully measured yet. Totals are partial, never fabricated.
class EpubReaderLayoutProgressed extends EpubReaderMessage {
  const EpubReaderLayoutProgressed({
    required this.generation,
    required this.revision,
    required this.spine,
    required this.flow,
    required this.paginated,
    required this.elapsedMicros,
  });

  final int generation;
  final int revision;
  final int spine;
  final ChapterFlow flow;
  final PaginatedChapter? paginated;
  final int elapsedMicros;
}

class EpubReaderLayoutCompleted extends EpubReaderMessage {
  const EpubReaderLayoutCompleted({
    required this.generation,
    required this.revision,
    required this.spine,
    required this.flow,
    required this.paginated,
    required this.elapsedMicros,
  });

  final int generation;
  final int revision;
  final int spine;
  final ChapterFlow flow;
  final PaginatedChapter? paginated;
  final int elapsedMicros;
}
