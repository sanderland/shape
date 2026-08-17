import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/engine/analysis.dart';
import 'package:goshape/engine/board.dart';

void main() {
  test('sampling includes pass but excludes illegal and off-board points', () {
    const posLen = 3;
    final board = Board(2, 2);
    board.play(Board.black, board.loc(0, 0));
    final data = Float32List(posLen * posLen + 1)
      ..[0] = 0.99 // occupied
      ..[1] = 0.4 // legal
      ..[2] = 1.0 // outside the 2x2 board
      ..[posLen * posLen] = 0.6; // pass
    final policy = PolicyData(data, posLen, board);

    final candidates = policy.sample(excludePass: false);

    expect(candidates.any((move) => move.isPass), isTrue);
    expect(candidates.any((move) => move.x == 0 && move.y == 0), isFalse);
    expect(candidates.any((move) => move.x == 2), isFalse);
    expect(policy.maxProb, closeTo(0.6, 1e-6),
        reason: 'illegal model output must not set the legal-policy scale');
  });
}
