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

/// How one benchmark configuration performed. [provider] is a free-form row
/// label ("CPU", "CPU intra=2", "CPU batch x4 /pos", ...), not necessarily a
/// bare execution provider name.
class ProviderTiming {
  final String provider;
  final int? msPerEval;
  final String? error;
  const ProviderTiming(this.provider, this.msPerEval, this.error);
  bool get ok => msPerEval != null;
}

/// What the game loop needs from an engine. Lets tests drive the whole loop --
/// navigation, cache invalidation, opponent sampling -- without a 107 MB model.
abstract class Analyzer {
  String get provider;
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles);
}

/// Runs the human-SL net on device.
class ShapeEngine implements Analyzer {
  final OrtSession session;
  final Features features;
  final int posLen;

  /// Which execution provider initialised. Note this is only the provider ORT
  /// *accepted*: NNAPI partitions the graph and silently runs unsupported ops on
  /// CPU, so this being "NNAPI" does not by itself mean the NPU did the work.
  /// Latency is the only real evidence -- see [benchmarkProviders].
  @override
  final String provider;

  ShapeEngine(this.session, this.posLen, this.provider) : features = Features(posLen);

  /// CPU first, because it measured best on real hardware.
  ///
  /// Galaxy (Snapdragon), b18c384nbt-humanv0, ms/eval:
  ///   featurizer (Dart)   0
  ///   NNAPI             249
  ///   XNNPACK           602
  ///   CPU               247
  ///
  /// NNAPI accepts the model and then runs it at CPU speed -- it partitions the
  /// graph and silently falls back for ops it cannot handle, which for this net is
  /// evidently most of them. XNNPACK is markedly worse. Use the in-app benchmark to
  /// re-check on other hardware before reordering this.
  /// QNN is tried first: it is the only route to a Qualcomm NPU now that NNAPI
  /// is deprecated, and it falls through to CPU on every other device.
  static const List<OrtProvider> preferredProviders = [
    OrtProvider.QNN,
    OrtProvider.CPU,
    OrtProvider.NNAPI,
    OrtProvider.XNNPACK,
  ];

  /// Order used by the benchmark, so every provider is reported regardless of
  /// which one we default to.
  static const List<OrtProvider> benchmarkProviderOrder = [
    OrtProvider.QNN,
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

  /// The profiles a hints-on position actually evaluates: player, target and the
  /// score reference. The sequential-vs-batched rows use exactly this set, since
  /// batch size changes the answer and measuring a batch of 4 would not settle a
  /// workload of 3.
  static const List<String> benchmarkProfiles = [
    'rank_5k', 'rank_2d', 'proyear_2023', //
  ];

  /// Time each configuration on [pos], creating and closing a session per row.
  ///
  /// Deliberately measures rather than trusts: an NNAPI session that falls back to
  /// CPU for most ops looks identical to a working one until you time it. Beyond
  /// the provider comparison this sweeps CPU intra-op threads (ORT's default may
  /// schedule onto little cores on big.LITTLE) and compares 4 sequential batch-1
  /// evals against one batch-4 eval -- desktop CPU EP has a sharp batch>=2 cliff
  /// that makes batching a big loss there, but only a device run settles it here.
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

    // One timed row: build a session, run [body] reps times, tear down.
    Future<void> row(
      String label,
      OrtSessionOptions options,
      Future<void> Function(ShapeEngine engine) body,
    ) async {
      OrtSession? session;
      try {
        session = await OnnxRuntime().createSessionFromAsset(assetPath, options: options);
        final engine = ShapeEngine(session, posLen, label);
        await body(engine); // warm up
        final sw = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          await body(engine);
        }
        out.add(ProviderTiming(label, sw.elapsedMilliseconds ~/ reps, null));
      } catch (e) {
        out.add(ProviderTiming(label, null, '$e'.split('\n').first));
      } finally {
        await session?.close();
      }
    }

    Future<void> oneEval(ShapeEngine e) => e.analyze(pos, [profile]);

    for (final p in benchmarkProviderOrder) {
      await row(p.name, OrtSessionOptions(providers: [p]), oneEval);
    }

    // CPU intra-op thread sweep, one eval per call. ORT's default thread count on
    // Android counts every core; pinning to the number of big cores may win.
    for (final t in [1, 2, 4]) {
      await row(
        'CPU intra=$t',
        OrtSessionOptions(providers: [OrtProvider.CPU], intraOpNumThreads: t),
        oneEval,
      );
    }

    // Per-position cost of a hints-on analysis (4 profiles): sequential vs batched.
    final cpu = OrtSessionOptions(providers: [OrtProvider.CPU]);
    await row('CPU seq x3 /pos', cpu, (e) => e.analyze(pos, benchmarkProfiles));
    await row('CPU batch x3 /pos', cpu, (e) {
      e.useBatchedAnalysis = true;
      return e.analyze(pos, benchmarkProfiles);
    });
    return out;
  }

  /// Evaluate all [profiles] in a single net call instead of one call each.
  ///
  /// Off by default: on ORT's CPU provider there is a sharp cliff between batch 1
  /// and batch 2 (desktop arm64, fp32: batch-1 30ms but batch-4 220ms, and
  /// single-threaded batch-4 is 865ms vs 4x92ms sequential -- the slowdown is in
  /// the conv kernels, not thread scheduling). Kept behind this flag so the
  /// in-app benchmark can measure whether mobile ORT behaves the same.
  bool useBatchedAnalysis = false;

  /// Evaluate [pos] under each of [profiles].
  ///
  /// bin/global are identical across profiles (only the 192-wide metadata row
  /// differs), so they are uploaded once and reused across the sequential runs,
  /// or tiled once for the batched path.
  @override
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles) async {
    final f = features.fillRowFeatures(pos);
    final nextPlayer = pos.nextPlayer;
    final boardArea = pos.boardSize * pos.boardSize;
    final metas = [
      for (final p in profiles) getProfile(p).getMetadataRow(nextPlayer, boardArea),
    ];
    final results = useBatchedAnalysis && profiles.length > 1
        ? await _runBatched(f, metas, pos.boardSize)
        : await _runSequential(f, metas, pos.boardSize);
    return {for (var i = 0; i < profiles.length; i++) profiles[i]: results[i]};
  }

  /// One batch-1 net call per metadata row, reusing the board tensors.
  Future<List<ProfileAnalysis>> _runSequential(
    FeatureResult f,
    List<Float32List> metas,
    int boardSize,
  ) async {
    final binValue = await OrtValue.fromList(f.bin, [1, kNumBinFeatures, posLen, posLen]);
    final globalValue = await OrtValue.fromList(f.global, [1, kNumGlobalFeatures]);
    try {
      final out = <ProfileAnalysis>[];
      for (final meta in metas) {
        final metaValue = await OrtValue.fromList(meta, [1, kMetadataChannels]);
        try {
          final outputs = await session.run({
            'bin_input': binValue,
            'global_input': globalValue,
            'input_meta': metaValue,
          });
          out.add((await _readOutputs(outputs, 1, boardSize)).single);
        } finally {
          await metaValue.dispose();
        }
      }
      return out;
    } finally {
      await binValue.dispose();
      await globalValue.dispose();
    }
  }

  /// All metadata rows as one batch-N net call.
  Future<List<ProfileAnalysis>> _runBatched(
    FeatureResult f,
    List<Float32List> metas,
    int boardSize,
  ) async {
    final n = metas.length;
    final bin = Float32List(n * f.bin.length);
    final global = Float32List(n * f.global.length);
    final meta = Float32List(n * kMetadataChannels);
    for (var i = 0; i < n; i++) {
      bin.setAll(i * f.bin.length, f.bin);
      global.setAll(i * f.global.length, f.global);
      meta.setAll(i * kMetadataChannels, metas[i]);
    }
    final inputs = {
      'bin_input': await OrtValue.fromList(bin, [n, kNumBinFeatures, posLen, posLen]),
      'global_input': await OrtValue.fromList(global, [n, kNumGlobalFeatures]),
      'input_meta': await OrtValue.fromList(meta, [n, kMetadataChannels]),
    };
    try {
      final outputs = await session.run(inputs);
      return await _readOutputs(outputs, n, boardSize);
    } finally {
      for (final v in inputs.values) {
        await v.dispose();
      }
    }
  }

  /// Split the net's [n]-row outputs into one [ProfileAnalysis] per row.
  Future<List<ProfileAnalysis>> _readOutputs(
    Map<String, OrtValue> outputs,
    int n,
    int boardSize,
  ) async {
    final policyLen = posLen * posLen + 1;
    try {
      final policy = _floats(await outputs['policy']!.asFlattenedList());
      final lead = _floats(await outputs['lead']!.asFlattenedList());
      final value = _floats(await outputs['value']!.asFlattenedList());
      return [
        for (var i = 0; i < n; i++)
          ProfileAnalysis(
            PolicyData(policy.sublist(i * policyLen, (i + 1) * policyLen), posLen, boardSize),
            lead[i],
            // value is softmax over {win, loss, noresult} for the side to move.
            value[i * 3],
          ),
      ];
    } finally {
      for (final v in outputs.values) {
        await v.dispose();
      }
    }
  }
}

Float32List _floats(List<dynamic> v) {
  if (v is Float32List) return v;
  final out = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    out[i] = (v[i] as num).toDouble();
  }
  return out;
}

/// Board coords -> loc, guarding against off-board taps.
int? coordsToLoc(Board b, int x, int y) {
  if (x < 0 || y < 0 || x >= b.xSize || y >= b.ySize) return null;
  return b.loc(x, y);
}
