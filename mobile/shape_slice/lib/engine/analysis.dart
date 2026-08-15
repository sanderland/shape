// Policy handling and the on-device engine: featurize -> human-SL net -> policies.
//
// Port of the parts of SHAPE's game_logic.py that matter: PolicyData.sample (the
// top_k/top_p/min_p sampler the opponent plays from) and the per-position analysis
// cache.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'board.dart';
import 'features.dart';
import 'mnn.dart';
import 'reference.dart';
import '../sgf_metadata.dart';

/// The same net in two formats. MNN's is converted from the ONNX one and checked
/// for parity offline (tools/mnn/) and again on device at startup.
const String kOnnxAsset = 'assets/b18c384nbt-humanv0.onnx';
const String kMnnAsset = 'assets/humanv0.mnn';

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

/// Raw net outputs, flattened across the batch.
class NetOutputs {
  final Float32List policy;
  final Float32List lead;
  final Float32List value;
  const NetOutputs(this.policy, this.lead, this.value);
}

/// One loaded copy of the net.
///
/// Two implementations exist because they are not close in speed: on a Galaxy
/// S24+ the same model runs at 104 ms/eval under MNN and 217 ms under ONNX
/// Runtime. Which one gameplay gets is decided at startup by [ShapeEngine.load].
abstract class NetRunner {
  String get label;

  /// Whether more than one metadata row fits in a single call.
  bool get supportsBatch;

  /// One forward pass over [n] rows; bin/global/meta are already tiled to [n].
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta, int n);

  Future<void> close();
}

class OrtRunner implements NetRunner {
  final OrtSession session;
  final int posLen;
  @override
  final String label;

  OrtRunner(this.session, this.posLen, this.label);

  @override
  bool get supportsBatch => true;

  static Future<OrtRunner> load(OrtProvider provider, {int posLen = 19}) async {
    final session = await OnnxRuntime().createSessionFromAsset(
      kOnnxAsset,
      options: OrtSessionOptions(providers: [provider]),
    );
    return OrtRunner(session, posLen, 'ORT ${provider.name}');
  }

  /// bin and global are identical across the profiles of one position, so this
  /// re-uploads them per call where hoisting them would not. At 32 KB against a
  /// ~100 ms forward pass that is noise, and it keeps the interface batch-shaped.
  @override
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta, int n) async {
    final inputs = {
      'bin_input': await OrtValue.fromList(bin, [n, kNumBinFeatures, posLen, posLen]),
      'global_input': await OrtValue.fromList(global, [n, kNumGlobalFeatures]),
      'input_meta': await OrtValue.fromList(meta, [n, kMetadataChannels]),
    };
    try {
      final outputs = await session.run(inputs);
      try {
        return NetOutputs(
          _floats(await outputs['policy']!.asFlattenedList()),
          _floats(await outputs['lead']!.asFlattenedList()),
          _floats(await outputs['value']!.asFlattenedList()),
        );
      } finally {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    } finally {
      for (final v in inputs.values) {
        await v.dispose();
      }
    }
  }

  @override
  Future<void> close() => session.close();
}

class MnnNetRunner implements NetRunner {
  final MnnBackend backend;
  MnnNetRunner(this.backend);

  @override
  String get label => backend.label;

  /// MainActivity pins the input shapes to batch 1, because the ONNX export's
  /// dynamic batch axis is left unresolved by MNN's Interpreter API.
  @override
  bool get supportsBatch => false;

  static Future<MnnNetRunner> load(MnnBackend backend) async {
    await MnnRunner.load(kMnnAsset, backend);
    return MnnNetRunner(backend);
  }

  @override
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta, int n) async {
    assert(n == 1, 'MNN bridge is pinned to batch 1');
    Map<String, Float32List> out;
    try {
      out = await MnnRunner.run(bin, global, meta);
    } on PlatformException {
      // There is one native session, and the benchmark loads and releases it. A
      // benchmark run mid-game therefore leaves gameplay without one; reload.
      await MnnRunner.load(kMnnAsset, backend);
      out = await MnnRunner.run(bin, global, meta);
    }
    return NetOutputs(out['policy']!, out['lead']!, out['value']!);
  }

  @override
  Future<void> close() => MnnRunner.release();
}

/// Runs the human-SL net on device.
class ShapeEngine implements Analyzer {
  final NetRunner runner;
  final Features features;
  final int posLen;

  /// Why the engine is not on a faster runtime, if it is not. Empty on the happy
  /// path. Surfaced in the UI because "MNN crashed this device, so you are on the
  /// 2x slower runtime" is something the user should be told, not have to guess
  /// from the timings.
  final List<String> notes;

  ShapeEngine(this.runner, {this.posLen = 19, this.notes = const []})
      : features = Features(posLen);

  /// Which runtime and backend actually got loaded. Note that for ONNX Runtime
  /// this is only the provider it *accepted*: NNAPI partitions the graph and
  /// silently runs unsupported ops on CPU, so "NNAPI" does not by itself mean the
  /// NPU did the work. Latency is the only real evidence -- see the benchmark.
  @override
  String get provider => runner.label;

  /// ONNX Runtime providers, best first, used when MNN is unavailable.
  ///
  /// Galaxy S24+, b18c384nbt-humanv0, ms/eval: CPU 217, NNAPI 216, XNNPACK 472.
  /// NNAPI accepts the model and then runs it at CPU speed -- it falls back for
  /// ops it cannot handle, which for this net is evidently most of them -- and it
  /// is deprecated as of Android 15. XNNPACK is markedly worse.
  static const List<OrtProvider> preferredProviders = [
    OrtProvider.CPU,
    OrtProvider.NNAPI,
    OrtProvider.XNNPACK,
  ];

  /// Load the net on the fastest runtime this device will run *correctly*.
  ///
  /// MNN first: 104 ms/eval against ONNX Runtime's 217 on a Galaxy S24+, both
  /// verified against the same reference position. Its OpenCL backend ties CPU at
  /// 105 ms, so the win is the runtime and not the GPU, and CPU is the one with
  /// no driver surface to go wrong.
  ///
  /// MNN is tried rather than assumed, because it dispatches on advertised CPU
  /// features and a machine that lies about them (the Android emulator on Apple
  /// Silicon claims SVE2) dies with SIGILL inside libMNN -- a native fault no Dart
  /// or Kotlin catch can contain. [MnnTrial] is what makes trying it safe: the
  /// breadcrumb it leaves turns a crash into a one-time cost, because the next
  /// launch sees it and takes ONNX Runtime instead.
  ///
  /// Loading is not enough to earn gameplay. A runtime must also reproduce the
  /// desktop answer on the bundled reference position, so a backend that returns
  /// garbage quickly is rejected exactly like one that fails to load. ORT is the
  /// baseline the reference was checked against and is not re-verified here; that
  /// keeps the extra forward pass on the risky path only.
  static Future<ShapeEngine> load({int posLen = 19, bool allowMnn = true}) async {
    final errors = <String>[];

    if (allowMnn) {
      if (await MnnTrial.crashedBefore()) {
        errors.add('MNN skipped: it crashed this device on an earlier run');
      } else {
        await MnnTrial.begin();
        try {
          final runner = await MnnNetRunner.load(MnnBackend.cpu);
          final check = await verify(runner);
          if (check.ok) {
            await MnnTrial.succeeded();
            return ShapeEngine(runner, posLen: posLen);
          }
          errors.add('${runner.label}: $check');
          await runner.close();
        } catch (e) {
          errors.add('MNN CPU: ${'$e'.split('\n').first}');
        }
        // Only reached if MNN failed *cleanly*. A hard crash never gets here, which
        // is the whole point of the breadcrumb.
        await MnnTrial.succeeded();
      }
    }

    for (final p in preferredProviders) {
      try {
        return ShapeEngine(await OrtRunner.load(p, posLen: posLen),
            posLen: posLen, notes: errors);
      } catch (e) {
        errors.add('ORT ${p.name}: ${'$e'.split('\n').first}');
      }
    }
    throw StateError('no runtime could load the model:\n${errors.join('\n')}');
  }

  /// Does this runner reproduce the desktop answer on the bundled position?
  static Future<ReferenceCheck> verify(NetRunner runner) async {
    final ref = await ReferencePosition.load();
    final out = await runner.run(ref.bin, ref.global, ref.meta, 1);
    return ref.check(out.policy);
  }

  /// Evaluate all profiles in a single net call instead of one call each.
  ///
  /// Off by default: on ORT's CPU provider there is a sharp cliff between batch 1
  /// and batch 2 (desktop arm64, fp32: batch-1 30ms but batch-4 220ms, and
  /// single-threaded batch-4 is 865ms vs 4x92ms sequential -- the slowdown is in
  /// the conv kernels, not thread scheduling), and on device batch x3 measured
  /// 714 ms against 3x217 sequential. Kept as a flag so it stays measurable.
  bool useBatchedAnalysis = false;

  bool get _batching => useBatchedAnalysis && runner.supportsBatch;

  /// Evaluate [pos] under each of [profiles].
  ///
  /// bin/global are identical across profiles -- only the 192-wide metadata row
  /// differs -- so featurization happens once regardless of how many profiles the
  /// caller asks for.
  @override
  Future<Map<String, ProfileAnalysis>> analyze(GoPosition pos, List<String> profiles) async {
    final f = features.fillRowFeatures(pos);
    final nextPlayer = pos.nextPlayer;
    final boardArea = pos.boardSize * pos.boardSize;
    final metas = [
      for (final p in profiles) getProfile(p).getMetadataRow(nextPlayer, boardArea),
    ];
    final results = _batching && profiles.length > 1
        ? await _runBatched(f, metas, pos.boardSize)
        : await _runSequential(f, metas, pos.boardSize);
    return {for (var i = 0; i < profiles.length; i++) profiles[i]: results[i]};
  }

  /// Run pre-computed tensors, bypassing featurization. Used by the benchmark so
  /// it can replay the fixed reference position and check the outputs.
  Future<List<ProfileAnalysis>> runRaw(
    FeatureResult f,
    List<Float32List> metas,
    int boardSize,
  ) =>
      _batching && metas.length > 1
          ? _runBatched(f, metas, boardSize)
          : _runSequential(f, metas, boardSize);

  /// One batch-1 net call per metadata row.
  Future<List<ProfileAnalysis>> _runSequential(
    FeatureResult f,
    List<Float32List> metas,
    int boardSize,
  ) async {
    final out = <ProfileAnalysis>[];
    for (final meta in metas) {
      out.addAll(_split(await runner.run(f.bin, f.global, meta, 1), 1, boardSize));
    }
    return out;
  }

  /// All metadata rows as one batch-N net call, with the board tensors tiled.
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
    return _split(await runner.run(bin, global, meta, n), n, boardSize);
  }

  /// Split the net's [n]-row outputs into one [ProfileAnalysis] per row.
  List<ProfileAnalysis> _split(NetOutputs o, int n, int boardSize) {
    final policyLen = posLen * posLen + 1;
    return [
      for (var i = 0; i < n; i++)
        ProfileAnalysis(
          PolicyData(
              Float32List.sublistView(o.policy, i * policyLen, (i + 1) * policyLen),
              posLen,
              boardSize),
          o.lead[i],
          // value is softmax over {win, loss, noresult} for the side to move.
          o.value[i * 3],
        ),
    ];
  }

  Future<void> close() => runner.close();
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
