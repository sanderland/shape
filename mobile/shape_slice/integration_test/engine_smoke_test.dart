// On-device smoke test for the ONNX engine paths that unit tests cannot reach:
// real session creation, the sequential-vs-batched agreement, and the benchmark.
//
// Run on an emulator or device:
//   flutter test integration_test/engine_smoke_test.dart -d <device>
//
// The emulator is fine for *correctness* here; its timings are meaningless
// (its NNAPI is a software stub), so never read performance off this test.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shape_slice/engine/analysis.dart';
import 'package:shape_slice/engine/features.dart';

const kModelAsset = 'assets/b18c384nbt-humanv0.onnx';

GoPosition _midgamePosition() {
  final pos = GoPosition(19, Rules.japanese);
  final moves = [(3, 3), (15, 15), (15, 3), (3, 15), (16, 5), (13, 2)];
  for (final (x, y) in moves) {
    pos.play(pos.nextPlayer, pos.board.loc(x, y));
  }
  return pos;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sequential and batched analysis agree', (tester) async {
    final engine = await ShapeEngine.load(kModelAsset);
    final pos = _midgamePosition();
    const profiles = ShapeEngine.benchmarkProfiles;

    final seq = await engine.analyze(pos, profiles);
    engine.useBatchedAnalysis = true;
    final batched = await engine.analyze(pos, profiles);

    for (final p in profiles) {
      final s = seq[p]!;
      final b = batched[p]!;
      expect(b.lead, closeTo(s.lead, 1e-3), reason: '$p lead');
      expect(b.winrate, closeTo(s.winrate, 1e-4), reason: '$p winrate');
      var maxDiff = 0.0;
      for (var i = 0; i < s.policy.data.length; i++) {
        maxDiff = math.max(maxDiff, (s.policy.data[i] - b.policy.data[i]).abs());
      }
      expect(maxDiff, lessThan(1e-4), reason: '$p policy');
      // Sanity: a real distribution, not zeros.
      expect(s.policy.maxProb, greaterThan(0.01), reason: '$p policy degenerate');
    }
    await engine.session.close();
  });

  testWidgets('benchmark runs every row without crashing', (tester) async {
    final results = await ShapeEngine.benchmarkProviders(
      kModelAsset,
      _midgamePosition(),
      reps: 1,
    );
    // Providers may legitimately be unavailable, but the CPU-based rows must work.
    for (final r in results.where((r) => r.provider.startsWith('CPU') || r.provider.startsWith('featurizer'))) {
      expect(r.ok, isTrue, reason: '${r.provider}: ${r.error}');
    }
    expect(results.map((r) => r.provider), contains('CPU batch x4 /pos'));
  });
}
