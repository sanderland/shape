// Geometry and painting, at every board size the app offers.
//
// The net is always 19x19 while the board may be 9 or 13, so the two sizes are
// easy to confuse: a policy is indexed by the tensor's width and the board by its
// own. Painting a smaller board with a heatmap is where that would show up.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/board_painter.dart';
import 'package:goshape/engine/analysis.dart';
import 'package:goshape/engine/board.dart';
import 'package:goshape/game/shape_game.dart';

const int posLen = 19;

PolicyData policyOver(Board board) {
  final boardSize = board.xSize;
  final data = Float32List(posLen * posLen + 1);
  var v = 1.0;
  for (var y = 0; y < boardSize; y++) {
    for (var x = 0; x < boardSize; x++) {
      data[y * posLen + x] = v;
      v *= 0.97;
    }
  }
  return PolicyData(data, posLen, board);
}

void main() {
  for (final size in kBoardSizes) {
    test('geometry round-trips every intersection on $size x $size', () {
      const canvas = Size(400, 400);
      final g = BoardGeometry(canvas, size);

      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          expect(g.nearest(g.point(x, y)), (x, y));
        }
      }

      // Equal margins: the grid must sit centred, not half a cell off.
      final left = g.point(0, 0).dx;
      final right = canvas.width - g.point(size - 1, 0).dx;
      expect(left, closeTo(right, 0.01));
    });

    test('a tap in the margin clamps to the nearest line on $size x $size', () {
      final g = BoardGeometry(const Size(400, 400), size);
      expect(g.nearest(Offset.zero), (0, 0));
      expect(g.nearest(const Offset(400, 400)), (size - 1, size - 1));
      expect(g.nearest(const Offset(-50, -50)), (0, 0));
    });

    testWidgets('paints $size x $size with heatmap, crosshair and markers', (
      tester,
    ) async {
      final board = Board(size, size);
      board.play(Board.black, board.loc(2, 2));
      board.play(Board.white, board.loc(3, 3));

      final painter = BoardPainter(
        board: board,
        heatmap: policyOver(board),
        lastMove: (3, 3),
        markedMove: (2, 2),
        markColor: const Color(0xFFEF6C00),
        crosshair: (size - 1, size - 1),
        crosshairPlayer: Board.black,
      );

      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(400, 400));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
      picture.dispose();
    });
  }

  test('a policy is read by board coordinates, not tensor coordinates', () {
    // On a 9x9 board, (8,0) is the top-right corner; reading it at tensor width 19
    // would land on a point that is off the board entirely.
    final p = policyOver(Board(9, 9));
    expect(p.probAt(8, 0), greaterThan(0));
    expect(p.probAt(0, 1), greaterThan(0));
    expect(p.sample(excludePass: true).length, 81);
  });
}
