// Pins the exact wording of the card, because the wording is the product here and
// a screenshot on a device cannot be diffed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/feedback_card.dart';
import 'package:goshape/game/shape_game.dart';

MoveFeedback fb({
  required double playerProb,
  required double targetProb,
  required double? pointsLost,
}) =>
    MoveFeedback(
      x: 3,
      y: 15,
      playerProb: playerProb,
      playerRel: 1.0,
      targetProb: targetProb,
      targetRel: 0.5,
      moveLikeTarget: posteriorLikeTarget(playerProb, targetProb),
      pointsLost: pointsLost,
    );

Future<void> show(WidgetTester tester, MoveFeedback? f) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackCard(
            feedback: f,
            playerRank: 'rank_5k',
            targetRank: 'rank_2d',
            boardSize: 19,
          ),
        ),
      ),
    );

void main() {
  testWidgets('a mistake leads with what it cost', (tester) async {
    await show(tester, fb(playerProb: 0.20, targetProb: 0.01, pointsLost: 3.2));
    expect(find.text('D4 · Lost 3.2 points'), findsOneWidget);
    // The cost is in the headline, so it must not be repeated underneath.
    expect(find.textContaining('pts'), findsNothing);
  });

  testWidgets('a costly move the target plays says both things at once',
      (tester) async {
    await show(tester, fb(playerProb: 0.10, targetProb: 0.30, pointsLost: 2.3));
    expect(find.text('D4 · Lost 2.3 points, but 2d plays it too'), findsOneWidget);
  });

  testWidgets('the excuse is dropped when the target barely plays it',
      (tester) async {
    await show(tester, fb(playerProb: 0.06, targetProb: 0.016, pointsLost: 2.0));
    expect(find.text('D4 · Lost 2.0 points'), findsOneWidget);
    expect(find.textContaining('plays it too'), findsNothing);
  });

  testWidgets('praise claims a comparison, not a rank', (tester) async {
    await show(tester, fb(playerProb: 0.05, targetProb: 0.30, pointsLost: 0.2));
    expect(find.text('D4 · More 2d than 5k'), findsOneWidget);
    // "Above your level -- a 2d move" asserted the move belonged to one rank, and
    // read as nonsense whenever the target was set below the player's own rank.
    expect(find.textContaining('Above your level'), findsNothing);
  });

  testWidgets('the fallback bucket admits it is one', (tester) async {
    await show(tester, fb(playerProb: 0.30, targetProb: 0.20, pointsLost: 0.2));
    expect(find.text('D4 · Nothing to flag'), findsOneWidget);
    expect(find.textContaining('Typical'), findsNothing);
  });

  testWidgets('a move neither rank plays is called rare, not typical',
      (tester) async {
    await show(tester, fb(playerProb: 0.002, targetProb: 0.003, pointsLost: 0.1));
    expect(find.text('D4 · Rare at both ranks'), findsOneWidget);
  });

  testWidgets('bars are labelled by rank alone', (tester) async {
    await show(tester, fb(playerProb: 0.05, targetProb: 0.30, pointsLost: 0.2));
    expect(find.text('5k'), findsOneWidget);
    expect(find.text('2d'), findsOneWidget);
    expect(find.textContaining('would play this'), findsNothing);
    // The posterior was a number derived from the two beside it.
    expect(find.textContaining('Looks like'), findsNothing);
  });

  testWidgets('the empty state says what will appear, not what Go is',
      (tester) async {
    await show(tester, null);
    expect(find.textContaining('Feedback appears here after you move'), findsOneWidget);
    expect(find.textContaining('Welcome'), findsNothing);
  });

  noticeTests();

  test('every verdict has its own colour, so the ring identifies the move', () {
    // The board rings the discussed move in this colour and the card is headed in
    // it; two verdicts sharing one would make the pairing ambiguous.
    final colors = MoveVerdict.values.map(verdictColor).toSet();
    expect(colors.length, MoveVerdict.values.length);
  });

  testWidgets('the card is headed in the same colour the board rings with',
      (tester) async {
    final f = fb(playerProb: 0.20, targetProb: 0.01, pointsLost: 3.2);
    await show(tester, f);
    final headline = tester.widget<Text>(find.text('D4 · Lost 3.2 points'));
    expect(headline.style?.color, verdictColor(f.verdict));
  });
}

Future<void> showNotice(
  WidgetTester tester, {
  bool gameOver = false,
  bool opponentPassed = false,
  double? score,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GameNotice(
          gameOver: gameOver,
          opponentPassed: opponentPassed,
          opponentRank: 'rank_1k',
          scoreLeadForBlack: score,
        ),
      ),
    ));

void noticeTests() {
  test('score is labelled by who is ahead, not by who is to move', () {
    expect(GameNotice.scoreLabel(12.5), 'B+12.5');
    expect(GameNotice.scoreLabel(-3.2), 'W+3.2');
    expect(GameNotice.scoreLabel(0), 'B+0.0');
    expect(GameNotice.scoreLabel(null), isNull);
  });

  testWidgets('a pass is announced, because it puts no stone on the board',
      (tester) async {
    await showNotice(tester, opponentPassed: true);
    expect(find.text('1k passed'), findsOneWidget);
    expect(find.text('Pass again to end the game.'), findsOneWidget);
  });

  testWidgets('game over leads with the score', (tester) async {
    await showNotice(tester, gameOver: true, score: 12.5);
    expect(find.text('Game over · B+12.5'), findsOneWidget);
    // The lead head has no search behind it; the card must not imply otherwise.
    expect(find.textContaining('without search'), findsOneWidget);
  });

  testWidgets('game over without an estimate still says the game is over',
      (tester) async {
    await showNotice(tester, gameOver: true, score: null);
    expect(find.text('Game over'), findsOneWidget);
  });

  testWidgets('nothing is shown when there is nothing to announce',
      (tester) async {
    await showNotice(tester);
    expect(find.byType(Card), findsNothing);
  });
}
