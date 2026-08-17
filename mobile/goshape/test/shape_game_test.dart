// Drives the whole game loop against a fake analyzer: no model, no device.
//
// Covers branching (analyses must not survive a discarded line), the opponent's
// ability to pass, feedback and review, and the claim that browsing history is a
// pure cache hit.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/engine/analysis.dart';
import 'package:goshape/engine/board.dart';
import 'package:goshape/engine/features.dart';
import 'package:goshape/game/shape_game.dart';

const int posLen = 19;

/// Deterministic stand-in: `lead` encodes the exact move sequence it saw, so a
/// cached analysis belonging to a discarded line is detectable.
double encodeLine(GoPosition pos) {
  var h = 0.0;
  for (final m in pos.moves) {
    h = h * 31 + m.loc;
  }
  return h;
}

class FakeAnalyzer implements Analyzer {
  @override
  String get provider => 'fake';

  int calls = 0;
  final List<int> analyzedMoveCounts = [];
  final List<List<String>> analyzedProfiles = [];
  Completer<void>? blockNextAnalysis;

  /// Start throwing once this many calls have been made, to model a runtime that
  /// works at startup and then stops.
  int? failFrom;

  /// Policy to hand back; defaults to a flat board policy with no pass.
  PolicyData Function(GoPosition pos)? policyFor;

  /// Per-profile override, so a move can look different to two ranks -- which is
  /// the only way anything can be a mistake.
  ProfileAnalysis Function(String profile, GoPosition pos)? overrideFor;

  @override
  Future<Map<String, ProfileAnalysis>> analyze(
      GoPosition pos, List<String> profiles) async {
    final blocker = blockNextAnalysis;
    blockNextAnalysis = null;
    if (blocker != null) await blocker.future;
    final limit = failFrom;
    if (limit != null && calls >= limit) throw StateError('engine went away');
    calls += 1;
    analyzedMoveCounts.add(pos.moves.length);
    analyzedProfiles.add(List.of(profiles));
    final policy = policyFor?.call(pos) ?? _flat(pos);
    return {
      for (final p in profiles)
        p: overrideFor?.call(p, pos) ??
            ProfileAnalysis(policy, encodeLine(pos)),
    };
  }

  PolicyData _flat(GoPosition pos) {
    final data = Float32List(posLen * posLen + 1);
    // Prefer empty points, descending so the choice is deterministic under any rng.
    var v = 1.0;
    for (var y = 0; y < pos.boardSize; y++) {
      for (var x = 0; x < pos.boardSize; x++) {
        if (pos.board.board[pos.board.loc(x, y)] == Board.empty) {
          data[y * posLen + x] = v;
          v *= 0.99;
        }
      }
    }
    return PolicyData(data, posLen, pos.board);
  }
}

/// Every point equally likely.
PolicyData flatHalf(GoPosition pos) {
  final d = Float32List(posLen * posLen + 1);
  for (var y = 0; y < 9; y++) {
    for (var x = 0; x < 9; x++) {
      d[y * posLen + x] = 0.5;
    }
  }
  return PolicyData(d, posLen, pos.board);
}

/// Same, except the diagonal is never played -- where the test puts every move.
PolicyData avoidsDiagonal(GoPosition pos) {
  final d = Float32List(posLen * posLen + 1);
  for (var y = 0; y < 9; y++) {
    for (var x = 0; x < 9; x++) {
      d[y * posLen + x] = x == y ? 0.0 : 0.5;
    }
  }
  return PolicyData(d, posLen, pos.board);
}

PolicyData passHeavy(GoPosition pos) {
  final data = Float32List(posLen * posLen + 1);
  data[posLen * posLen] = 1.0; // pass dominates
  data[0] = 0.001; // one legal alternative, below min_p
  return PolicyData(data, posLen, pos.board);
}

ShapeGame newGame(FakeAnalyzer fake, {bool autoplay = false}) {
  final g = ShapeGame(fake, boardSize: 9, random: Random(1));
  g.autoplayOpponent = autoplay;
  return g;
}

void main() {
  test('branching keeps the old continuation as a variation', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();

    await g.playAt(2, 2);
    await g.playAt(4, 4);
    await g.playAt(6, 6);
    expect(g.line.length, 3);
    final original = g.current;

    await g.goFirst();
    expect(g.cursor, 0);

    // A different first move branches rather than deleting what was there.
    await g.playAt(8, 8);
    expect(g.line.length, 1);
    expect(g.root.children.length, 2, reason: 'two first moves now exist');

    // The abandoned line is still whole, still reachable, still analysed.
    var n = g.root.children.first;
    expect(n.path.map((m) => g.pos.board.locX(m.loc)), [2]);
    expect(n.endOfMainLine.depth, 3);
    expect(identical(n.endOfMainLine, original), isTrue);
    expect(n.analyses, isNotEmpty, reason: 'its evaluations survive too');

    // And every node still describes its own line, not a neighbour's.
    for (final node in [g.root, ...g.root.children]) {
      for (final a in node.analyses.values) {
        expect(a.lead, encodeLine(_replayNode(g, node)));
      }
    }
  });

  test('replaying a move you already explored returns to it, cache and all',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();
    await g.playAt(2, 2);
    final first = g.current;

    await g.goFirst();
    final callsBefore = fake.calls;
    await g.playAt(2, 2);

    expect(identical(g.current, first), isTrue, reason: 'same node, not a duplicate');
    expect(g.root.children.length, 1);
    expect(fake.calls, callsBefore, reason: 'its analyses were already there');
  });

  test('replaying an explored move lets the opponent follow its known reply',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    await g.start();
    await g.playAt(2, 2);
    expect(g.cursor, 2, reason: 'your move and their reply');
    final reply = g.current;

    await g.goFirst();
    final callsBefore = fake.calls;
    await g.playAt(2, 2);

    expect(identical(g.current, reply), isTrue,
        reason: 'the reply is already in the tree and should be resumed');
    expect(g.cursor, 2);
    expect(g.humanToPlay, isTrue,
        reason: 'otherwise the board is dead until Forward is pressed by hand');
    expect(fake.calls, callsBefore, reason: 'all of it was cached');
    expect(reply.parent!.children.length, 1,
        reason: 'resampling would invent a second answer to one position');

    // And play carries on from there.
    await g.playAt(4, 4);
    expect(g.cursor, 4);
  });

  test('the sgf carries the variations, not just the line you ended on', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();
    await g.playAt(2, 2);
    await g.goFirst();
    await g.playAt(8, 8);

    final sgf = g.toSgf();
    // Both first moves must be present, each in its own parenthesised variation.
    expect(sgf, contains(';B[cc]'));
    expect(sgf, contains(';B[ii]'));
    expect('('.allMatches(sgf).length, greaterThan(1));
  });

  test('browsing history does no analysis work', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();
    await g.playAt(2, 2);
    await g.playAt(4, 4);
    await g.playAt(6, 6);

    final before = fake.calls;
    await g.goFirst();
    await g.goLast();
    await g.goPrev();
    await g.goNext();
    expect(fake.calls, before, reason: 'navigation should be a pure cache hit');
  });

  test('board-only navigation steps one move at a time', () async {
    final g = ShapeGame(null, boardSize: 9);
    await g.start();
    await g.playAt(2, 2);
    await g.playAt(4, 4);
    await g.playAt(6, 6);

    await g.goPrev();
    expect(g.cursor, 2);
    await g.goNext();
    expect(g.cursor, 3);
  });

  test('opponent can pass', () async {
    final fake = FakeAnalyzer()..policyFor = (pos) => passHeavy(pos);
    final g = newGame(fake, autoplay: true);
    await g.start();

    await g.playAt(2, 2);

    expect(g.line.length, greaterThanOrEqualTo(2));
    expect(g.line.last.isPass, isTrue,
        reason: 'without an AI net, sampling is the only way the opponent can pass');
  });

  test('two passes end the game', () async {
    final fake = FakeAnalyzer()..policyFor = (pos) => passHeavy(pos);
    final g = newGame(fake, autoplay: true);
    await g.start();

    await g.pass(); // human passes; opponent samples a pass in reply
    expect(g.gameOver, isTrue);
  });

  test('feedback and heatmap are independent, and each costs evals', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);

    // Everything off: only the profile behind the score estimate, which is always
    // shown and so is never optional.
    await g.setFeedbackMode(FeedbackMode.off);
    await g.setHeatmapMode(HeatmapMode.off);
    expect(g.activeProfiles, [kReferenceProfile]);
    expect(g.feedback, isNull);

    // Heatmap alone pulls in exactly the painted profile, not the feedback set.
    await g.setHeatmapMode(HeatmapMode.target);
    expect(g.activeProfiles.toSet(), {kReferenceProfile, g.targetRank});

    await g.setHeatmapMode(HeatmapMode.yourRank);
    expect(g.activeProfiles.toSet(), {kReferenceProfile, g.playerRank});

    // Feedback alone needs player + target + the score reference, heatmap or not.
    await g.setHeatmapMode(HeatmapMode.off);
    await g.setFeedbackMode(FeedbackMode.all);
    expect(g.activeProfiles.toSet(),
        {g.playerRank, g.targetRank, kReferenceProfile});

    // Mistakes-only is a display choice: it cannot be cheaper, since you must
    // evaluate a move to learn whether it was a mistake.
    final withAll = g.activeProfiles.toSet();
    await g.setFeedbackMode(FeedbackMode.mistakesOnly);
    expect(g.activeProfiles.toSet(), withAll);
  });

  test('a full exchange evaluates 2 + 3 profiles, not 4 + 4', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    await g.start();
    expect(fake.analyzedProfiles.single.toSet(),
        {g.playerRank, g.targetRank, kReferenceProfile});

    fake.analyzedProfiles.clear();
    await g.playAt(2, 2); // human plays; opponent autoplay replies
    expect(g.line.length, 2);
    expect(fake.analyzedProfiles.first.toSet(), {g.opponentRank, kReferenceProfile},
        reason: 'transient position: sampling policy + reference lead only');
    expect(fake.analyzedProfiles.last.toSet(),
        {g.playerRank, g.targetRank, kReferenceProfile},
        reason: 'after the reply: heatmap/feedback profiles + reference lead');
    expect(fake.analyzedProfiles.expand((p) => p).length, 5,
        reason: 'a full exchange must cost 5 profile evals');
  });

  test('review jumps to the position before your last move, not the reply',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    await g.start();
    await g.playAt(2, 2); // your move at index 0; opponent replies at index 1
    expect(g.line.length, 2);
    expect(g.cursor, 2);

    await g.setHeatmapMode(HeatmapMode.off);
    await g.toggleReview();

    expect(g.cursor, 0, reason: 'should land on the position you faced');
    expect(g.heatmapMode, HeatmapMode.target,
        reason: 'the point of the button is to show the target policy');
    expect(g.analysisFor(g.targetRank), isNotNull);
  });

  test('review toggles back to where it was, heatmap included', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    await g.start();
    await g.playAt(2, 2);
    await g.setHeatmapMode(HeatmapMode.yourRank);
    final cursorBefore = g.cursor;

    await g.toggleReview();
    expect(g.reviewing, isTrue);
    expect(g.cursor, 0);
    expect(g.heatmapMode, HeatmapMode.target);

    await g.toggleReview();
    expect(g.reviewing, isFalse);
    expect(g.cursor, cursorBefore, reason: 'should return to the live position');
    expect(g.heatmapMode, HeatmapMode.yourRank,
        reason: 'the heatmap setting was borrowed, not replaced');
  });

  test('ordinary navigation leaves review rather than stranding it', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    await g.start();
    await g.playAt(2, 2);
    await g.toggleReview();
    expect(g.reviewing, isTrue);

    await g.goLast();
    expect(g.reviewing, isFalse);
  });

  test('feedback describes your move while the opponent is to blame for the position',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.all;
    await g.start();
    await g.playAt(2, 2);

    expect(g.line.length, 2, reason: 'opponent has replied');
    expect(g.cursor, 2);
    expect(g.feedback, isNotNull, reason: 'still describing your move, not theirs');
    expect((g.feedback!.x, g.feedback!.y), (2, 2));
  });

  test('turning feedback on describes the move already played', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.off;
    await g.start();
    await g.playAt(2, 2);
    expect(g.feedback, isNull);

    await g.setFeedbackMode(FeedbackMode.all);
    expect(g.feedback, isNotNull,
        reason: 'no further move should be needed to get feedback');
    expect((g.feedback!.x, g.feedback!.y), (2, 2));
  });

  test('a new game can change the board size', () async {
    // The net is 19x19 whatever the board is, so a 9x9 game must still produce
    // moves inside 9x9 rather than anywhere in the tensor.
    final fake = FakeAnalyzer();
    final g = ShapeGame(fake, boardSize: 19, random: Random(1))..autoplayOpponent = true;
    await g.start();
    await g.playAt(2, 2);
    expect(g.boardSize, 19);

    await g.newGame(size: 9);
    expect(g.boardSize, 9);
    expect(g.pos.boardSize, 9);
    expect(g.line, isEmpty);

    await g.playAt(4, 4);
    await g.playAt(0, 0);
    for (final m in g.line.where((m) => !m.isPass)) {
      expect(g.pos.board.locX(m.loc), lessThan(9));
      expect(g.pos.board.locY(m.loc), lessThan(9));
    }
    expect(g.toSgf(), contains('SZ[9]'));
  });

  test('without an engine the board still works', () async {
    final g = ShapeGame(null, boardSize: 9, random: Random(1))
      ..engineError = 'no engine here';
    await g.start();

    // You place both colours yourself, since nothing is there to reply.
    await g.playAt(2, 2);
    await g.playAt(4, 4);
    expect(g.line.length, 2);
    expect(g.pos.board.board[g.pos.board.loc(2, 2)], Board.black);
    expect(g.pos.board.board[g.pos.board.loc(4, 4)], Board.white);

    expect(g.hasEngine, isFalse);
    expect(g.feedback, isNull);
    expect(g.error, isNull, reason: 'a missing engine is not a per-move error');

    // Illegal moves are still refused, and navigation still works.
    await g.playAt(2, 2);
    expect(g.error, isNotNull);
    await g.goFirst();
    expect(g.cursor, 0);
  });

  test('an engine that starts failing degrades instead of erroring every move',
      () async {
    final fake = FakeAnalyzer()..failFrom = 2;
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.all;
    await g.start();
    expect(g.hasEngine, isTrue);

    await g.playAt(2, 2);
    expect(g.hasEngine, isFalse, reason: 'one failure is enough to stop asking');
    expect(g.engineError, contains('inference failed'));

    final callsAfterFailure = fake.calls;
    await g.playAt(4, 4);
    expect(fake.calls, callsAfterFailure, reason: 'must not keep retrying');
    expect(g.line.length, 3, reason: 'stones still go down');
    expect(g.feedback, isNull);
  });

  test('the 9p heatmap reuses the profile the score already comes from', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.all;
    await g.start();
    await g.playAt(2, 2);

    final before = fake.calls;
    await g.setHeatmapMode(HeatmapMode.pro);
    expect(g.heatmapProfile, kReferenceProfile);
    expect(g.analysisFor(kReferenceProfile), isNotNull);
    expect(fake.calls, before,
        reason: 'the reference profile is already evaluated for the score');
  });

  test('a score estimate is available with feedback and heatmap both off',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.off;
    await g.setHeatmapMode(HeatmapMode.off);
    await g.start();
    await g.playAt(2, 2);

    expect(g.feedback, isNull, reason: 'feedback is off');
    expect(g.scoreLeadForBlack, isNotNull,
        reason: 'the score does not depend on having asked for feedback');
  });

  test('the opponent\'s own turn is not charged for a score nobody can read',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.off;
    await g.setHeatmapMode(HeatmapMode.off);
    await g.start();
    fake.analyzedProfiles.clear();
    await g.playAt(2, 2);

    // The position where the opponent is about to reply exists for a moment; it
    // gets the opponent's policy and nothing else.
    expect(fake.analyzedProfiles.first, [g.opponentRank]);
  });

  test('mistake navigation lands on the move the card describes', () async {
    // A move is a mistake when it costs points AND the target rank would not play
    // it, so the fake has to disagree with itself across profiles. Every point is
    // 50% to the player; the diagonal is 0% to the target. Constant lead 1.5 makes
    // pointsLost = 1.5 + 1.5 - 1 = 2, over the one-point bar.
    final fake = FakeAnalyzer();
    final g = ShapeGame(fake, boardSize: 9, random: Random(2));
    fake.overrideFor = (profile, pos) => ProfileAnalysis(
          profile == g.targetRank ? avoidsDiagonal(pos) : flatHalf(pos),
          1.5,
        );
    g.feedbackMode = FeedbackMode.all;
    g.autoplayOpponent = false;
    await g.start();

    // Alternates B/W, so your moves are the even indices, all on the diagonal.
    for (final p in const [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]) {
      await g.playAt(p.$1, p.$2);
    }

    final mistakes = g.knownMistakes;
    expect(mistakes, isNotEmpty, reason: 'the fake should produce some');
    // Only your own moves, and always in playing order.
    for (final n in mistakes) {
      expect(n.move!.pla, g.humanColor);
    }
    final depths = mistakes.map((n) => n.depth).toList();
    expect(depths, orderedEquals(depths.toList()..sort()));

    await g.goFirst();
    final first = mistakes.first;

    // Going back to the start already puts you on the first decision, since the
    // move you played from there is the one being discussed.
    expect(g.cursor, first.depth - 1,
        reason: 'the position you faced, not the one after you played');
    expect(g.humanToPlay, isTrue, reason: 'so the heatmap paints and you can move');
    expect(identical(g.describedMove, first), isTrue);
    expect(g.describedMoveIsPlayed, isFalse,
        reason: 'it is a dot on the board, not a stone');
    expect(g.nextMoves.map((n) => (n.x, n.y)),
        contains((g.feedback!.x, g.feedback!.y)),
        reason: 'the card and the dot must be the same move');
    expect(g.feedback!.isMistake, isTrue);

    // Forward then back returns to where it started.
    if (mistakes.length > 1) {
      await g.goToMistake(forward: true);
      expect(g.cursor, mistakes[1].depth - 1);
      await g.goToMistake(forward: false);
      expect(g.cursor, first.depth - 1);
    }

    await g.goLast();
    expect(g.nextMistake, isNull, reason: 'nothing ahead of the last move');
  });

  test('unevaluated moves are not counted as mistakes', () async {
    // With feedback off nothing is judged, so the arrows have nowhere to go rather
    // than freezing the app to analyse a whole game on demand.
    final fake = FakeAnalyzer();
    final g = ShapeGame(fake, boardSize: 9, random: Random(2));
    g.feedbackMode = FeedbackMode.off;
    g.autoplayOpponent = false;
    await g.start();
    await g.playAt(0, 0);
    await g.playAt(1, 1);

    expect(g.knownMistakes, isEmpty);
    expect(g.nextMistake, isNull);
    expect(g.previousMistake, isNull);
  });

  test('the board is told about every explored continuation', () async {
    final fake = FakeAnalyzer();
    final g = ShapeGame(fake, boardSize: 9, random: Random(1));
    g.autoplayOpponent = false;
    await g.start();

    expect(g.nextMoves, isEmpty, reason: 'nothing explored yet');

    await g.playAt(2, 2);
    await g.goFirst();
    expect(g.nextMoves.map((n) => (n.x, n.y)), [(2, 2)]);
    expect(g.nextMoves.single.isMainLine, isTrue);

    await g.playAt(8, 8);
    await g.goFirst();
    final shown = g.nextMoves;
    expect(shown.map((n) => (n.x, n.y)), [(2, 2), (8, 8)]);
    expect(shown.map((n) => n.isMainLine), [true, false],
        reason: 'only the first child is the line navigation follows');
  });

  test('a pass is not drawn on the board as a continuation', () async {
    final fake = FakeAnalyzer();
    final g = ShapeGame(fake, boardSize: 9, random: Random(1));
    g.autoplayOpponent = false;
    await g.start();
    await g.pass();
    await g.goFirst();

    expect(g.current.children.length, 1, reason: 'the pass is in the tree');
    expect(g.nextMoves, isEmpty, reason: 'but it has no point to draw');
  });

  test('a position you are looking at is evaluated even on the opponent\'s turn',
      () async {
    // Playing white means the opponent opens, so browsing back to the start lands
    // on a position where they are to move. Nothing is about to happen there --
    // you are looking at it -- so it needs everything a position on screen needs.
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.humanColor = Board.white;
    await g.setHeatmapMode(HeatmapMode.yourRank);
    await g.start();
    expect(g.cursor, 1, reason: 'the opponent opened');

    await g.goFirst();
    expect(g.humanToPlay, isFalse, reason: 'their turn, but on screen');
    expect(g.activeProfiles, contains(g.playerRank),
        reason: 'the heatmap you asked for must be evaluated');
    expect(g.activeProfiles, contains(kReferenceProfile),
        reason: 'and the score, which is always shown');
  });

  test('a rank changed while inference is running is still analysed', () async {
    // The pickers stay live during a refresh, so a second choice lands mid-flight.
    // It must not just update the label and be dropped.
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();

    final gate = Completer<void>();
    fake.blockNextAnalysis = gate;
    final firstChange = g.setRanks(target: 'rank_9d');
    await g.setRanks(target: 'rank_1d');
    gate.complete();
    await firstChange;

    expect(g.targetRank, 'rank_1d');
    expect(g.analysisFor('rank_1d'), isNotNull,
        reason: 'the rank actually selected was never evaluated');
  });

  test('a rank changed while a move is being analysed is picked up after',
      () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();

    final gate = Completer<void>();
    fake.blockNextAnalysis = gate;
    final move = g.playAt(2, 2);
    await g.setRanks(target: 'rank_9d');
    gate.complete();
    await move;

    expect(g.targetRank, 'rank_9d');
    expect(g.analysisFor('rank_9d'), isNotNull,
        reason: 'a change made during a move must not be lost either');
  });

  test('timing is reported per evaluation, not per analysis call', () async {
    // A position needs one net call per profile, so the total for a call says
    // nothing until you know how many it covered.
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    g.feedbackMode = FeedbackMode.all;
    await g.start();
    await g.playAt(2, 2);

    expect(g.analysisEvals, greaterThan(0));
    expect(g.analysisEvals, fake.analyzedProfiles.last.length,
        reason: 'the count must match what was actually asked of the engine');
    expect(g.msPerEval, g.analysisMs ~/ g.analysisEvals);
  });

  test('review is unavailable before you have moved', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake, autoplay: true);
    await g.start();
    expect(g.canReviewOwnMove, isFalse);
  });

  test('illegal move is rejected without corrupting the line', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();
    await g.playAt(2, 2);
    final len = g.line.length;

    await g.playAt(2, 2); // occupied
    expect(g.line.length, len);
    expect(g.error, isNotNull);
  });

  test('new game stays busy until its initial analysis finishes', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();
    await g.playAt(2, 2);

    final blocker = Completer<void>();
    fake.blockNextAnalysis = blocker;
    final reset = g.newGame();

    expect(g.busy, isTrue);
    await g.playAt(4, 4);
    expect(g.line, isEmpty,
        reason: 'moves must stay disabled during startup analysis');

    blocker.complete();
    await reset;
    expect(g.busy, isFalse);
    expect(g.line, isEmpty);
  });
}

/// Rebuild the position at [node], wherever in the tree it sits.
GoPosition _replayNode(ShapeGame g, GameNode node) {
  final p = GoPosition(g.boardSize, Rules.japanese);
  for (final m in node.path) {
    p.play(m.pla, m.loc);
  }
  return p;
}
