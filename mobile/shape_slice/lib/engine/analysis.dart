// Policy handling and the on-device engine: featurize -> human-SL net -> policies.
//
// Port of the parts of SHAPE's game_logic.py that matter: PolicyData.sample (the
// top_k/top_p/min_p sampler the opponent plays from) and the per-position analysis
// cache.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'board.dart';
import 'features.dart';
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

/// How one execution provider performed, for the in-app benchmark.
class ProviderTiming {
  final String provider;
  final int? msPerEval;
  final String? error;
  const ProviderTiming(this.provider, this.msPerEval, this.error);
  bool get ok => msPerEval != null;
}

/// Runs the human-SL net on device.
class ShapeEngine {
  final OrtSession session;
  final Features features;
  final int posLen;

  /// Which execution provider initialised. Note this is only the provider ORT
  /// *accepted*: NNAPI partitions the graph and silently runs unsupported ops on
  /// CPU, so this being "NNAPI" does not by itself mean the NPU did the work.
  /// Latency is the only real evidence -- see [benchmarkProviders].
  final String provider;

  ShapeEngine(this.session, this.posLen, this.provider) : features = Features(posLen);

  /// Preference order on Android: NNAPI (NPU/GPU), then XNNPACK (optimised CPU),
  /// then plain CPU.
  static const List<OrtProvider> preferredProviders = [
    OrtProvider.NNAPI,
    OrtProvider.XNNPACK,
    OrtProvider.CPU,
  ];

  static Future<ShapeEngine> load(
    String assetPath, {
    int posLen = 19,
    List<OrtProvider>? prefer,
  }) async {
    Object? lastError;
    for (final p in prefer ?? preferredProviders) {
      try {
        final session = await OnnxRuntime().createSessionFromAsset(
          assetPath,
          options: OrtSessionOptions(providers: [p]),
        );
        return ShapeEngine(session, posLen, p.name);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('no execution provider could load the model: $lastError');
  }

  /// Time each provider on [pos], creating and closing a session per provider.
  ///
  /// Deliberately measures rather than trusts: an NNAPI session that falls back to
  /// CPU for most ops looks identical to a working one until you time it.
  static Future<List<ProviderTiming>> benchmarkProviders(
    String assetPath,
    GoPosition pos, {
    int posLen = 19,
    int reps = 3,
    String profile = 'rank_5k',
  }) async {
    final out = <ProviderTiming>[];

    // Featurization is pure Dart and runs identically for every provider, so time it
    // separately -- if the ladder search dominates, no execution provider will help.
    final fsw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      Features(posLen).fillRowFeatures(pos);
    }
    out.add(ProviderTiming('featurizer (Dart)', fsw.elapsedMilliseconds ~/ reps, null));

    for (final p in preferredProviders) {
      OrtSession? session;
      try {
        session = await OnnxRuntime().createSessionFromAsset(
          assetPath,
          options: OrtSessionOptions(providers: [p]),
        );
        final engine = ShapeEngine(session, posLen, p.name);
        await engine.analyze(pos, [profile]); // warm up
        final sw = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          await engine.analyze(pos, [profile]);
        }
        out.add(ProviderTiming(p.name, sw.elapsedMilliseconds ~/ reps, null));
      } catch (e) {
        out.add(ProviderTiming(p.name, null, '$e'.split('\n').first));
      } finally {
        await session?.close();
      }
    }
    return out;
  }

  /// Evaluate [pos] under each of [profiles].
  ///
  /// Runs one profile per call rather than batching them: bin/global are identical
  /// across profiles so a batch is possible, but measured batch-N is *slower* than N
  /// batch-1 calls on ORT's CPU provider (there is a sharp cliff between batch 1 and 2).
  /// Revisit if a hardware EP inverts that.
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles) async {
    final f = features.fillRowFeatures(pos);
    final nextPlayer = pos.nextPlayer;
    final boardArea = pos.boardSize * pos.boardSize;

    final out = <String, ProfileAnalysis>{};
    for (final profile in profiles) {
      final meta = getProfile(profile).getMetadataRow(nextPlayer, boardArea);
      final inputs = {
        'bin_input': await OrtValue.fromList(f.bin, [1, kNumBinFeatures, posLen, posLen]),
        'global_input': await OrtValue.fromList(f.global, [1, kNumGlobalFeatures]),
        'input_meta': await OrtValue.fromList(meta, [1, kMetadataChannels]),
      };
      final outputs = await session.run(inputs);
      final policy = Float32List.fromList(_flatten(await outputs['policy']!.asList()));
      final lead = _flatten(await outputs['lead']!.asList()).first;
      final value = _flatten(await outputs['value']!.asList());
      for (final v in inputs.values) {
        v.dispose();
      }
      // value is softmax over {win, loss, noresult} for the side to move.
      final winrate = value.isNotEmpty ? value[0] : 0.5;
      out[profile] = ProfileAnalysis(
        PolicyData(policy, posLen, pos.boardSize),
        lead,
        winrate,
      );
    }
    return out;
  }
}

List<double> _flatten(dynamic v) {
  if (v is num) return [v.toDouble()];
  if (v is Float32List) return List<double>.from(v);
  if (v is List) return v.expand(_flatten).toList();
  throw ArgumentError('unexpected ORT output element: ${v.runtimeType}');
}

/// Board coords -> loc, guarding against off-board taps.
int? coordsToLoc(Board b, int x, int y) {
  if (x < 0 || y < 0 || x >= b.xSize || y >= b.ySize) return null;
  return b.loc(x, y);
}
