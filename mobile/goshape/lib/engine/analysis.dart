// The on-device engine -- featurize, run the human-SL net, hand back policies --
// and PolicyData, a port of the top_k/top_p/min_p sampler in SHAPE's game_logic.py
// that the opponent plays from.

import 'dart:math' as math;
import 'dart:typed_data';

import 'board.dart';
import 'features.dart';
import 'net.dart';
import 'reference.dart';
import '../sgf_metadata.dart';

/// A move suggestion: board coords (null == pass) with its probability.
class PolicyMove {
  final int? x;
  final int? y;
  final double prob;
  const PolicyMove(this.x, this.y, this.prob);
  bool get isPass => x == null;
}

/// Policy over a posLen x posLen grid plus pass, as the net emits it.
class PolicyData {
  final Float32List data; // posLen*posLen + 1
  final int posLen;
  final int boardSize;
  late final double maxProb;

  PolicyData(this.data, this.posLen, this.boardSize) {
    var m = 0.0;
    for (final v in data) {
      if (v > m) m = v;
    }
    maxProb = m;
  }

  double get passProb => data[posLen * posLen];

  double probAt(int x, int y) => data[y * posLen + x];

  /// prob and prob relative to the best move, as SHAPE's `PolicyData.at` returns.
  (double, double) at(int? x, int? y) {
    final p = (x == null || y == null) ? passProb : probAt(x, y);
    return (p, maxProb > 0 ? p / maxProb : 0.0);
  }

  /// SHAPE's sampler: sort descending, cut by min_p / top_k / top_p.
  List<PolicyMove> sample({
    int topK = 10000,
    double topP = 1e9,
    double minP = 0.0,
    bool excludePass = true,
  }) {
    final moves = <PolicyMove>[];
    for (var y = 0; y < boardSize; y++) {
      for (var x = 0; x < boardSize; x++) {
        final p = probAt(x, y);
        if (p > 0) moves.add(PolicyMove(x, y, p));
      }
    }
    if (passProb > 0 && !excludePass) moves.add(PolicyMove(null, null, passProb));
    if (moves.isEmpty) return const [];

    moves.sort((a, b) => b.prob.compareTo(a.prob));
    final highest = moves.first.prob;

    final top = <PolicyMove>[];
    var total = 0.0;
    for (var i = 0; i < moves.length; i++) {
      if (moves[i].prob < minP * highest) return top;
      top.add(moves[i]);
      total += moves[i].prob;
      if (i + 1 == topK) return top;
      if (total >= topP) return top;
    }
    return top;
  }

  /// Weighted pick, as SHAPE's opponent does with np.random.choice.
  PolicyMove? pick(List<PolicyMove> candidates, math.Random rng) {
    if (candidates.isEmpty) return null;
    final total = candidates.fold<double>(0.0, (a, m) => a + m.prob);
    if (total <= 0) return null;
    var r = rng.nextDouble() * total;
    for (final m in candidates) {
      r -= m.prob;
      if (r <= 0) return m;
    }
    return candidates.last;
  }
}

/// One profile's evaluation of one position.
class ProfileAnalysis {
  final PolicyData policy;
  final double lead; // score lead for the side to move, from the net's value head
  final double winrate;
  ProfileAnalysis(this.policy, this.lead, this.winrate);
}

/// What the game loop needs from an engine. Lets tests drive the whole loop --
/// navigation, cache invalidation, opponent sampling -- without a 107 MB model.
abstract class Analyzer {
  String get provider;
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles);
}

/// Runs the human-SL net on device.
class ShapeEngine implements Analyzer {
  final NetRunner runner;
  final Features features;
  final int posLen;

  ShapeEngine(this.runner, {this.posLen = 19}) : features = Features(posLen);

  @override
  String get provider => runner.label;

  /// Load the net and refuse to run on a device that computes it wrongly.
  ///
  /// The check costs one evaluation at startup and is worth it: a net that is
  /// quietly wrong produces feedback that looks entirely plausible and is not,
  /// which is worse than not starting.
  static Future<ShapeEngine> load({int posLen = 19}) async {
    final engine = ShapeEngine(await MnnRunner.load(), posLen: posLen);
    final check = await engine.verifyAgainstReference();
    if (!check.ok) {
      await engine.close();
      throw StateError('the net does not compute correctly on this device: $check');
    }
    return engine;
  }

  /// Does this device reproduce what the desktop export produced?
  Future<ReferenceCheck> verifyAgainstReference() async {
    final ref = await ReferencePosition.load();
    final out = await runner.run(ref.bin, ref.global, ref.meta);
    return ref.check(out.policy);
  }

  /// Evaluate [pos] under each of [profiles].
  ///
  /// One net call per profile. The board features are identical across them --
  /// only the 192-wide metadata row differs -- so featurization happens once, but
  /// the forward passes cannot be merged: batching measured slower on every
  /// runtime tried, and MNN's input shapes are pinned to a single row.
  @override
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles) async {
    final f = features.fillRowFeatures(pos);
    final boardArea = pos.boardSize * pos.boardSize;
    final out = <String, ProfileAnalysis>{};
    for (final profile in profiles) {
      final meta = getProfile(profile).getMetadataRow(pos.nextPlayer, boardArea);
      final o = await runner.run(f.bin, f.global, meta);
      out[profile] = ProfileAnalysis(
        PolicyData(o.policy, posLen, pos.boardSize),
        o.lead,
        o.winrate,
      );
    }
    return out;
  }

  Future<void> close() => runner.close();
}

/// Board coords -> loc, or null if the coordinates are off the board.
int? coordsToLoc(Board b, int x, int y) {
  if (x < 0 || y < 0 || x >= b.xSize || y >= b.ySize) return null;
  return b.loc(x, y);
}
