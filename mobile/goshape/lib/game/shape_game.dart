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

/// Posterior needed to call a move "above your level" — 0.667, i.e. the target
/// rank is twice as likely to play it as your rank.
///
/// This was 0.5, which is the point of *no evidence*: a move both ranks like
/// equally cleared it. Calibrated over 80 positions of realistic rank_5k
/// self-play (tools/onnx_export/calibrate_verdict.py), player 5k / target 2d,
/// showing the fraction of moves each rank would really play that clear a
/// given threshold:
///
///   threshold   flags 5k moves   flags 2d moves   lift
///   0.50             38.8%            75.0%       1.94   <- was here
///   0.60              7.5%            43.8%       5.83
///   0.667             2.5%            26.2%      10.50   <- now here
///
/// At 0.5 nearly two in five of the player's own ordinary moves were praised.
const double kAboveTargetThreshold = 0.667;

/// How often the target rank must actually play a move before "your target plays
/// it too" is worth saying. The posterior is a ratio, so a target that plays a move
/// 1.5% of the time against your 6% clears it while barely playing the move at all,
/// and the sentence then reads as an endorsement nobody made.
const double kTargetPlaysItThreshold = 0.02;

/// Probabilities below this are treated as equal when forming the posterior.
///
/// Without it, target 0.0011% against player 0.0001% reports "91% like your
/// target" — a confident rank read on a move neither rank would ever play.
/// Note this is a tail guard only: it does not move the numbers above, because
/// moves people actually play are never that unlikely.
const double kPolicyFloor = 0.0005;

String rankLabel(String profile) {
  if (profile.startsWith('rank_')) return profile.substring(5);
  if (profile.startsWith('proyear_')) return 'pro ${profile.substring(8)}';
  if (profile.startsWith('preaz_')) return '${profile.substring(6)} (pre-AZ)';
  return profile;
}

enum MoveVerdict {
  /// Lost real points on a move your target rank does not reach for.
  mistake,

  /// Lost real points, but on a move the target rank plays. Distinct from
  /// [typical] because leading with "typical" while the move cost two points
  /// tells the player less than the card knows.
  costly,

  /// The target rank is at least twice as likely to play it as your rank.
  aboveYourLevel,

  /// Nothing the numbers can say. The fallback, and honest about being one.
  typical,
}

/// How much of the post-move card to show. Independent of [HeatmapMode]: the
/// heatmap tells you what to play *before* you move, this judges it after.
enum FeedbackMode { off, mistakesOnly, all }

/// Which policy, if any, to paint on the board before you move.
///
/// [pro] is the strongest profile the net has, and is the same one the score and
/// points-lost come from, so it is usually already evaluated and costs nothing to
/// show. It is not an AI policy -- this net only ever learned to imitate humans,
/// and giving it blank metadata produces an out-of-distribution answer, not a
/// stronger one -- but it is the closest thing available without a second model.
enum HeatmapMode { off, yourRank, target, pro }

/// P(target rank | move) under a two-hypothesis prior, with both probabilities
/// floored so vanishing policy values cannot manufacture a confident read.
double posteriorLikeTarget(double playerProb, double targetProb) {
  final p = math.max(playerProb, kPolicyFloor);
  final t = math.max(targetProb, kPolicyFloor);
  return t / (p + t);
}

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

  /// Whether the target rank plays this often enough for saying so to mean
  /// anything. See [kTargetPlaysItThreshold].
  bool get targetPlaysItToo => targetProb >= kTargetPlaysItThreshold;

  /// Desktop's rule: a big loss only counts as a mistake worth flagging if the move
  /// is either unlike your target rank or one almost nobody plays. A costly move the
  /// target rank would happily play is a level-appropriate move, not a blunder --
  /// but it is still costly, and [MoveVerdict.costly] says so rather than filing it
  /// under "typical" with the price in a footnote.
  MoveVerdict get verdict {
    if (costly) {
      return (isRare || moveLikeTarget < kTargetRankThreshold)
          ? MoveVerdict.mistake
          : MoveVerdict.costly;
    }
    // Don't praise a move neither rank actually plays: a 0.3% vs 0.1% split is a
    // 3:1 ratio but says nothing useful.
    if (!isRare && moveLikeTarget >= kAboveTargetThreshold) {
      return MoveVerdict.aboveYourLevel;
    }
    return MoveVerdict.typical;
  }

  /// Only [MoveVerdict.mistake] halts, matching desktop: a costly move the target
  /// rank plays is deliberately not flagged.
  bool get isMistake => verdict == MoveVerdict.mistake;
}

/// Board sizes offered. The featurizer is size-aware and pinned against KataGo on
/// all three (test/featurizer_test.dart), and the net is 19x19 throughout: a
/// smaller board occupies the corner of the same tensor, which is how KataGo does
/// it too.
const List<int> kBoardSizes = [9, 13, 19];

class ShapeGame extends ChangeNotifier {
  /// Null when the engine could not start. The board still works without it: you
  /// place stones for both sides and get no feedback, which beats no app at all.
  final Analyzer? engine;

  /// Not final: [newGame] can change it.
  int boardSize;
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

  // Default to the least hand-holding that still teaches: no policy shown
  // before you move, and only genuine mistakes called out afterwards.
  FeedbackMode feedbackMode = FeedbackMode.mistakesOnly;
  HeatmapMode heatmapMode = HeatmapMode.off;

  /// Profile whose policy the board paints, or null when the heatmap is off.
  String? get heatmapProfile => switch (heatmapMode) {
        HeatmapMode.off => null,
        HeatmapMode.yourRank => playerRank,
        HeatmapMode.target => targetRank,
        HeatmapMode.pro => kReferenceProfile,
      };

  bool get wantsFeedback => feedbackMode != FeedbackMode.off;

  /// Sampler settings, matching SHAPE's defaults.
  int topK = 50;
  double topP = 1.0;
  double minP = 0.05;

  bool busy = false;
  String? error;

  /// Why there is no engine, if there is none. Shown in the status line.
  String? engineError;

  /// Set when a call to a loaded engine throws, so one failure does not become a
  /// failure on every move for the rest of the session.
  bool _engineFailed = false;

  bool get hasEngine => engine != null && !_engineFailed;
  MoveFeedback? feedback;
  int analysisMs = 0;

  ShapeGame(this.engine, {this.boardSize = 19, math.Random? random})
      : rng = random ?? math.Random() {
    pos = GoPosition(boardSize, Rules.japanese);
  }

  /// Profiles to evaluate at the current position, kept as small as its role
  /// allows: each one is a full net call (~250ms on a phone).
  ///
  /// A position where the opponent is about to reply is transient -- the reply
  /// lands moments later -- so it only needs what that moment uses: the
  /// opponent's policy to sample from, and the reference lead so points-lost can
  /// be computed for the move just played. Player/target there would only feed a
  /// heatmap nobody sees, and fill in lazily if you browse back.
  ///
  /// With feedback and the heatmap both off an exchange costs two evaluations:
  /// the opponent's policy to reply from, and the reference profile behind the
  /// score. "Mistakes only" costs the same as "all": you cannot know a move was a
  /// mistake without evaluating it.
  List<String> get activeProfiles {
    final transient = autoplayOpponent && atTip && !humanToPlay && !gameOver;
    final needed = <String>{};
    if (transient) needed.add(opponentRank);
    if (wantsFeedback) {
      needed.add(kReferenceProfile);
      if (!transient) needed.addAll([playerRank, targetRank]);
    }
    if (!transient) {
      // The score estimate is always shown, so the profile behind it is always
      // evaluated -- one extra call per move, and only when feedback is off, since
      // feedback needs the same profile anyway. Transient positions are skipped:
      // the opponent's reply lands before anyone could read a score off them.
      needed.add(kReferenceProfile);
      final hm = heatmapProfile;
      if (hm != null) needed.add(hm);
    }
    return needed.toList();
  }

  /// Profiles needed to describe a move already played (no opponent sampling).
  List<String> get _feedbackProfiles =>
      {playerRank, targetRank, kReferenceProfile}.toList();

  /// True when the move that produced this position was the opponent passing.
  /// Easy to miss otherwise: a pass puts no stone on the board.
  bool get opponentJustPassed =>
      cursor > 0 && line[cursor - 1].isPass && line[cursor - 1].pla != humanColor;

  /// Score estimate for the current position in points for Black, or null if it
  /// has not been evaluated. From the reference profile's lead head, which is a
  /// net estimate with no search behind it -- good enough to say who is ahead and
  /// roughly by how much, and labelled as an estimate wherever it is shown.
  double? get scoreLeadForBlack {
    final a = analyses[cursor]?[kReferenceProfile];
    if (a == null) return null;
    // lead is from the side to move's point of view.
    return pos.nextPlayer == Board.black ? a.lead : -a.lead;
  }

  bool get atTip => cursor == line.length;
  bool get canGoBack => cursor > 0;
  bool get canGoForward => cursor < line.length;
  bool get humanToPlay => !hasEngine || pos.nextPlayer == humanColor;
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

  /// Analyze position [idx] for [profiles], skipping anything already cached.
  ///
  /// The position is built lazily: replaying the line to rebuild it is not free,
  /// and browsing history is almost always a pure cache hit.
  Future<void> _analyze(
    int idx,
    GoPosition Function() buildPosition,
    List<String> profiles,
  ) async {
    if (!hasEngine) return;
    final want =
        profiles.where((x) => !(analyses[idx]?.containsKey(x) ?? false)).toList();
    if (want.isEmpty) return;
    final sw = Stopwatch()..start();
    try {
      final result = await engine!.analyze(buildPosition(), want);
      analysisMs = sw.elapsedMilliseconds;
      (analyses[idx] ??= {}).addAll(result);
    } catch (e) {
      // Inference failing once means it will fail again, so stop asking and say so
      // rather than erroring on every move from here on.
      _engineFailed = true;
      engineError = 'inference failed: ${describeFailure(e)}';
    }
  }

  Future<void> _analyzeCurrent() => _analyze(cursor, () => pos, activeProfiles);

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

  /// Describe the last move you played at or before the cursor.
  ///
  /// Deliberately not "the move that produced this position": the opponent replies
  /// immediately, so by the time it is your turn again that move is theirs, and
  /// keying off it would leave the card empty for the whole of your thinking time.
  Future<void> _updateFeedback() async {
    feedback = null;
    if (!wantsFeedback || !hasEngine) return;
    final beforeIdx = lastOwnMoveIndex;
    if (beforeIdx == null) return;
    final move = line[beforeIdx];

    // Usually both are cached from when the move was played; this only does work if
    // feedback was off then, or the ranks have changed since. The position after the
    // move contributes only its reference lead, for points-lost -- every probability
    // comes from the position you faced before playing.
    await _analyze(beforeIdx, () => _positionAt(beforeIdx), _feedbackProfiles);
    await _analyze(beforeIdx + 1, () => _positionAt(beforeIdx + 1),
        const [kReferenceProfile]);

    final before = analyses[beforeIdx];
    final player = before?[playerRank];
    final target = before?[targetRank];
    if (player == null || target == null) return;

    // loc encodes x/y purely from board width, so the current board decodes it.
    final x = pos.board.locX(move.loc);
    final y = pos.board.locY(move.loc);
    final (pProb, pRel) = player.policy.at(x, y);
    final (tProb, tRel) = target.policy.at(x, y);
    feedback = MoveFeedback(
      x: x,
      y: y,
      playerProb: pProb,
      playerRel: pRel,
      targetProb: tProb,
      targetRel: tRel,
      moveLikeTarget: posteriorLikeTarget(pProb, tProb),
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
      _reviewReturn = null;
      // Playing while browsing history discards the moves and analysis after here.
      if (!atTip) {
        line.removeRange(cursor, line.length);
        analyses.removeWhere((moveIndex, _) => moveIndex > cursor);
      }
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
    if (!hasEngine) return;
    if (!autoplayOpponent || gameOver || humanToPlay || busy || !atTip) return;
    busy = true;
    notifyListeners();
    try {
      await _analyze(cursor, () => pos, [opponentRank]);
      final analysis = analyses[cursor]?[opponentRank];
      if (analysis != null) {
        final candidates = analysis.policy.sample(
          topK: topK,
          topP: topP,
          minP: minP,
          excludePass: false,
        );
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

  Future<void> _goTo(int target, {bool keepReview = false}) async {
    if (busy) return;
    if (!keepReview) _reviewReturn = null;
    final t = target.clamp(0, line.length);
    busy = true;
    notifyListeners();
    try {
      // Still re-analyzes when the cursor has not moved: entering or leaving review
      // changes which policy the board needs even when it lands where it started.
      if (t != cursor) {
        cursor = t;
        pos = _positionAt(cursor);
      }
      await _analyzeCurrent();
      await _updateFeedback();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Index of the last move you played at or before the cursor, or null.
  int? get lastOwnMoveIndex {
    for (var i = cursor - 1; i >= 0; i--) {
      if (line[i].pla == humanColor && !line[i].isPass) return i;
    }
    return null;
  }

  bool get canReviewOwnMove => lastOwnMoveIndex != null || reviewing;

  /// Where review was entered from, so leaving it puts everything back.
  ({int cursor, HeatmapMode heatmap})? _reviewReturn;

  bool get reviewing => _reviewReturn != null;

  /// Show the position you faced before your last move with the target rank's
  /// policy on it -- "what would a 2d have played?" -- and put both the cursor and
  /// the heatmap setting back when tapped again.
  ///
  /// Skips back over the opponent's replies, so it lands on your decision rather
  /// than theirs no matter where the cursor is.
  Future<void> toggleReview() async {
    if (busy) return;
    final ret = _reviewReturn;
    if (ret != null) {
      _reviewReturn = null;
      heatmapMode = ret.heatmap;
      await _goTo(ret.cursor, keepReview: true);
      return;
    }
    final idx = lastOwnMoveIndex;
    if (idx == null) return;
    _reviewReturn = (cursor: cursor, heatmap: heatmapMode);
    heatmapMode = HeatmapMode.target;
    await _goTo(idx, keepReview: true);
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
    try {
      line.clear();
      cursor = 0;
      analyses.clear();
      _reviewReturn = null;
      feedback = null;
      error = null;
      boardSize = size ?? boardSize;
      pos = GoPosition(boardSize, Rules.japanese);
      await _analyzeCurrent();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
    await _maybeOpponentMove();
  }

  Future<void> setFeedbackMode(FeedbackMode mode) async {
    if (feedbackMode == mode) return;
    feedbackMode = mode;
    if (!wantsFeedback) feedback = null;
    await _refresh();
  }

  Future<void> setHeatmapMode(HeatmapMode mode) async {
    if (heatmapMode == mode) return;
    heatmapMode = mode;
    await _refresh();
  }

  Future<void> _refresh() async {
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
    for (final m in line) {
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
