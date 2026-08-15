// Pins the move-labelling rule against desktop SHAPE's should_halt_on_mistake
// (shape/ui/tab_config.py): a big loss is only flagged when the move is either
// unlike your target rank or one almost nobody plays. A costly move your target
// rank would also play is level-appropriate, not a blunder.

import 'package:flutter_test/flutter_test.dart';
import 'package:shape_slice/game/shape_game.dart';

MoveFeedback fb({
  required double playerProb,
  required double targetProb,
  required double? pointsLost,
}) {
  final mlt = targetProb / ((playerProb + targetProb).clamp(1e-10, double.infinity));
  return MoveFeedback(
    x: 3,
    y: 3,
    playerProb: playerProb,
    playerRel: 1.0,
    targetProb: targetProb,
    targetRel: 1.0,
    moveLikeTarget: mlt,
    pointsLost: pointsLost,
  );
}

void main() {
  test('costly and unlike the target rank is a mistake', () {
    // target 1% vs player 20% -> moveLikeTarget ~4.8%, under the 20% gate
    final f = fb(playerProb: 0.20, targetProb: 0.01, pointsLost: 4.0);
    expect(f.costly, isTrue);
    expect(f.moveLikeTarget, lessThan(kTargetRankThreshold));
    expect(f.verdict, MoveVerdict.mistake);
  });

  test('costly but the target rank would play it too is NOT flagged', () {
    // This is the SHAPE philosophy: don't scold a player for a mistake their
    // target rank makes as well.
    final f = fb(playerProb: 0.10, targetProb: 0.30, pointsLost: 4.0);
    expect(f.costly, isTrue);
    expect(f.moveLikeTarget, greaterThan(kTargetRankThreshold));
    expect(f.verdict, isNot(MoveVerdict.mistake));
  });

  test('costly and rare is a mistake even if the ratio looks fine', () {
    // Both ranks under 1%: nobody plays this, so the ratio is meaningless.
    final f = fb(playerProb: 0.001, targetProb: 0.003, pointsLost: 3.0);
    expect(f.isRare, isTrue);
    expect(f.moveLikeTarget, greaterThan(kTargetRankThreshold));
    expect(f.verdict, MoveVerdict.mistake);
  });

  test('cheap move the target prefers is above your level', () {
    final f = fb(playerProb: 0.02, targetProb: 0.30, pointsLost: 0.2);
    expect(f.verdict, MoveVerdict.aboveYourLevel);
  });

  test('cheap move your own rank prefers is typical', () {
    final f = fb(playerProb: 0.30, targetProb: 0.05, pointsLost: 0.2);
    expect(f.verdict, MoveVerdict.typical);
  });

  test('a gain is never costly', () {
    final f = fb(playerProb: 0.05, targetProb: 0.02, pointsLost: -1.6);
    expect(f.costly, isFalse);
    expect(f.verdict, MoveVerdict.typical);
  });

  test('missing score data does not manufacture a mistake', () {
    final f = fb(playerProb: 0.01, targetProb: 0.001, pointsLost: null);
    expect(f.costly, isFalse);
    expect(f.verdict, isNot(MoveVerdict.mistake));
  });

  test('threshold constants match desktop SHAPE defaults', () {
    expect(kMistakeSizePoints, 1.0); // mistake_size_spinbox
    expect(kTargetRankThreshold, 0.20); // target_rank_spinbox / 100
    expect(kMaxProbThreshold, 0.01); // max_probability_spinbox / 100
  });
}
