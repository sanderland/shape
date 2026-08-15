// Drives the whole game loop against a fake analyzer: no model, no ONNX, no device.
//
// Covers the two things that went wrong in review -- stale analyses surviving a
// branch, and an opponent that could never pass -- plus the caching claim that
// browsing history does no work.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shape_slice/engine/analysis.dart';
import 'package:shape_slice/engine/board.dart';
import 'package:shape_slice/engine/features.dart';
import 'package:shape_slice/game/shape_game.dart';

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

  /// Policy to hand back; defaults to a flat board policy with no pass.
  PolicyData Function(GoPosition pos)? policyFor;

  @override
  Future<Map<String, ProfileAnalysis>> analyze(
      GoPosition pos, List<String> profiles) async {
    calls += 1;
    analyzedMoveCounts.add(pos.moves.length);
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

  test('hints off evaluates only the opponent profile', () async {
    final fake = FakeAnalyzer();
    final g = newGame(fake);
    await g.setHints(false);
    expect(g.activeProfiles, [g.opponentRank]);
    expect(g.feedback, isNull);

    await g.setHints(true);
    expect(g.activeProfiles.length, greaterThan(1));
    expect(g.activeProfiles, contains(kReferenceProfile));
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
}

/// Rebuild the position after [n] moves of the game's current line.
GoPosition _replay(ShapeGame g, int n) {
  final p = GoPosition(g.boardSize, Rules.japanese);
  for (var i = 0; i < n; i++) {
    p.play(g.line[i].pla, g.line[i].loc);
  }
  return p;
}
