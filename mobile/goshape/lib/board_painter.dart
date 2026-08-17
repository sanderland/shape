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

  /// [origin] is the top-left intersection, placed so the margins around the grid
  /// are equal.
  BoardGeometry(Size canvas, this.size)
      : cell = math.min(canvas.width, canvas.height) / (size + 1),
        origin = Offset(
          (canvas.width - (size - 1) * (math.min(canvas.width, canvas.height) / (size + 1))) / 2,
          (canvas.height - (size - 1) * (math.min(canvas.width, canvas.height) / (size + 1))) / 2,
        );

  Offset point(int x, int y) => Offset(origin.dx + x * cell, origin.dy + y * cell);

  /// Nearest intersection, clamped to the board.
  ///
  /// Clamped rather than nullable because this drives a finger being dragged: the
  /// crosshair should stay on the nearest line when the finger strays into the
  /// margin, not blink out.
  (int, int) nearest(Offset local) => (
        ((local.dx - origin.dx) / cell).round().clamp(0, size - 1),
        ((local.dy - origin.dy) / cell).round().clamp(0, size - 1),
      );
}

/// How many heatmap moves to paint; more would be unreadable noise.
const int _kHeatmapTopN = 12;

class BoardPainter extends CustomPainter {
  final Board board;
  final PolicyData? heatmap;
  final (int, int)? lastMove;

  /// The move the feedback card is talking about, ringed in [markColor].
  ///
  /// Without it the only ring on the board is the last-move marker, which sits on
  /// the opponent's reply by the time you read the card -- so the card appeared to
  /// be describing their move rather than yours.
  final (int, int)? markedMove;
  final Color markColor;

  /// Intersection under the finger, drawn as full-width guide lines and a preview
  /// stone. A stone is a good deal smaller than a fingertip, so aiming happens
  /// while held and the move is placed on release.
  final (int, int)? crosshair;

  /// Colour of the preview stone: whose turn it is.
  final int crosshairPlayer;

  /// Continuations already in the tree, as small dots. Without these a branch is
  /// invisible: the board looks identical whether or not anything follows.
  final List<({int x, int y, Color color, bool main})> nextMoves;

  BoardPainter({
    required this.board,
    this.heatmap,
    this.lastMove,
    this.markedMove,
    this.markColor = const Color(0xFFE53935),
    this.crosshair,
    this.crosshairPlayer = Board.black,
    this.nextMoves = const [],
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
          if (h.isLegalAt(x, y)) idx.add(y * n + x);
        }
      }
      idx.sort((a, b) =>
          h.probAt(b % n, b ~/ n).compareTo(h.probAt(a % n, a ~/ n)));
      for (final i in idx.take(_kHeatmapTopN)) {
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

    final fm = markedMove;
    if (fm != null) {
      canvas.drawCircle(
        g.point(fm.$1, fm.$2),
        cell * 0.34,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.09
          ..color = markColor,
      );
    }

    for (final n in nextMoves) {
      final at = g.point(n.x, n.y);
      final r = cell * (n.main ? 0.20 : 0.15);
      canvas.drawCircle(at, r, Paint()..color = n.color.withValues(alpha: 0.9));
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, cell * 0.03)
          ..color = Colors.white70,
      );
    }

    final ch = crosshair;
    if (ch != null) {
      const guide = Color(0xFF8E24AA);
      final at = g.point(ch.$1, ch.$2);
      final guides = Paint()
        ..color = guide.withValues(alpha: 0.85)
        ..strokeWidth = math.max(1.5, cell * 0.07);
      canvas.drawLine(
          Offset(g.point(0, 0).dx, at.dy), Offset(g.point(n - 1, 0).dx, at.dy), guides);
      canvas.drawLine(
          Offset(at.dx, g.point(0, 0).dy), Offset(at.dx, g.point(0, n - 1).dy), guides);

      canvas.drawCircle(
        at,
        cell * 0.46,
        Paint()
          ..color = (crosshairPlayer == Board.black
                  ? const Color(0xFF1A1A1A)
                  : const Color(0xFFF7F7F7))
              .withValues(alpha: 0.75),
      );
      canvas.drawCircle(
        at,
        cell * 0.46,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, cell * 0.08)
          ..color = guide,
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
