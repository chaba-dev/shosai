import 'package:flutter_test/flutter_test.dart';

import '../support/corpus_interactive_support.dart';

void main() {
  group('classifyJumpArrivalStep', () {
    test('a fresh failure banner is a failure, never an arrival', () {
      final step = classifyJumpArrivalStep(
        targetUnit: 5,
        paintedUnit: 4,
        semanticsUnit: 5,
        bannerVisible: true,
        bannerBeforeJump: false,
      );
      expect(step, CorpusJumpStep.layoutFailed);
    });

    test('a stale banner does not terminate a pending jump', () {
      final step = classifyJumpArrivalStep(
        targetUnit: 5,
        paintedUnit: 4,
        semanticsUnit: 5,
        bannerVisible: true,
        bannerBeforeJump: true,
      );
      expect(step, CorpusJumpStep.pending);
    });

    test('an old page is pending; the waiter must not succeed early', () {
      final step = classifyJumpArrivalStep(
        targetUnit: 10,
        paintedUnit: 4,
        semanticsUnit: 5,
        bannerVisible: false,
        bannerBeforeJump: false,
      );
      expect(step, CorpusJumpStep.pending);
    });

    test('the painted page reaching the target is an arrival', () {
      final step = classifyJumpArrivalStep(
        targetUnit: 75,
        paintedUnit: 75,
        semanticsUnit: 76,
        bannerVisible: false,
        bannerBeforeJump: false,
      );
      expect(step, CorpusJumpStep.arrived);
    });

    test('on the retained path the 1-based semantics signal decides', () {
      // Precedence pin: the retained completion signal (a semantics label at
      // the target chapter) outranks a fresh failure banner, because the
      // controller installs the unit and the page image together — a label
      // at the target is completion, not a failure state.
      expect(
        classifyJumpArrivalStep(
          targetUnit: 75,
          paintedUnit: null,
          semanticsUnit: 76,
          bannerVisible: false,
          bannerBeforeJump: false,
        ),
        CorpusJumpStep.arrived,
      );
      expect(
        classifyJumpArrivalStep(
          targetUnit: 75,
          paintedUnit: null,
          semanticsUnit: 76,
          bannerVisible: true,
          bannerBeforeJump: false,
        ),
        CorpusJumpStep.arrived,
        reason:
            'a retained completion signal outranks even a fresh relayout-'
            'failure banner, so arrival is classified first',
      );
      expect(
        classifyJumpArrivalStep(
          targetUnit: 75,
          paintedUnit: null,
          semanticsUnit: 75,
          bannerVisible: false,
          bannerBeforeJump: false,
        ),
        CorpusJumpStep.pending,
        reason:
            'a 1-based semantics number equal to the 0-based target has '
            'not reached the target unit',
      );
    });
  });

  group('jumpTargetsCurrentUnit', () {
    test('a row targeting the current chapter is not an arrival test', () {
      expect(
        jumpTargetsCurrentUnit(targetUnit: 6, currentUnitBefore: 6),
        isTrue,
      );
      expect(
        jumpTargetsCurrentUnit(targetUnit: 6, currentUnitBefore: 5),
        isFalse,
      );
      expect(
        jumpTargetsCurrentUnit(targetUnit: null, currentUnitBefore: 6),
        isFalse,
      );
    });

    test('the retained path normalizes its 1-based label before the guard', () {
      // Retained chapter label 7 == 0-based unit 6: a row targeting unit 6
      // must be classified as already-at-target by the caller's normalized
      // guard, never as a fresh arrival.
      expect(
        jumpTargetsCurrentUnit(targetUnit: 6, currentUnitBefore: 7 - 1),
        isTrue,
      );
      // And the classifier's retained rule is pinned so a wiring regression
      // cannot resurrect a false arrival for a same-target retained jump.
      expect(
        classifyJumpArrivalStep(
          targetUnit: 6,
          paintedUnit: null,
          semanticsUnit: 7,
          bannerVisible: false,
          bannerBeforeJump: false,
        ),
        CorpusJumpStep.arrived,
      );
    });
  });

  group('turnSampleQualifies', () {
    test('requires frames and a painted-position change', () {
      expect(
        turnSampleQualifies(
          frameCount: 12,
          positionBefore: (3, 4),
          positionAfter: (3, 5),
        ),
        isTrue,
      );
      expect(
        turnSampleQualifies(
          frameCount: 0,
          positionBefore: (3, 4),
          positionAfter: (3, 5),
        ),
        isFalse,
        reason: 'a no-op key event is never recorded as a turn measurement',
      );
      expect(
        turnSampleQualifies(
          frameCount: 12,
          positionBefore: (3, 4),
          positionAfter: (3, 4),
        ),
        isFalse,
        reason: 'an unchanged painted page is rejected',
      );
      expect(
        turnSampleQualifies(
          frameCount: 12,
          positionBefore: null,
          positionAfter: (3, 5),
        ),
        isFalse,
      );
    });
  });
}
