// Tests ShapeEngine against a recording fake, so no device or 107 MB model is
// needed to check that each profile gets its own metadata and its own evaluation.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/engine/analysis.dart';
import 'package:goshape/engine/features.dart';
import 'package:goshape/engine/net.dart';
import 'package:goshape/sgf_metadata.dart';

const int kPolicyLen = 19 * 19 + 1;

/// Records every call and returns outputs that identify the call they came from.
class RecordingRunner implements NetRunner {
  @override
  final String label;

  RecordingRunner({this.label = 'fake'});

  final List<Float32List> metasSeen = [];
  final List<Float32List> binsSeen = [];
  int closed = 0;

  @override
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta) async {
    metasSeen.add(meta);
    binsSeen.add(bin);
    final policy = Float32List(kPolicyLen)..[0] = meta[0];
    return NetOutputs(policy, meta[0] * 10, meta[0] / 100);
  }

  @override
  Future<void> close() async => closed++;
}

void main() {
  test('every profile gets its own metadata row and its own evaluation', () async {
    final runner = RecordingRunner();
    final engine = ShapeEngine(runner);
    final pos = GoPosition(19, Rules.japanese);

    final out = await engine.analyze(pos, ['rank_5k', 'rank_2d', 'proyear_2023']);

    expect(out.keys, ['rank_5k', 'rank_2d', 'proyear_2023']);
    expect(runner.metasSeen.length, 3);

    // Different ranks must produce different metadata, or the whole point of the
    // human-SL net is lost -- three identical rows would look like a working app.
    expect(runner.metasSeen.map((m) => m.join(',')).toSet().length, 3,
        reason: 'profiles collapsed to the same metadata');
    for (final m in runner.metasSeen) {
      expect(m.length, kMetadataChannels);
    }
  });

  test('board features are computed once and shared across profiles', () async {
    final runner = RecordingRunner();
    final engine = ShapeEngine(runner);
    final pos = GoPosition(19, Rules.japanese);

    await engine.analyze(pos, ['rank_5k', 'rank_2d']);

    expect(runner.binsSeen.length, 2);
    expect(identical(runner.binsSeen[0], runner.binsSeen[1]), isTrue);
    expect(runner.binsSeen.first.length, kNumBinFeatures * 19 * 19);
  });

  test('each profile keeps the outputs of its own evaluation', () async {
    final runner = RecordingRunner();
    final engine = ShapeEngine(runner);
    final pos = GoPosition(19, Rules.japanese);

    final out = await engine.analyze(pos, ['rank_5k', 'rank_2d']);

    // The fake ties every output to the metadata it was given, so a mix-up between
    // profiles shows up as a mismatch here.
    for (final e in out.entries) {
      final tag = runner.metasSeen
          .firstWhere((m) => m[0] == e.value.policy.data[0])[0];
      expect(e.value.lead, closeTo(tag * 10, 1e-4));
      expect(e.value.winrate, closeTo(tag / 100, 1e-6));
    }
  });

  test('failures are described in words a status line can show', () {
    // What the platform channel actually hands back, wrapper and Java class name
    // and all, versus what belongs in front of a user.
    expect(
      describeFailure(
          'PlatformException(mnn, IllegalStateException: not supported on the '
          'Android emulator, null, null)'),
      'not supported on the Android emulator',
    );
    expect(describeFailure(StateError('engine went away')),
        'Bad state: engine went away');
    expect(describeFailure('plain trouble\nstack frame'), 'plain trouble');
  });

  test('provider name and close pass through to the runner', () async {
    final runner = RecordingRunner(label: 'MNN CPU');
    final engine = ShapeEngine(runner);
    expect(engine.provider, 'MNN CPU');
    await engine.close();
    expect(runner.closed, 1);
  });
}
