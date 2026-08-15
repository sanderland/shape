// Tests for how ShapeEngine drives a NetRunner.
//
// Gameplay now runs on MNN where it works and ONNX Runtime where it does not, so
// the dispatch between them -- one call per profile vs one batched call, and which
// row of the output belongs to which profile -- is real logic with a real failure
// mode. A recording fake stands in for the net, so none of this needs a device or
// the 107 MB model.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shape_slice/engine/analysis.dart';
import 'package:shape_slice/engine/features.dart';
import 'package:shape_slice/sgf_metadata.dart';

const int kPolicyLen = 19 * 19 + 1;

/// Records every call and returns outputs that identify the row they came from.
class RecordingRunner implements NetRunner {
  @override
  final String label;
  @override
  final bool supportsBatch;

  RecordingRunner({this.supportsBatch = true, this.label = 'fake'});

  final List<int> batchSizes = [];
  final List<Float32List> metasSeen = [];
  final List<Float32List> binsSeen = [];
  int closed = 0;

  @override
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta, int n) async {
    batchSizes.add(n);
    metasSeen.add(meta);
    binsSeen.add(bin);

    // Row i is marked by its metadata's first element, so the test can prove the
    // split put each row's outputs with the profile that asked for them.
    final policy = Float32List(n * kPolicyLen);
    final lead = Float32List(n);
    final value = Float32List(n * 3);
    for (var i = 0; i < n; i++) {
      final tag = meta[i * kMetadataChannels];
      policy[i * kPolicyLen] = tag;
      lead[i] = tag * 10;
      value[i * 3] = tag / 100;
    }
    return NetOutputs(policy, lead, value);
  }

  @override
  Future<void> close() async => closed++;
}

/// Metadata rows tagged 1, 2, 3 in their first element.
List<Float32List> taggedMetas(int count) => [
      for (var i = 1; i <= count; i++)
        Float32List(kMetadataChannels)..[0] = i.toDouble(),
    ];

FeatureResult dummyFeatures() => FeatureResult(
      Float32List(kNumBinFeatures * 19 * 19)..[0] = 7,
      Float32List(kNumGlobalFeatures)..[0] = 8,
    );

void main() {
  test('sequential path makes one batch-1 call per profile, in order', () async {
    final runner = RecordingRunner();
    final engine = ShapeEngine(runner);

    final out = await engine.runRaw(dummyFeatures(), taggedMetas(3), 19);

    expect(runner.batchSizes, [1, 1, 1]);
    expect(out.map((a) => a.lead), [10, 20, 30]);
    expect(out.map((a) => a.policy.data[0]), [1, 2, 3]);
    // winrate is value[i*3]; fp32 storage means these are not exact.
    expect(out.map((a) => a.winrate),
        [closeTo(0.01, 1e-6), closeTo(0.02, 1e-6), closeTo(0.03, 1e-6)]);
  });

  test('batched path tiles the board tensors and splits rows back out', () async {
    final runner = RecordingRunner();
    final engine = ShapeEngine(runner)..useBatchedAnalysis = true;

    final out = await engine.runRaw(dummyFeatures(), taggedMetas(3), 19);

    expect(runner.batchSizes, [3], reason: 'one call, not three');

    // bin is identical across profiles, so every tile must carry the same values.
    final bin = runner.binsSeen.single;
    const binLen = kNumBinFeatures * 19 * 19;
    expect(bin.length, 3 * binLen);
    for (var i = 0; i < 3; i++) {
      expect(bin[i * binLen], 7, reason: 'tile $i lost the board features');
    }

    // Only the metadata differs between rows, and the split must respect that.
    expect(out.map((a) => a.lead), [10, 20, 30]);
    expect(out.map((a) => a.policy.data[0]), [1, 2, 3]);
  });

  test('a runner that cannot batch is never batched', () async {
    // MNN's bridge pins its input shapes to batch 1 because the export's dynamic
    // batch axis is left unresolved; feeding it a batch segfaults inside libMNN.
    // The flag must not be able to reach it.
    final runner = RecordingRunner(supportsBatch: false, label: 'MNN CPU');
    final engine = ShapeEngine(runner)..useBatchedAnalysis = true;

    final out = await engine.runRaw(dummyFeatures(), taggedMetas(3), 19);

    expect(runner.batchSizes, [1, 1, 1]);
    expect(out.map((a) => a.lead), [10, 20, 30]);
  });

  test('analyze builds one metadata row per profile and keys results by name', () async {
    final runner = RecordingRunner();
    final engine = ShapeEngine(runner);
    final pos = GoPosition(19, Rules.japanese);

    final out = await engine.analyze(pos, ['rank_5k', 'rank_2d', 'proyear_2023']);

    expect(out.keys, ['rank_5k', 'rank_2d', 'proyear_2023']);
    expect(runner.batchSizes, [1, 1, 1]);

    // Different ranks must produce different metadata, or the whole point of the
    // human-SL net is lost -- three identical rows would look like a working app.
    final rows = runner.metasSeen.map((m) => m.join(',')).toSet();
    expect(rows.length, 3, reason: 'profiles collapsed to the same metadata');
    for (final m in runner.metasSeen) {
      expect(m.length, kMetadataChannels);
    }
  });

  test('provider name and close pass through to the runner', () async {
    final runner = RecordingRunner(label: 'MNN CPU');
    final engine = ShapeEngine(runner);
    expect(engine.provider, 'MNN CPU');
    expect(engine.notes, isEmpty);
    await engine.close();
    expect(runner.closed, 1);
  });
}
