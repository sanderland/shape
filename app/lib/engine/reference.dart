// The fixed position the app checks itself against at startup.
//
// Shipped in assets/position.bin with the expected outputs in assets/reference.json,
// both produced by the export tool. Engine startup runs it once to confirm this
// device computes the net correctly, because a net that is quietly wrong produces
// feedback that looks entirely plausible and is not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'features.dart';

/// Tolerance for matching the saved reference. fp32 rounding lands around 1e-5;
/// anything near 1e-3 means the runtime is doing its own thing, and a wrong top
/// move means it is broken outright.
const double kReferenceTolerance = 1e-3;

/// How far this device's output strayed from the saved reference.
class ReferenceCheck {
  /// Largest disagreement over the reference's highest-rated moves.
  final double maxDiff;
  final bool topMoveOk;
  const ReferenceCheck(this.maxDiff, this.topMoveOk);

  bool get ok => topMoveOk && maxDiff < kReferenceTolerance;

  @override
  String toString() => topMoveOk
      ? (ok ? 'ok' : 'differs ${maxDiff.toStringAsExponential(0)}')
      : 'WRONG MOVE';
}

class ReferencePosition {
  final Float32List bin;
  final Float32List global;
  final Float32List meta;
  final int expectedTopIndex;
  final Map<int, double> expectedPolicy;

  ReferencePosition(
    this.bin,
    this.global,
    this.meta,
    this.expectedTopIndex,
    this.expectedPolicy,
  );

  /// Which profile the reference outputs were generated under.
  static const String profile = 'rank_5k';

  static Future<ReferencePosition> load() async {
    final raw = await rootBundle.load('assets/position.bin');
    const binLen = kNumBinFeatures * 19 * 19;
    final all = raw.buffer.asFloat32List(raw.offsetInBytes, binLen + kNumGlobalFeatures);
    final ref =
        jsonDecode(await rootBundle.loadString('assets/reference.json')) as Map<String, dynamic>;
    final p = (ref['profiles'] as Map)[profile] as Map<String, dynamic>;
    final top = (p['top'] as List).cast<Map<String, dynamic>>();
    return ReferencePosition(
      Float32List.fromList(all.sublist(0, binLen)),
      Float32List.fromList(all.sublist(binLen)),
      Float32List.fromList((p['meta'] as List).map((e) => (e as num).toDouble()).toList()),
      top.first['idx'] as int,
      {for (final e in top) e['idx'] as int: (e['p'] as num).toDouble()},
    );
  }

  ReferenceCheck check(List<double> policy) {
    var worst = 0.0;
    expectedPolicy.forEach((idx, p) {
      final d = (policy[idx] - p).abs();
      if (d > worst) worst = d;
    });
    var best = 0;
    for (var i = 1; i < policy.length; i++) {
      if (policy[i] > policy[best]) best = i;
    }
    return ReferenceCheck(worst, best == expectedTopIndex);
  }
}
