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
  final Uint8List _legal;
  late final double maxProb;

  PolicyData(this.data, this.posLen, Board board)
      : boardSize = board.xSize,
        _legal = Uint8List(board.xSize * board.ySize) {
    var m = 0.0;
    for (var y = 0; y < board.ySize; y++) {
      for (var x = 0; x < board.xSize; x++) {
        if (!board.wouldBeLegal(board.pla, board.loc(x, y))) continue;
        _legal[y * board.xSize + x] = 1;
        final p = probAt(x, y);
        if (p > m) m = p;
      }
    }
    if (passProb > m) m = passProb;
    maxProb = m;
  }

  double get passProb => data[posLen * posLen];

  double probAt(int x, int y) => data[y * posLen + x];

  bool isLegalAt(int x, int y) => _legal[y * boardSize + x] != 0;

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
        if (!isLegalAt(x, y)) continue;
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
  ProfileAnalysis(this.policy, this.lead);
}

/// What the game loop needs from an engine. Lets tests drive the whole loop --
/// navigation, cache invalidation, opponent sampling -- without a 107 MB model.
abstract class Analyzer {
  String get provider;
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles);
}

/// Why there is no engine. The message is written for the status line, not a log.
class EngineUnavailable implements Exception {
  final String message;
  const EngineUnavailable(this.message);
  @override
  String toString() => message;
}

/// Trims an exception down to the part worth showing in the UI: the message,
/// without the platform wrapper or the Java class name in front of it.
String describeFailure(Object e) {
  final s = '$e';
  final wrapped =
      RegExp(r'PlatformException\([^,]*,\s*(.*?),\s*null,\s*null\)').firstMatch(s);
  var out = (wrapped?.group(1) ?? s).split('\n').first.trim();
  out = out.replaceFirst(RegExp(r'^[A-Za-z_$]*(Exception|Error)\s*:\s*'), '');
  return out;
}

/// Runs the human-SL net on device.
class ShapeEngine implements Analyzer {
  final NetRunner runner;
  final Features features;
  final int posLen;

  ShapeEngine(this.runner, {this.posLen = 19}) : features = Features(posLen);

  @override
  String get provider => runner.label;

  /// Load the net, or explain why there will not be one.
  ///
  /// Throws [EngineUnavailable] rather than letting a platform exception escape:
  /// every caller wants a sentence to show, and none of them can fix the problem.
  /// The app runs on without an engine, so failing here costs feedback and the
  /// opponent, not the whole app.
  ///
  /// Loading is not enough: the net must also reproduce the desktop export on
  /// the bundled position (see reference.dart).
  static Future<ShapeEngine> load({int posLen = 19}) async {
    if (await EngineTrial.crashedBefore()) {
      throw const EngineUnavailable(
          'the engine crashed this device on an earlier run, so it was not started again');
    }
    await EngineTrial.begin();
    ShapeEngine? engine;
    try {
      engine = ShapeEngine(await MnnRunner.load(), posLen: posLen);
      final check = await engine.verifyAgainstReference();
      if (!check.ok) {
        throw EngineUnavailable('the net does not compute correctly here ($check)');
      }
      // Only reached once a forward pass has returned. A hard fault never gets
      // here, which is the point of the breadcrumb.
      await EngineTrial.survived();
      return engine;
    } catch (e) {
      await engine?.close().catchError((_) {});
      await EngineTrial.survived();
      throw e is EngineUnavailable ? e : EngineUnavailable(describeFailure(e));
    }
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
        PolicyData(o.policy, posLen, pos.board),
        o.lead,
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
