import 'dart:math' as math;
import 'package:flutter/material.dart';

const int kBoardSize = 19;
const String kGtpCols = 'ABCDEFGHJKLMNOPQRST';

String idxToGtp(int i) {
  if (i == kBoardSize * kBoardSize) return 'pass';
  return '${kGtpCols[i % kBoardSize]}${kBoardSize - i ~/ kBoardSize}';
}

/// Draws the board, stones, and a policy heatmap.
/// `board[y][x]` is 'B', 'W' or '.'; `policy` is length 362 (row-major, last = pass).
class BoardPainter extends CustomPainter {
  final List<List<String>> board;
  final List<double>? policy;
  final int topN;

  BoardPainter({required this.board, this.policy, this.topN = 12});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = math.min(size.width, size.height) / (kBoardSize + 1);
    final origin = Offset(cell, cell);

    Offset pt(int x, int y) =>
        Offset(origin.dx + x * cell - cell / 2, origin.dy + y * cell - cell / 2);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFD2B48C),
    );

    final line = Paint()
      ..color = Colors.black87
      ..strokeWidth = 1.0;
    for (var i = 0; i < kBoardSize; i++) {
      canvas.drawLine(pt(0, i), pt(kBoardSize - 1, i), line);
      canvas.drawLine(pt(i, 0), pt(i, kBoardSize - 1), line);
    }

    final star = Paint()..color = Colors.black87;
    for (final y in [3, 9, 15]) {
      for (final x in [3, 9, 15]) {
        canvas.drawCircle(pt(x, y), cell * 0.09, star);
      }
    }

    // Heatmap under the stones so stones stay readable.
    if (policy != null) {
      final idx = List<int>.generate(kBoardSize * kBoardSize, (i) => i)
        ..sort((a, b) => policy![b].compareTo(policy![a]));
      final maxP = policy![idx.first];
      for (final i in idx.take(topN)) {
        final p = policy![i];
        if (p <= 0) continue;
        final x = i % kBoardSize, y = i ~/ kBoardSize;
        if (board[y][x] != '.') continue;
        final rel = p / maxP;
        final side = cell * (0.45 + 0.5 * rel);
        canvas.drawRect(
          Rect.fromCenter(center: pt(x, y), width: side, height: side),
          Paint()..color = Color.lerp(
              const Color(0xFF7FD98C), const Color(0xFF0B6E2E), rel)!
              .withValues(alpha: 0.55 + 0.4 * rel),
        );
        if (rel > 0.25) {
          final tp = TextPainter(
            text: TextSpan(
              text: (p * 100).toStringAsFixed(p >= 0.1 ? 0 : 1),
              style: TextStyle(
                color: Colors.white,
                fontSize: cell * 0.34,
                fontWeight: FontWeight.w700,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, pt(x, y) - Offset(tp.width / 2, tp.height / 2));
        }
      }
    }

    for (var y = 0; y < kBoardSize; y++) {
      for (var x = 0; x < kBoardSize; x++) {
        final s = board[y][x];
        if (s == '.') continue;
        final c = pt(x, y);
        canvas.drawCircle(c, cell * 0.47,
            Paint()..color = Colors.black.withValues(alpha: 0.25));
        canvas.drawCircle(
          c,
          cell * 0.46,
          Paint()..color = s == 'B' ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) =>
      old.policy != policy || old.board != board;
}
