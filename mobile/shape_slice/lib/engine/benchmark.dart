// On-device benchmark: every runtime and backend, timed AND checked.
//
// Runs the fixed reference position shipped in assets/position.bin rather than
// whatever the game is on, so results are reproducible between runs and can be
// verified against assets/reference.json -- the same numbers the desktop export
// produced. A backend that runs fast and returns garbage is a real failure mode
// (GPU output that never gets copied back to host looks exactly like this), so
// timing alone is not enough to trust a row.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'dart:io';

import 'analysis.dart';
import 'features.dart';
import 'mnn.dart';

/// A running log of the benchmark, flushed to disk as it goes.
///
/// A native crash in a backend kills the process outright -- no Dart or Kotlin
/// catch can contain it -- taking the dialog and every result already measured
/// with it. Appending each row and each step as it happens means a crash costs
/// only the step it died on, and the next run reports both.
class _Journal {
  static File? _file;
  static final List<String> _lines = [];

  static Future<void> init() async {
    try {
      _file = File('${await MnnRunner.cacheDir()}/benchmark_journal.txt');
    } catch (_) {
      _file = null;
    }
  }

  static void append(String line) {
    _lines.add(line);
    try {
      _file?.writeAsStringSync(_lines.join('\n'), flush: true);
    } catch (_) {}
  }

  /// What the previous run managed before dying, if it died.
  static List<String> takePrevious() {
    try {
      final f = _file;
      if (f == null || !f.existsSync()) return const [];
      final lines = f.readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();
      f.deleteSync();
      return lines;
    } catch (_) {
      return const [];
    }
  }

  static void finish() {
    try {
      if (_file?.existsSync() ?? false) _file!.deleteSync();
    } catch (_) {}
  }
}

const String kOnnxAsset = 'assets/b18c384nbt-humanv0.onnx';
const String kMnnAsset = 'assets/humanv0.mnn';
const String kBenchProfile = 'rank_5k';

/// Tolerance for "same answer as desktop". fp32 rounding across runtimes lands
/// around 1e-5; anything near 1e-3 means a backend is quietly doing its own
/// thing, and a wrong top move means it is broken outright.
const double kBenchTolerance = 1e-3;

class BenchRow {
  final String label;
  final int? msPerEval;
  final double? maxDiff;
  final bool? topMoveOk;
  final String? error;

  const BenchRow(this.label, {this.msPerEval, this.maxDiff, this.topMoveOk, this.error});

  bool get ok => error == null && msPerEval != null;
  bool get correct => topMoveOk == true && (maxDiff ?? 1) < kBenchTolerance;

  String get status {
    if (error != null) return 'unavailable';
    if (topMoveOk == false) return 'WRONG MOVE';
    if ((maxDiff ?? 0) >= kBenchTolerance) return 'differs ${maxDiff!.toStringAsExponential(0)}';
    return 'ok';
  }
}

/// The fixed position and the expected outputs for it.
class _Reference {
  final Float32List bin;
  final Float32List global;
  final Float32List meta;
  final int expectedTopIndex;
  final Map<int, double> expectedPolicy;

  _Reference(this.bin, this.global, this.meta, this.expectedTopIndex, this.expectedPolicy);

  static Future<_Reference> load() async {
    final raw = await rootBundle.load('assets/position.bin');
    const binLen = kNumBinFeatures * 19 * 19;
    final all = raw.buffer.asFloat32List(raw.offsetInBytes, binLen + kNumGlobalFeatures);
    final ref = jsonDecode(await rootBundle.loadString('assets/reference.json'))
        as Map<String, dynamic>;
    final profile = (ref['profiles'] as Map)[kBenchProfile] as Map<String, dynamic>;
    final top = (profile['top'] as List).cast<Map<String, dynamic>>();
    return _Reference(
      Float32List.fromList(all.sublist(0, binLen)),
      Float32List.fromList(all.sublist(binLen)),
      Float32List.fromList(
          (profile['meta'] as List).map((e) => (e as num).toDouble()).toList()),
      top.first['idx'] as int,
      {for (final e in top) e['idx'] as int: (e['p'] as num).toDouble()},
    );
  }

  /// Largest disagreement with desktop over the moves desktop rated highest.
  (double, bool) check(List<double> policy) {
    var worst = 0.0;
    expectedPolicy.forEach((idx, p) {
      final d = (policy[idx] - p).abs();
      if (d > worst) worst = d;
    });
    var best = 0;
    for (var i = 1; i < policy.length; i++) {
      if (policy[i] > policy[best]) best = i;
    }
    return (worst, best == expectedTopIndex);
  }
}

/// Times [body] after a warm-up, and checks what it returned.
Future<BenchRow> _row(
  String label,
  _Reference ref,
  int reps,
  Future<List<double>> Function() body,
) async {
  try {
    final warm = await body();
    final (diff, topOk) = ref.check(warm);
    final sw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      await body();
    }
    return BenchRow(label,
        msPerEval: sw.elapsedMilliseconds ~/ reps, maxDiff: diff, topMoveOk: topOk);
  } catch (e) {
    return BenchRow(label, error: '$e'.split('\n').first);
  }
}

/// [includeMnn] is opt-in because MNN dispatches on advertised CPU features and
/// a machine that lies about them (notably the Android emulator on Apple Silicon,
/// which claims SVE2) dies with SIGILL inside libMNN -- a native fault no Kotlin
/// try/catch can contain. Gameplay never touches MNN, so the blast radius is this
/// one button.
Future<List<BenchRow>> runBenchmark({
  int reps = 3,
  int posLen = 19,
  bool includeMnn = false,
}) async {
  final ref = await _Reference.load();
  final rows = <BenchRow>[];
  final features = FeatureResult(ref.bin, ref.global);

  await _Journal.init();
  final previous = _Journal.takePrevious();
  if (previous.isNotEmpty) {
    rows.add(BenchRow('PREVIOUS RUN CRASHED', error: 'got as far as: ${previous.last}'));
    for (final line in previous.where((l) => l.contains('ms'))) {
      rows.add(BenchRow('  (prev) $line'));
    }
  }

  // --- ONNX Runtime ---
  Future<void> ortRow(String label, OrtSessionOptions options, {int batch = 1}) async {
    OrtSession? session;
    try {
      session = await OnnxRuntime().createSessionFromAsset(kOnnxAsset, options: options);
      final engine = ShapeEngine(session, posLen, label)..useBatchedAnalysis = batch > 1;
      final metas = List.filled(batch, ref.meta);
      _Journal.append('$label: starting');
      final row = await _row(label, ref, reps, () async {
        final out = await engine.runRaw(features, metas, 19);
        return out.first.policy.data.toList();
      });
      rows.add(row);
      _Journal.append('$label ${row.msPerEval} ms ${row.status}');
    } catch (e) {
      rows.add(BenchRow(label, error: '$e'.split('\n').first));
    } finally {
      await session?.close();
    }
  }

  for (final p in [OrtProvider.CPU, OrtProvider.NNAPI, OrtProvider.XNNPACK]) {
    await ortRow('ORT ${p.name}', OrtSessionOptions(providers: [p]));
  }
  await ortRow('ORT CPU batch x3',
      OrtSessionOptions(providers: [OrtProvider.CPU]), batch: 3);

  if (!includeMnn) return rows;

  // --- MNN: the reason this file exists ---
  for (final backend in MnnBackend.values) {
    try {
      _Journal.append('${backend.label}: loading model');
      await MnnRunner.load(kMnnAsset, backend);
      _Journal.append('${backend.label}: model loaded, running inference');
      final row = await _row(backend.label, ref, reps, () async {
        final out = await MnnRunner.run(ref.bin, ref.global, ref.meta);
        return out['policy']!.toList();
      });
      rows.add(row);
      _Journal.append('${backend.label} ${row.msPerEval} ms ${row.status}');
    } catch (e) {
      rows.add(BenchRow(backend.label, error: '$e'.split('\n').first));
      _Journal.append('${backend.label}: threw');
    } finally {
      await MnnRunner.release().catchError((_) {});
    }
  }
  _Journal.finish();

  return rows;
}
