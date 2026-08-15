// On-device benchmark: every runtime and backend, timed AND checked.
//
// Runs the fixed reference position shipped in assets/position.bin rather than
// whatever the game is on, so results are reproducible between runs and can be
// verified against assets/reference.json -- the same numbers the desktop export
// produced. A backend that runs fast and returns garbage is a real failure mode
// (GPU output that never gets copied back to host looks exactly like this), so
// timing alone is not enough to trust a row.

import 'dart:io';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'analysis.dart';
import 'mnn.dart';
import 'reference.dart';

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

/// One row of the results table: how fast, and whether it was right.
class BenchRow {
  final String label;
  final int? msPerEval;
  final ReferenceCheck? check;
  final String? error;

  const BenchRow(this.label, {this.msPerEval, this.check, this.error});

  bool get ok => error == null && msPerEval != null;
  bool get correct => check?.ok ?? false;

  String get status => error != null ? 'unavailable' : '${check ?? ''}';
}

/// Times [body] after a warm-up, and checks what it returned.
Future<BenchRow> _row(
  String label,
  ReferencePosition ref,
  int reps,
  Future<List<double>> Function() body,
) async {
  try {
    final check = ref.check(await body());
    final sw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      await body();
    }
    return BenchRow(label, msPerEval: sw.elapsedMilliseconds ~/ reps, check: check);
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
  final ref = await ReferencePosition.load();
  final rows = <BenchRow>[];
  final features = ref.features;

  await _Journal.init();
  final previous = _Journal.takePrevious();
  if (previous.isNotEmpty) {
    rows.add(BenchRow('PREVIOUS RUN DIED AT', error: previous.last));
    for (final line in previous.where((l) => l.contains(' ms '))) {
      rows.add(BenchRow('  (prev) $line'));
    }
  }

  // Android's own record, which survives a native crash even when nothing the
  // app wrote does.
  final exit = await MnnRunner.lastExit();
  if (exit != null) {
    rows.add(BenchRow('LAST PROCESS EXIT',
        error: '${exit['reason']}: ${exit['description']} '
            '(rss ${((exit['rssKb'] as num?) ?? 0) ~/ 1024} MB)'));
  }

  // --- ONNX Runtime ---
  Future<void> ortRow(String label, OrtProvider provider, {int batch = 1}) async {
    OrtRunner? runner;
    try {
      runner = await OrtRunner.load(provider, posLen: posLen);
      final engine = ShapeEngine(runner, posLen: posLen)..useBatchedAnalysis = batch > 1;
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
      await runner?.close();
    }
  }

  for (final p in [OrtProvider.CPU, OrtProvider.NNAPI, OrtProvider.XNNPACK]) {
    await ortRow('ORT ${p.name}', p);
  }
  await ortRow('ORT CPU batch x3', OrtProvider.CPU, batch: 3);

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
