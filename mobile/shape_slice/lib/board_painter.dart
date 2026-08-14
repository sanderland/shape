import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'engine/analysis.dart';
import 'engine/board.dart';

const String kGtpCols = 'ABCDEFGHJKLMNOPQRST';

String coordLabel(int x, int y, int size) => '${kGtpCols[x]}${size - y}';

/// Geometry shared by the painter and hit-testing, so a tap lands where it looks.
class BoardGeometry {
  final double cell;
  final Offset origin;
  final int size;

  BoardGeometry(Size canvas, this.size)
      : cell = math.min(canvas.width, canvas.height) / (size + 1),
        origin = Offset(
          math.min(canvas.width, canvas.height) / (size + 1),
          math.min(canvas.width, canvas.height) / (size + 1),
        );

  Offset point(int x, int y) =>
      Offset(origin.dx + x * cell - cell / 2, origin.dy + y * cell - cell / 2);

  /// Nearest intersection to a tap, or null if clearly off-board.
  (int, int)? hit(Offset local) {
    final x = ((local.dx - origin.dx + cell / 2) / cell).round();
    final y = ((local.dy - origin.dy + cell / 2) / cell).round();
    if (x < 0 || y < 0 || x >= size || y >= size) return null;
    final d = (local - point(x, y)).distance;
    if (d > cell * 0.75) return null;
    return (x, y);
  }
}

class BoardPainter extends CustomPainter {
  final Board board;
  final PolicyData? heatmap;
  final int topN;
  final (int, int)? lastMove;
  /// Move to ring in red (the one the feedback refers to), if any.
  final (int, int)? flaggedMove;

  BoardPainter({
    required this.board,
    this.heatmap,
    this.topN = 12,
    this.lastMove,
    this.flaggedMove,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = board.xSize;
    final g = BoardGeometry(size, n);
    final cell = g.cell;

    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFD2B48C));

    final line = Paint()
      ..color = Colors.black87
      ..strokeWidth = 1.0;
    for (var i = 0; i < n; i++) {
      canvas.drawLine(g.point(0, i), g.point(n - 1, i), line);
      canvas.drawLine(g.point(i, 0), g.point(i, n - 1), line);
    }

    final starCoords = n == 19
        ? [3, 9, 15]
        : n == 13
            ? [3, 6, 9]
            : n == 9
                ? [2, 4, 6]
                : <int>[];
    final star = Paint()..color = Colors.black87;
    for (final y in starCoords) {
      for (final x in starCoords) {
        canvas.drawCircle(g.point(x, y), cell * 0.09, star);
      }
    }

    // Heatmap under the stones, so stones stay readable.
    final h = heatmap;
    if (h != null && h.maxProb > 0) {
      final idx = <int>[];
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          if (board.board[board.loc(x, y)] == Board.empty) idx.add(y * n + x);
        }
      }
      idx.sort((a, b) =>
          h.probAt(b % n, b ~/ n).compareTo(h.probAt(a % n, a ~/ n)));
      for (final i in idx.take(topN)) {
        final x = i % n, y = i ~/ n;
        final p = h.probAt(x, y);
        if (p <= 0.001) continue;
        final rel = p / h.maxProb;
        final side = cell * (0.42 + 0.5 * rel);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: g.point(x, y), width: side, height: side),
            Radius.circular(cell * 0.08),
          ),
          Paint()
            ..color = Color.lerp(const Color(0xFF7FD98C), const Color(0xFF0B6E2E), rel)!
                .withValues(alpha: 0.5 + 0.4 * rel),
        );
        if (rel > 0.22) {
          _text(canvas, g.point(x, y), (p * 100).toStringAsFixed(p >= 0.095 ? 0 : 1),
              cell * 0.32, Colors.white);
        }
      }
    }

    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final s = board.board[board.loc(x, y)];
        if (s == Board.empty || s == Board.wall) continue;
        final c = g.point(x, y);
        canvas.drawCircle(c, cell * 0.47, Paint()..color = Colors.black.withValues(alpha: 0.22));
        canvas.drawCircle(
          c,
          cell * 0.46,
          Paint()..color = s == Board.black ? const Color(0xFF1A1A1A) : const Color(0xFFF7F7F7),
        );
      }
    }

    final lm = lastMove;
    if (lm != null) {
      final stone = board.board[board.loc(lm.$1, lm.$2)];
      canvas.drawCircle(
        g.point(lm.$1, lm.$2),
        cell * 0.20,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.07
          ..color = stone == Board.black ? Colors.white70 : Colors.black54,
      );
    }

    final fm = flaggedMove;
    if (fm != null) {
      canvas.drawCircle(
        g.point(fm.$1, fm.$2),
        cell * 0.34,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.09
          ..color = const Color(0xFFE53935),
      );
    }
  }

  void _text(Canvas canvas, Offset at, String s, double fontSize, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) => true;
}
