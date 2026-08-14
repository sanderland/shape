// Gate for the Dart port of KataGo's board.py + features.py.
//
// Compares bin_input (22 planes) and global_input (19) against fixtures generated
// by the Python original (tools/onnx_export/export_fixtures.py) for positions
// chosen to break a naive port: ladders, ko, captures, passes, several sizes.
//
// Exact equality is required -- these are the tensors fed to the net, and a single
// wrong plane yields a plausible-looking but wrong policy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shape_slice/engine/board.dart';
import 'package:shape_slice/engine/features.dart';

void main() {
  final raw = jsonDecode(File('assets/featurizer_fixtures.json').readAsStringSync())
      as Map<String, dynamic>;
  final posLen = raw['posLen'] as int;
  final cases = (raw['cases'] as List).cast<Map<String, dynamic>>();
  final features = Features(posLen);

  test('fixture file covers the awkward cases', () {
    expect(cases.length, greaterThanOrEqualTo(15));
    final names = cases.map((c) => c['name'] as String).toList();
    expect(names.any((n) => n.startsWith('ko')), isTrue, reason: 'need a ko fixture');
    expect(names.any((n) => n.contains('pass')), isTrue, reason: 'need a pass fixture');
    expect(cases.map((c) => c['boardSize']).toSet().length, greaterThan(1));
  });

  GoPosition build(Map<String, dynamic> c) {
    final size = c['boardSize'] as int;
    final rules = Rules.fromName(c['ruleset'] as String);
    final pos = GoPosition(size, rules);
    var pla = Board.black;
    for (final mv in (c['moves'] as List).cast<String>()) {
      pos.play(pla, mv == 'pass' ? Board.passLoc : gtpToLoc(mv, pos.board));
      pla = Board.getOpp(pla);
    }
    return pos;
  }

  for (final c in cases) {
    final name = c['name'] as String;
    final ruleset = c['ruleset'] as String;

    // Area scoring needs pass-alive, which is deliberately not ported; the featurizer
    // must refuse loudly rather than emit zeroed area planes.
    if (ruleset == 'chinese') {
      test('$name (area scoring) throws rather than emitting wrong features', () {
        final pos = build(c);
        expect(() => features.fillRowFeatures(pos), throwsUnimplementedError);
      });
      continue;
    }

    test('features match KataGo: $name', () {
      final pos = build(c);

      final expectedNextPlayer = c['nextPlayer'] == 'B' ? Board.black : Board.white;
      expect(pos.nextPlayer, expectedNextPlayer, reason: 'next player');

      final result = features.fillRowFeatures(pos);
      final expectedBin = base64Decode(c['binB64'] as String);
      final expectedGlobal = (c['global'] as List).map((e) => (e as num).toDouble()).toList();

      expect(result.bin.length, expectedBin.length, reason: 'bin length');
      expect(result.global.length, expectedGlobal.length, reason: 'global length');

      // Report the first mismatch as plane/x/y -- a raw index is useless to debug.
      final area = posLen * posLen;
      for (var i = 0; i < expectedBin.length; i++) {
        if (result.bin[i] != expectedBin[i].toDouble()) {
          final plane = i ~/ area;
          final p = i % area;
          fail('bin mismatch in $name: plane $plane at (x=${p % posLen}, y=${p ~/ posLen}) '
              'got ${result.bin[i]} want ${expectedBin[i]}');
        }
      }

      for (var i = 0; i < expectedGlobal.length; i++) {
        expect(result.global[i], closeTo(expectedGlobal[i], 1e-6),
            reason: 'global[$i] in $name');
      }
    });
  }

  test('board legality: ko recapture and single-stone suicide are refused', () {
    final pos = GoPosition(9, Rules.japanese);
    final b = pos.board;
    // Surround a point so a lone black stone there would be single-stone suicide.
    for (final gtp in ['D5', 'C4', 'E4', 'D3']) {
      pos.play(Board.white, gtpToLoc(gtp, b));
      pos.play(Board.black, gtpToLoc('A9', b)); // filler, undone below
      pos.undo();
    }
    expect(pos.board.wouldBeLegal(Board.black, gtpToLoc('D4', pos.board)), isFalse);
    expect(pos.board.wouldBeLegal(Board.white, gtpToLoc('D4', pos.board)), isTrue);
  });
}
