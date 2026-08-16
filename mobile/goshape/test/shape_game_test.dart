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
      for (final p in profiles) p: ProfileAnalysis(policy, encodeLine(pos), 0.5),
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
    return PolicyData(data, posLen, pos.boardSize);
  }
}

PolicyData passHeavy(GoPosition pos) {
  final data = Float32List(posLen * posLen + 1);
  data[posLen * posLen] = 1.0; // pass dominates
  data[0] = 0.001; // one legal alternative, below min_p
  return PolicyData(data, posLen, pos.boardSize);
}

ShapeGame newGame(FakeAnalyzer fake, {bool autoplay = false}) {
  final g = ShapeGame(fake, boardSize: 9, random: Random(1));
  g.autoplayOpponent = autoplay;
  return g;
}

void main() {
  test('branching discards analyses for the abandoned continuation', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.start();

    await g.playAt(2, 2);
    await g.playAt(4, 4);
    await g.playAt(6, 6);
    expect(g.line.length, 3);
    expect(g.analyses.keys.toSet(), {0, 1, 2, 3});

    await g.goFirst();
    expect(g.cursor, 0);

    // A different first move: everything after the branch point is a different game.
    await g.playAt(8, 8);
    expect(g.line.length, 1);

    expect(g.analyses.keys.where((k) => k > 1), isEmpty,
        reason: 'analyses past the branch point must be dropped');

    // Every surviving analysis must describe the line we are actually on.
    for (final entry in g.analyses.entries) {
      final expected = encodeLine(_replay(g, entry.key));
      for (final a in entry.value.values) {
        expect(a.lead, expected, reason: 'stale analysis cached at ${entry.key}');
      }
    }
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
    // Each profile is a ~250ms net call on a phone, so the per-position sets are
    // deliberately minimal: the transient position while the opponent replies only
    // needs the opponent's policy and the reference lead, and persistent positions
    // never need the opponent's policy at all.
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
    // The opponent replies at once, so keying feedback off "the move that produced
    // this position" left the card empty for the whole of the player's turn.
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

/// Rebuild the position after [n] moves of the game's current line.
GoPosition _replay(ShapeGame g, int n) {
  final p = GoPosition(g.boardSize, Rules.japanese);
  for (var i = 0; i < n; i++) {
    p.play(g.line[i].pla, g.line[i].loc);
  }
  return p;
}
