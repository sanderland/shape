// SHAPE's game loop, ported: play a move, get rank-relative feedback, let a
// human-like opponent reply by sampling from the human-SL policy at its rank.
//
// Deviation from desktop SHAPE, stated plainly: desktop uses a separate KataGo net
// with search for `scoreLead`, and its "AI" heatmap is that net's raw policy. Only
// the human-SL net ships here, so the score axis uses the human net's own lead head
// evaluated at the target rank, and there is no AI reference policy. That makes
// "points lost" an approximation of desktop's mistake size, not the same number.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/analysis.dart';
import '../engine/board.dart';
import '../engine/features.dart';

/// Ranks offered, strongest last. Mirrors SHAPE's rank_* / proyear_* profiles.
const List<String> kRanks = [
  'rank_20k', 'rank_15k', 'rank_10k', 'rank_8k', 'rank_6k', 'rank_5k', 'rank_4k',
  'rank_3k', 'rank_2k', 'rank_1k', 'rank_1d', 'rank_2d', 'rank_3d', 'rank_4d',
  'rank_5d', 'rank_6d', 'rank_7d', 'rank_8d', 'rank_9d', 'proyear_2023',
];

String rankLabel(String profile) {
  if (profile.startsWith('rank_')) return profile.substring(5);
  if (profile.startsWith('proyear_')) return 'pro ${profile.substring(8)}';
  if (profile.startsWith('preaz_')) return '${profile.substring(6)} (pre-AZ)';
  return profile;
}

/// How the move just played looks to each rank.
class MoveFeedback {
  final int x;
  final int y;
  final double playerProb;
  final double playerRel;
  final double targetProb;
  final double targetRel;

  /// P(target rank | this move), the two-hypothesis posterior SHAPE shows.
  final double moveLikeTarget;

  /// Points lost, from the target rank's lead head. Null until both ends analyzed.
  final double? pointsLost;

  MoveFeedback({
    required this.x,
    required this.y,
    required this.playerProb,
    required this.playerRel,
    required this.targetProb,
    required this.targetRel,
    required this.moveLikeTarget,
    required this.pointsLost,
  });

  bool get isMistake => (pointsLost ?? 0) > 1.0;
  bool get targetWouldPlay => targetRel > 0.5;
}

class ShapeGame extends ChangeNotifier {
  final ShapeEngine engine;
  final int boardSize;
  final math.Random rng;

  GoPosition pos;
  final List<Move> _redo = [];

  /// analyses[moveCount][profile]
  final Map<int, Map<String, ProfileAnalysis>> analyses = {};

  String playerRank = 'rank_10k';
  String opponentRank = 'rank_10k';
  String targetRank = 'rank_5k';

  int humanColor = Board.black;
  bool autoplayOpponent = true;

  /// Sampler settings, matching SHAPE's defaults.
  int topK = 50;
  double topP = 1.0;
  double minP = 0.05;

  bool busy = false;
  String? error;
  MoveFeedback? lastFeedback;
  int analysisMs = 0;

  ShapeGame(this.engine, {this.boardSize = 19, math.Random? random})
      : rng = random ?? math.Random(),
        pos = GoPosition(boardSize, Rules.japanese);

  List<String> get activeProfiles =>
      {playerRank, opponentRank, targetRank}.toList();

  int get moveCount => pos.moves.length;
  bool get canUndo => pos.moves.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get humanToPlay => pos.nextPlayer == humanColor;
  bool get gameOver =>
      pos.moves.length >= 2 &&
      pos.moves[pos.moves.length - 1].isPass &&
      pos.moves[pos.moves.length - 2].isPass;

  Map<String, ProfileAnalysis>? get currentAnalysis => analyses[moveCount];

  ProfileAnalysis? analysisFor(String profile, {int? atMove}) =>
      analyses[atMove ?? moveCount]?[profile];

  Future<void> start() async {
    await _analyzeCurrent();
    await _maybeOpponentMove();
  }

  Future<void> _analyzeCurrent() async {
    final idx = moveCount;
    final want = activeProfiles.where((p) => !(analyses[idx]?.containsKey(p) ?? false)).toList();
    if (want.isEmpty) return;
    final sw = Stopwatch()..start();
    final result = await engine.analyze(pos, want);
    analysisMs = sw.elapsedMilliseconds;
    (analyses[idx] ??= {}).addAll(result);
  }

  /// Points the side that just moved gave up, per the target rank's lead head.
  ///
  /// `lead` is from the side-to-move's perspective, so the mover's lead after their
  /// move is -lead(next position) and the raw loss is before + after.
  ///
  /// Under territory scoring that raw figure carries a systematic +1.0 per stone:
  /// KataGo's selfKomi feature is `komi + blackNonPassMoves - whiteNonPassMoves`, so
  /// placing a stone shifts the frame by exactly one point (the Japanese convention
  /// that a stone played into your own area costs a point). Measured on the empty
  /// board: tengen 0.87, D4 0.96, Q16 1.14, versus B2 2.69 and A1 6.13 -- i.e. all
  /// reasonable moves sit at 1.0, not 0. Without this correction every normal move
  /// is reported as a ~1 point mistake.
  double? _pointsLost(int beforeIdx, {required bool wasPass}) {
    final before = analyses[beforeIdx]?[targetRank];
    final after = analyses[beforeIdx + 1]?[targetRank];
    if (before == null || after == null) return null;
    final raw = before.lead + after.lead;
    final territoryOffset =
        (pos.rules.scoringRule == 'SCORING_TERRITORY' && !wasPass) ? 1.0 : 0.0;
    return raw - territoryOffset;
  }

  bool isLegal(int x, int y) {
    final loc = coordsToLoc(pos.board, x, y);
    if (loc == null) return false;
    return pos.board.wouldBeLegal(pos.nextPlayer, loc);
  }

  Future<void> playAt(int x, int y) async {
    final loc = coordsToLoc(pos.board, x, y);
    if (loc == null) return;
    await _play(loc);
  }

  Future<void> pass() => _play(Board.passLoc);

  Future<void> _play(int loc) async {
    if (busy) return;
    if (!pos.board.wouldBeLegal(pos.nextPlayer, loc)) {
      error = 'Illegal move';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();

    try {
      final beforeIdx = moveCount;
      final mover = pos.nextPlayer;
      final beforeAnalysis = analyses[beforeIdx];

      pos.play(mover, loc);
      _redo.clear();
      await _analyzeCurrent();

      // Feedback only for real moves by the human, and only if we evaluated before.
      if (loc != Board.passLoc && mover == humanColor && beforeAnalysis != null) {
        final x = pos.board.locX(loc);
        final y = pos.board.locY(loc);
        final player = beforeAnalysis[playerRank];
        final target = beforeAnalysis[targetRank];
        if (player != null && target != null) {
          final (pProb, pRel) = player.policy.at(x, y);
          final (tProb, tRel) = target.policy.at(x, y);
          lastFeedback = MoveFeedback(
            x: x,
            y: y,
            playerProb: pProb,
            playerRel: pRel,
            targetProb: tProb,
            targetRel: tRel,
            moveLikeTarget: tProb / math.max(pProb + tProb, 1e-10),
            pointsLost: _pointsLost(beforeIdx, wasPass: false),
          );
        }
      } else if (mover == humanColor) {
        lastFeedback = null;
      }
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }

    await _maybeOpponentMove();
  }

  Future<void> _maybeOpponentMove() async {
    if (!autoplayOpponent || gameOver || humanToPlay || busy) return;
    busy = true;
    notifyListeners();
    try {
      await _analyzeCurrent();
      final analysis = analyses[moveCount]?[opponentRank];
      if (analysis != null) {
        final candidates = analysis.policy.sample(topK: topK, topP: topP, minP: minP);
        final choice = analysis.policy.pick(candidates, rng);
        final loc = (choice == null || choice.isPass)
            ? Board.passLoc
            : pos.board.loc(choice.x!, choice.y!);
        // The sampler can offer a move that is illegal (ko); fall back to the next best.
        if (loc != Board.passLoc && !pos.board.wouldBeLegal(pos.nextPlayer, loc)) {
          final legal = candidates.firstWhere(
            (m) => !m.isPass && pos.board.wouldBeLegal(pos.nextPlayer, pos.board.loc(m.x!, m.y!)),
            orElse: () => const PolicyMove(null, null, 0),
          );
          pos.play(pos.nextPlayer,
              legal.isPass ? Board.passLoc : pos.board.loc(legal.x!, legal.y!));
        } else {
          pos.play(pos.nextPlayer, loc);
        }
        _redo.clear();
        await _analyzeCurrent();
      }
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Undo back to the human's turn (so one full exchange, normally).
  Future<void> undo() async {
    if (busy || !canUndo) return;
    busy = true;
    notifyListeners();
    try {
      do {
        _redo.add(pos.moves.last);
        pos.undo();
      } while (pos.moves.isNotEmpty && !humanToPlay && autoplayOpponent);
      lastFeedback = null;
      await _analyzeCurrent();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> redo() async {
    if (busy || !canRedo) return;
    busy = true;
    notifyListeners();
    try {
      final m = _redo.removeLast();
      pos.play(m.pla, m.loc);
      await _analyzeCurrent();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> newGame({int? size}) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    pos = GoPosition(size ?? boardSize, Rules.japanese);
    _redo.clear();
    analyses.clear();
    lastFeedback = null;
    error = null;
    busy = false;
    notifyListeners();
    await start();
  }

  Future<void> setRanks({String? player, String? opponent, String? target}) async {
    playerRank = player ?? playerRank;
    opponentRank = opponent ?? opponentRank;
    targetRank = target ?? targetRank;
    notifyListeners();
    if (!busy) {
      busy = true;
      notifyListeners();
      try {
        await _analyzeCurrent();
      } finally {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// SGF for the current line.
  String toSgf() {
    final b = StringBuffer('(;GM[1]FF[4]CA[UTF-8]SZ[$boardSize]KM[6.5]RU[Japanese]');
    b.write('PB[${humanColor == Board.black ? rankLabel(playerRank) : rankLabel(opponentRank)}]');
    b.write('PW[${humanColor == Board.white ? rankLabel(playerRank) : rankLabel(opponentRank)}]');
    for (final m in pos.moves) {
      final tag = m.pla == Board.black ? 'B' : 'W';
      if (m.isPass) {
        b.write(';$tag[]');
      } else {
        final x = pos.board.locX(m.loc);
        final y = pos.board.locY(m.loc);
        b.write(';$tag[${String.fromCharCode(97 + x)}${String.fromCharCode(97 + y)}]');
      }
    }
    b.write(')');
    return b.toString();
  }
}
