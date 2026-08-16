// The cards under the board.
//
// Their own widgets rather than methods on the page because the wording is the
// part of this app most worth pinning down, and a widget can be rendered in a test
// without a device or a model behind it.

import 'package:flutter/material.dart';

import 'board_painter.dart';
import 'game/shape_game.dart';

class FeedbackCard extends StatelessWidget {
  final MoveFeedback? feedback;
  final String playerRank;
  final String targetRank;
  final int boardSize;

  const FeedbackCard({
    super.key,
    required this.feedback,
    required this.playerRank,
    required this.targetRank,
    required this.boardSize,
  });

  @override
  Widget build(BuildContext context) {
    final fb = feedback;
    if (fb == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Feedback appears here after you move: how often '
            '${rankLabel(playerRank)} and ${rankLabel(targetRank)} play it, '
            'and what it cost.',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
      );
    }

    final pl = fb.pointsLost;
    final points = pl == null ? '' : pl.abs().toStringAsFixed(1);

    // Every headline states what the numbers support and stops there. The cost
    // leads whenever there is one, because a card that opens with a verdict and
    // buries "lost 2.3 points" underneath is telling the player less than it knows.
    final (color, headline, icon) = switch (fb.verdict) {
      MoveVerdict.mistake => (
          const Color(0xFFE53935),
          'Lost $points points',
          Icons.warning_amber,
        ),
      MoveVerdict.costly => (
          const Color(0xFFEF6C00),
          fb.targetPlaysItToo
              ? 'Lost $points points, but ${rankLabel(targetRank)} plays it too'
              : 'Lost $points points',
          Icons.warning_amber,
        ),
      MoveVerdict.aboveYourLevel => (
          const Color(0xFF0B6E2E),
          // What the posterior actually measures, and nothing more. It also stays
          // true when the target rank is set below your own.
          'More ${rankLabel(targetRank)} than ${rankLabel(playerRank)}',
          Icons.check_circle_outline,
        ),
      MoveVerdict.typical => (
          const Color(0xFF37474F),
          fb.isRare ? 'Rare at both ranks' : 'Nothing to flag',
          null,
        ),
    };

    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text('${coordLabel(fb.x, fb.y, boardSize)} · $headline',
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
          const SizedBox(height: 8),
          _bar(rankLabel(playerRank), fb.playerProb, fb.playerRel),
          _bar(rankLabel(targetRank), fb.targetProb, fb.targetRel),
          // The posterior is a number derived from the two directly above it, and
          // its only job is to pick the headline, which is already there in words.
          if (pl != null && fb.verdict != MoveVerdict.mistake &&
              fb.verdict != MoveVerdict.costly)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${pl >= 0 ? "−" : "+"}$points pts',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          if (fb.isRare && fb.verdict == MoveVerdict.mistake)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Under 1% at both ranks.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
        ]),
      ),
    );
  }

  Widget _bar(String label, double prob, double rel) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 52, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: rel.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: Colors.black12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 46,
            child: Text('${(prob * 100).toStringAsFixed(1)}%',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ]),
      );

}

/// Announces the things that happen without a stone appearing on the board.
///
/// A pass and the end of the game both change everything and look like nothing, so
/// neither can be left to a line of grey monospace under the controls.
class GameNotice extends StatelessWidget {
  final bool gameOver;
  final bool opponentPassed;
  final String opponentRank;

  /// Points for Black, from the net's lead head. Null until evaluated.
  final double? scoreLeadForBlack;

  const GameNotice({
    super.key,
    required this.gameOver,
    required this.opponentPassed,
    required this.opponentRank,
    required this.scoreLeadForBlack,
  });

  /// "B+12.5", or null when there is no estimate yet.
  static String? scoreLabel(double? leadForBlack) {
    if (leadForBlack == null) return null;
    final s = leadForBlack.abs().toStringAsFixed(1);
    return '${leadForBlack >= 0 ? "B" : "W"}+$s';
  }

  @override
  Widget build(BuildContext context) {
    if (!gameOver && !opponentPassed) return const SizedBox.shrink();

    final score = scoreLabel(scoreLeadForBlack);
    final (color, icon, title, detail) = gameOver
        ? (
            const Color(0xFF37474F),
            Icons.flag_outlined,
            score == null ? 'Game over' : 'Game over · $score',
            'Both players passed. Score estimated by the net, without search.',
          )
        : (
            const Color(0xFF00695C),
            Icons.skip_next,
            '${rankLabel(opponentRank)} passed',
            'Pass again to end the game.',
          );

    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
              Text(detail,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
          ),
        ]),
      ),
    );
  }
}
