// SHAPE's game loop, ported: play a move, get rank-relative feedback, let a
// human-like opponent reply by sampling from the human-SL policy at its rank.
//
// Deviation from desktop SHAPE, stated plainly: desktop uses a separate KataGo net
// with search for `scoreLead`, and its "AI" heatmap is that net's raw policy. Only
// the human-SL net ships here, so the score axis uses the human net's lead head at
// the strongest available profile. That approximates desktop's mistake size rather
// than reproducing it.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/analysis.dart';
import '../engine/board.dart';
import '../engine/features.dart';

/// Ranks offered, weakest first.
const List<String> kRanks = [
  'rank_20k', 'rank_15k', 'rank_10k', 'rank_8k', 'rank_6k', 'rank_5k', 'rank_4k',
  'rank_3k', 'rank_2k', 'rank_1k', 'rank_1d', 'rank_2d', 'rank_3d', 'rank_4d',
  'rank_5d', 'rank_6d', 'rank_7d', 'rank_8d', 'rank_9d', 'proyear_2023',
];

/// Strongest profile the net offers; used for the score estimate rather than the
/// player's own rank, so "points lost" doesn't move when you change your rank.
const String kReferenceProfile = 'proyear_2023';

/// Desktop SHAPE's thresholds (shape/ui/tab_config.py: should_halt_on_mistake).
const double kMistakeSizePoints = 1.0;
const double kTargetRankThreshold = 0.20;
const double kMaxProbThreshold = 0.01;

String rankLabel(String profile) {
  if (profile.startsWith('rank_')) return profile.substring(5);
  if (profile.startsWith('proyear_')) return 'pro ${profile.substring(8)}';
  if (profile.startsWith('preaz_')) return '${profile.substring(6)} (pre-AZ)';
  return profile;
}

enum MoveVerdict { mistake, aboveYourLevel, typical }

/// How the move just played looks to each rank.
class MoveFeedback {
  final int x;
  final int y;
  final double playerProb;
  final double playerRel;
  final double targetProb;
  final double targetRel;

  /// P(target rank | this move): the two-hypothesis posterior SHAPE shows.
  final double moveLikeTarget;

  /// Points lost per the reference profile's lead head. Null until both ends analyzed.
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

  double get maxProb => math.max(playerProb, targetProb);
  bool get isRare => maxProb < kMaxProbThreshold;
  bool get costly => (pointsLost ?? 0) > kMistakeSizePoints;

  /// Desktop's rule: a big loss only counts as a mistake worth flagging if the move
  /// is either unlike your target rank or one almost nobody plays. A costly move the
  /// target rank would happily play is a level-appropriate move, not a blunder.
  MoveVerdict get verdict {
    if (costly && (isRare || moveLikeTarget < kTargetRankThreshold)) {
      return MoveVerdict.mistake;
    }
    if (moveLikeTarget >= 0.5) return MoveVerdict.aboveYourLevel;
    return MoveVerdict.typical;
  }

  bool get isMistake => verdict == MoveVerdict.mistake;
}

class ShapeGame extends ChangeNotifier {
  final ShapeEngine engine;
  final int boardSize;
  final math.Random rng;

  /// The whole game; [cursor] is how many of these are on the board.
  final List<Move> line = [];
  int cursor = 0;
  late GoPosition pos;

  /// analyses[moveIndex][profile]
  final Map<int, Map<String, ProfileAnalysis>> analyses = {};

  String playerRank = 'rank_5k';
  String opponentRank = 'rank_1k';
  String targetRank = 'rank_2d';

  int humanColor = Board.black;
  bool autoplayOpponent = true;

  /// When off, only the opponent's profile is evaluated: no heatmap, no feedback,
  /// and one net call per position instead of four.
  bool hintsEnabled = true;

  /// Sampler settings, matching SHAPE's defaults.
  int topK = 50;
  double topP = 1.0;
  double minP = 0.05;

  bool busy = false;
  String? error;
  MoveFeedback? feedback;
  int analysisMs = 0;

  ShapeGame(this.engine, {this.boardSize = 19, math.Random? random})
      : rng = random ?? math.Random() {
    pos = GoPosition(boardSize, Rules.japanese);
  }

  List<String> get activeProfiles => hintsEnabled
      ? {playerRank, targetRank, opponentRank, kReferenceProfile}.toList()
      : {opponentRank}.toList();

  /// Profiles needed to describe a move already played (no opponent sampling).
  List<String> get _feedbackProfiles =>
      {playerRank, targetRank, kReferenceProfile}.toList();

  bool get atTip => cursor == line.length;
  bool get canGoBack => cursor > 0;
  bool get canGoForward => cursor < line.length;
  bool get humanToPlay => pos.nextPlayer == humanColor;
  bool get gameOver =>
      cursor >= 2 && line[cursor - 1].isPass && line[cursor - 2].isPass;

  ProfileAnalysis? analysisFor(String profile, {int? atMove}) =>
      analyses[atMove ?? cursor]?[profile];

  GoPosition _positionAt(int idx) {
    final p = GoPosition(boardSize, Rules.japanese);
    for (var i = 0; i < idx; i++) {
      p.play(line[i].pla, line[i].loc);
    }
    return p;
  }

  Future<void> start() async {
    await _analyzeCurrent();
    await _maybeOpponentMove();
  }

  Future<void> _analyze(int idx, GoPosition p, List<String> profiles) async {
    final want =
        profiles.where((x) => !(analyses[idx]?.containsKey(x) ?? false)).toList();
    if (want.isEmpty) return;
    final sw = Stopwatch()..start();
    final result = await engine.analyze(p, want);
    analysisMs = sw.elapsedMilliseconds;
    (analyses[idx] ??= {}).addAll(result);
  }

  Future<void> _analyzeCurrent() => _analyze(cursor, pos, activeProfiles);

  /// Points the side that just moved gave up, per the reference profile.
  ///
  /// `lead` is from the side-to-move's perspective, so the raw loss is
  /// leadBefore + leadAfter. Under territory scoring that carries a systematic
  /// +1.0 per stone, because KataGo's selfKomi is
  /// `komi + blackNonPassMoves - whiteNonPassMoves` -- the Japanese convention that
  /// a stone costs a point. Measured on the empty board: tengen 0.87, D4 0.96,
  /// Q16 1.14, against B2 2.69 and A1 6.13. Without this every normal move reads as
  /// a ~1 point mistake.
  double? _pointsLost(int beforeIdx, {required bool wasPass}) {
    final before = analyses[beforeIdx]?[kReferenceProfile];
    final after = analyses[beforeIdx + 1]?[kReferenceProfile];
    if (before == null || after == null) return null;
    final offset =
        (pos.rules.scoringRule == 'SCORING_TERRITORY' && !wasPass) ? 1.0 : 0.0;
    return before.lead + after.lead - offset;
  }

  /// Describe the move that produced the current position, if it was the human's.
  Future<void> _updateFeedback() async {
    feedback = null;
    if (!hintsEnabled || cursor == 0) return;
    final move = line[cursor - 1];
    if (move.pla != humanColor || move.isPass) return;

    final beforeIdx = cursor - 1;
    // Browsing back to an old move may land on a position we never evaluated.
    await _analyze(beforeIdx, _positionAt(beforeIdx), _feedbackProfiles);
    await _analyze(cursor, pos, _feedbackProfiles);

    final before = analyses[beforeIdx];
    final player = before?[playerRank];
    final target = before?[targetRank];
    if (player == null || target == null) return;

    final board = _positionAt(beforeIdx).board;
    final x = board.locX(move.loc);
    final y = board.locY(move.loc);
    final (pProb, pRel) = player.policy.at(x, y);
    final (tProb, tRel) = target.policy.at(x, y);
    feedback = MoveFeedback(
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
      // Playing while browsing history discards the moves after here.
      if (!atTip) line.removeRange(cursor, line.length);
      final mover = pos.nextPlayer;
      pos.play(mover, loc);
      line.add(Move(mover, loc));
      cursor = line.length;
      await _analyzeCurrent();
      await _updateFeedback();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }

    await _maybeOpponentMove();
  }

  Future<void> _maybeOpponentMove() async {
    if (!autoplayOpponent || gameOver || humanToPlay || busy || !atTip) return;
    busy = true;
    notifyListeners();
    try {
      await _analyze(cursor, pos, [opponentRank]);
      final analysis = analyses[cursor]?[opponentRank];
      if (analysis != null) {
        final candidates = analysis.policy.sample(topK: topK, topP: topP, minP: minP);
        final choice = analysis.policy.pick(candidates, rng);
        var loc = (choice == null || choice.isPass)
            ? Board.passLoc
            : pos.board.loc(choice.x!, choice.y!);
        // The sampler can offer an illegal move (ko); fall back to the best legal one.
        if (loc != Board.passLoc && !pos.board.wouldBeLegal(pos.nextPlayer, loc)) {
          final legal = candidates.firstWhere(
            (m) => !m.isPass &&
                pos.board.wouldBeLegal(pos.nextPlayer, pos.board.loc(m.x!, m.y!)),
            orElse: () => const PolicyMove(null, null, 0),
          );
          loc = legal.isPass ? Board.passLoc : pos.board.loc(legal.x!, legal.y!);
        }
        final mover = pos.nextPlayer;
        pos.play(mover, loc);
        line.add(Move(mover, loc));
        cursor = line.length;
        await _analyzeCurrent();
      }
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ---- navigation ----

  Future<void> _goTo(int target) async {
    if (busy) return;
    final t = target.clamp(0, line.length);
    if (t == cursor) return;
    busy = true;
    notifyListeners();
    try {
      cursor = t;
      pos = _positionAt(cursor);
      await _analyzeCurrent();
      await _updateFeedback();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> goFirst() => _goTo(0);
  Future<void> goLast() => _goTo(line.length);

  /// Step back one exchange, so you land on your own move rather than the reply.
  Future<void> goPrev() => _goTo(cursor - (autoplayOpponent && cursor >= 2 ? 2 : 1));
  Future<void> goNext() => _goTo(cursor + (autoplayOpponent && cursor + 2 <= line.length ? 2 : 1));

  Future<void> newGame({int? size}) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    line.clear();
    cursor = 0;
    analyses.clear();
    feedback = null;
    error = null;
    pos = GoPosition(size ?? boardSize, Rules.japanese);
    busy = false;
    notifyListeners();
    await start();
  }

  Future<void> setHints(bool enabled) async {
    if (hintsEnabled == enabled) return;
    hintsEnabled = enabled;
    notifyListeners();
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      if (enabled) {
        await _analyzeCurrent();
        await _updateFeedback();
      } else {
        feedback = null;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> setRanks({String? player, String? opponent, String? target}) async {
    playerRank = player ?? playerRank;
    opponentRank = opponent ?? opponentRank;
    targetRank = target ?? targetRank;
    notifyListeners();
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await _analyzeCurrent();
      await _updateFeedback();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// SGF for the whole game, not just the browsed prefix.
  String toSgf() {
    final b = StringBuffer('(;GM[1]FF[4]CA[UTF-8]SZ[$boardSize]KM[6.5]RU[Japanese]');
    b.write('PB[${humanColor == Board.black ? rankLabel(playerRank) : rankLabel(opponentRank)}]');
    b.write('PW[${humanColor == Board.white ? rankLabel(playerRank) : rankLabel(opponentRank)}]');
    final full = _positionAt(0).board;
    for (final m in line) {
      final tag = m.pla == Board.black ? 'B' : 'W';
      if (m.isPass) {
        b.write(';$tag[]');
      } else {
        final x = full.locX(m.loc);
        final y = full.locY(m.loc);
        b.write(';$tag[${String.fromCharCode(97 + x)}${String.fromCharCode(97 + y)}]');
      }
    }
    b.write(')');
    return b.toString();
  }
}
