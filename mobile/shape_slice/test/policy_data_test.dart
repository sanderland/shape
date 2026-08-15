import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shape_slice/engine/analysis.dart';

void main() {
  test('opponent sampling can include pass', () {
    final policy = PolicyData(Float32List.fromList([0.4, 0, 0, 0, 0.6]), 2, 1);

    final candidates = policy.sample(excludePass: false);

    expect(candidates.any((move) => move.isPass), isTrue);
  });
}
