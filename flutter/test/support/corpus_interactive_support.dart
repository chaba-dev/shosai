/// Pure decision helpers for the real-book interactive corpus harness.
///
/// Extracted from `integration_test/epub_real_corpus_reader_test.dart` so the
/// arrival and turn-sample classifications have their own discriminating
/// tests (`test/corpus/corpus_interactive_support_test.dart`): a stale
/// relayout-failure banner must never be read as a jump's outcome, a
/// fresh banner is a failure (not an arrival), and a page-turn sample counts
/// only when the key event moved the painted page.
library;

/// One step of the contents-jump arrival decision.
///
/// [paintedUnit] is the currently painted page's 0-based chapter unit (null
/// on the retained path), [semanticsUnit] the semantics label's 1-based
/// chapter number, [bannerVisible] whether the relayout-failure banner is
/// visible now, and [bannerBeforeJump] whether it was already visible before
/// the jump was tapped. [targetUnit] is the tapped row's 0-based unit.
CorpusJumpStep classifyJumpArrivalStep({
  required int? targetUnit,
  required int? paintedUnit,
  required int? semanticsUnit,
  required bool bannerVisible,
  required bool bannerBeforeJump,
}) {
  if (paintedUnit != null && paintedUnit == targetUnit) {
    return CorpusJumpStep.arrived;
  }
  if (paintedUnit == null &&
      semanticsUnit != null &&
      targetUnit != null &&
      semanticsUnit == targetUnit + 1) {
    return CorpusJumpStep.arrived;
  }
  if (bannerVisible && !bannerBeforeJump) {
    return CorpusJumpStep.layoutFailed;
  }
  return CorpusJumpStep.pending;
}

/// Whether the tapped Contents row targets the chapter already current, so
/// the run records "already at target" instead of claiming an arrival.
///
/// [currentUnitBefore] must be the normalized 0-based current chapter on
/// either path: the Dart page's painted unit, or the retained path's 1-based
/// semantics label minus one (the retained path installs the unit and the
/// page image together, so the label is its completion signal).
bool jumpTargetsCurrentUnit({
  required int? targetUnit,
  required int? currentUnitBefore,
}) => targetUnit != null && targetUnit == currentUnitBefore;

/// Whether a page-turn sample qualifies as a measurement: it must have
/// produced frames and moved the painted page (chapter unit + page index).
/// A sample with no frame, an unknown position, or an unchanged position is
/// rejected rather than measured.
bool turnSampleQualifies({
  required int frameCount,
  required (int, int)? positionBefore,
  required (int, int)? positionAfter,
}) =>
    frameCount > 0 &&
    positionBefore != null &&
    positionAfter != null &&
    positionBefore != positionAfter;

enum CorpusJumpStep { pending, arrived, layoutFailed }
