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
/// 0.5 is the point of *no evidence*: a move both ranks like equally clears it,
/// so nearly two in five of the player's own ordinary moves get praised.
/// Calibrated over 80 positions of realistic rank_5k self-play
/// (tools/onnx_export/calibrate_verdict.py), player 5k / target 2d, showing the
/// fraction of moves each rank would really play that clear a given threshold:
///
///   threshold   flags 5k moves   flags 2d moves   lift
///   0.50             38.8%            75.0%       1.94
///   0.60              7.5%            43.8%       5.83
///   0.667             2.5%            26.2%      10.50   <- chosen
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

/// A node in the game tree: the position reached by playing [move] from [parent].
///
/// A tree rather than a list because playing from a position you have browsed back
/// to should add a branch — an SGF variation — not delete what was there.
class GameNode {
  final GameNode? parent;

  /// Null at the root, which is the empty board.
  final Move? move;
  final List<GameNode> children = [];

  /// Cached per node, so a variation keeps its own evaluations and revisiting a
  /// position costs nothing.
  final Map<String, ProfileAnalysis> analyses = {};

  GameNode({this.parent, this.move});

  bool get isRoot => parent == null;

  int get depth {
    var d = 0;
    for (var n = this; n.parent != null; n = n.parent!) {
      d++;
    }
    return d;
  }

  /// Moves from the root down to here.
  List<Move> get path {
    final out = <Move>[];
    for (var n = this; n.parent != null; n = n.parent!) {
      out.add(n.move!);
    }
    return out.reversed.toList(growable: false);
  }

  /// The child for [move], reusing the existing one so replaying a move you have
  /// already explored returns to it -- with its analyses -- instead of duplicating.
  GameNode childFor(Move move) {
    for (final c in children) {
      if (c.move!.loc == move.loc && c.move!.pla == move.pla) return c;
    }
    final child = GameNode(parent: this, move: move);
    children.add(child);
    return child;
  }

  /// Following the first child at each step, which is the main line.
  GameNode get endOfMainLine {
    var n = this;
    while (n.children.isNotEmpty) {
      n = n.children.first;
    }
    return n;
  }
}

/// A move that continues from the current position, for the board to show.
class NextMove {
  final int x;
  final int y;

  /// Null when the move has not been evaluated, or is the opponent's.
  final MoveVerdict? verdict;

  /// Whether this is the continuation navigation will follow.
  final bool isMainLine;

  const NextMove(this.x, this.y, this.verdict, this.isMainLine);
}

class ShapeGame extends ChangeNotifier {
  /// Null when the engine could not start. The board still works without it: you
  /// place stones for both sides and get no feedback.
  final Analyzer? engine;

  int boardSize;
  final math.Random rng;

  /// The empty board. Everything played hangs off it.
  GameNode root = GameNode();

  /// Where you are looking.
  GameNode current = GameNode();

  late GoPosition pos;

  /// Moves from the root to [current]; its length is [cursor].
  List<Move> get line => current.path;
  int get cursor => current.depth;

  /// The whole line through the current node: back to the root, then on down the
  /// main line. Navigation and mistake-hunting move along this.
  List<GameNode> get currentLine {
    final back = <GameNode>[];
    for (var n = current; n.parent != null; n = n.parent!) {
      back.add(n);
    }
    final out = back.reversed.toList();
    for (var n = current; n.children.isNotEmpty;) {
      n = n.children.first;
      out.add(n);
    }
    return out;
  }

  /// Moves continuing from here, so the board can show what has been explored.
  List<NextMove> get nextMoves => [
        for (final c in current.children)
          if (!c.move!.isPass)
            NextMove(
              pos.board.locX(c.move!.loc),
              pos.board.locY(c.move!.loc),
              feedbackFor(c)?.verdict,
              identical(c, current.children.first),
            ),
      ];

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
    current = root;
    pos = GoPosition(boardSize, Rules.japanese);
  }

  /// Profiles to evaluate at the current position, kept as small as its role
  /// allows: each one is a full net call (~250ms on a phone).
  ///
  /// A position where the opponent is about to reply is transient -- the reply
  /// lands moments later -- so it only needs the opponent's policy to sample from
  /// and the reference lead for points-lost. Player/target there would only feed
  /// a heatmap nobody sees, and fill in lazily if you browse back.
  ///
  /// "Mistakes only" costs the same as "all": you cannot know a move was a
  /// mistake without evaluating it.
  List<String> get activeProfiles {
    // Transient is deliberately not tied to being at the tip: a reply already in
    // the tree is followed just as immediately as a freshly sampled one. Browsing
    // lands on your own moves when autoplay is on, so this does not strip the
    // heatmap from anywhere you can actually look.
    final transient = autoplayOpponent && !humanToPlay && !gameOver;
    final needed = <String>{};
    if (transient) needed.add(opponentRank);
    if (wantsFeedback) {
      needed.add(kReferenceProfile);
      if (!transient) needed.addAll([playerRank, targetRank]);
    }
    if (!transient) {
      // The score estimate is always shown, so the profile behind it is always
      // evaluated -- except at transient positions, where the reply lands before
      // anyone could read a score.
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
  bool get opponentJustPassed {
    final m = current.move;
    return m != null && m.isPass && m.pla != humanColor;
  }

  /// Score estimate for the current position in points for Black, or null if it
  /// has not been evaluated. From the reference profile's lead head, which is a
  /// net estimate with no search behind it -- good enough to say who is ahead and
  /// roughly by how much, and labelled as an estimate wherever it is shown.
  double? get scoreLeadForBlack {
    final a = current.analyses[kReferenceProfile];
    if (a == null) return null;
    // lead is from the side to move's point of view.
    return pos.nextPlayer == Board.black ? a.lead : -a.lead;
  }

  bool get atTip => current.children.isEmpty;
  bool get canGoBack => !current.isRoot;
  bool get canGoForward => current.children.isNotEmpty;
  bool get humanToPlay => !hasEngine || pos.nextPlayer == humanColor;

  bool get gameOver {
    final prev = current.parent?.move;
    return current.move?.isPass == true && prev?.isPass == true;
  }

  ProfileAnalysis? analysisFor(String profile) => current.analyses[profile];

  GoPosition _positionFor(GameNode node) {
    final p = GoPosition(boardSize, Rules.japanese);
    for (final m in node.path) {
      p.play(m.pla, m.loc);
    }
    return p;
  }

  Future<void> start() async {
    await _analyzeCurrent();
    await _maybeOpponentMove();
  }

  /// Analyze [node] for [profiles], skipping anything already cached.
  ///
  /// The position is built lazily: replaying the line to rebuild it is not free,
  /// and browsing history is almost always a pure cache hit.
  Future<void> _analyze(
    GameNode node,
    GoPosition Function() buildPosition,
    List<String> profiles,
  ) async {
    if (!hasEngine) return;
    final want = profiles.where((x) => !node.analyses.containsKey(x)).toList();
    if (want.isEmpty) return;
    final sw = Stopwatch()..start();
    try {
      final result = await engine!.analyze(buildPosition(), want);
      analysisMs = sw.elapsedMilliseconds;
      node.analyses.addAll(result);
    } catch (e) {
      // Inference failing once means it will fail again, so stop asking and say so
      // rather than erroring on every move from here on.
      _engineFailed = true;
      engineError = 'inference failed: ${describeFailure(e)}';
    }
  }

  Future<void> _analyzeCurrent() => _analyze(current, () => pos, activeProfiles);

  /// Points the side that just moved gave up, per the reference profile.
  ///
  /// `lead` is from the side-to-move's perspective, so the raw loss is
  /// leadBefore + leadAfter. Under territory scoring that carries a systematic
  /// +1.0 per stone, because KataGo's selfKomi is
  /// `komi + blackNonPassMoves - whiteNonPassMoves` -- the Japanese convention that
  /// a stone costs a point. Measured on the empty board: tengen 0.87, D4 0.96,
  /// Q16 1.14, against B2 2.69 and A1 6.13. Without this every normal move reads as
  /// a ~1 point mistake.
  double? _pointsLost(GameNode moveNode, {required bool wasPass}) {
    final before = moveNode.parent?.analyses[kReferenceProfile];
    final after = moveNode.analyses[kReferenceProfile];
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
    final node = lastOwnMove;
    if (node == null) return;

    // Usually both are cached from when the move was played; this only does work if
    // feedback was off then, or the ranks have changed since. The position after the
    // move contributes only its reference lead, for points-lost -- every probability
    // comes from the position you faced before playing.
    final before = node.parent!;
    await _analyze(before, () => _positionFor(before), _feedbackProfiles);
    await _analyze(node, () => _positionFor(node), const [kReferenceProfile]);

    feedback = feedbackFor(node);
  }

  /// How the move arriving at [node] looks, from analyses already cached.
  ///
  /// Returns null when it is not yours, was a pass, or has not been evaluated --
  /// this reads the cache and never triggers work, so it is safe to call for every
  /// node in the tree.
  MoveFeedback? feedbackFor(GameNode node) {
    final move = node.move;
    if (move == null || move.pla != humanColor || move.isPass) return null;

    final before = node.parent?.analyses;
    final player = before?[playerRank];
    final target = before?[targetRank];
    if (player == null || target == null) return null;

    // loc encodes x/y purely from board width, so the current board decodes it.
    final x = pos.board.locX(move.loc);
    final y = pos.board.locY(move.loc);
    final (pProb, pRel) = player.policy.at(x, y);
    final (tProb, tRel) = target.policy.at(x, y);
    return MoveFeedback(
      x: x,
      y: y,
      playerProb: pProb,
      playerRel: pRel,
      targetProb: tProb,
      targetRel: tRel,
      moveLikeTarget: posteriorLikeTarget(pProb, tProb),
      pointsLost: _pointsLost(node, wasPass: false),
    );
  }

  /// Your moves along the current line already known to be mistakes.
  ///
  /// Known, not all: a move is judged from cached analyses, which exist for every
  /// move played while feedback was on. Moves never evaluated are skipped rather
  /// than evaluated now, because scanning a whole game would cost a few hundred
  /// milliseconds per move and freeze the button that asked for it.
  List<GameNode> get knownMistakes =>
      [for (final n in currentLine) if (feedbackFor(n)?.isMistake ?? false) n];

  GameNode? get nextMistake {
    for (final n in knownMistakes) {
      if (n.depth > cursor) return n;
    }
    return null;
  }

  GameNode? get previousMistake {
    GameNode? found;
    for (final n in knownMistakes) {
      if (n.depth < cursor) found = n;
    }
    return found;
  }

  /// Jump so the mistake is the move just played, which is what the card describes.
  Future<void> goToMistake({required bool forward}) async {
    final node = forward ? nextMistake : previousMistake;
    if (node == null) return;
    await _goToNode(node);
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
      final mover = pos.nextPlayer;
      pos.play(mover, loc);
      current = current.childFor(Move(mover, loc));
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
    if (!autoplayOpponent || gameOver || humanToPlay || busy) return;

    // Their answer to this position is already in the tree, so follow it. Sampling
    // again would invent a second reply to a position they have already answered,
    // and returning here instead would strand the game on their turn with the board
    // refusing input until Forward was pressed by hand.
    if (!atTip) {
      await _goToNode(current.children.first);
      return;
    }

    busy = true;
    notifyListeners();
    try {
      await _analyze(current, () => pos, [opponentRank]);
      final analysis = current.analyses[opponentRank];
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
        current = current.childFor(Move(mover, loc));
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

  Future<void> _goToNode(GameNode target, {bool keepReview = false}) async {
    if (busy) return;
    if (!keepReview) _reviewReturn = null;
    busy = true;
    notifyListeners();
    try {
      // Still re-analyzes when the node has not changed: entering or leaving review
      // changes which policy the board needs even when it lands where it started.
      if (!identical(target, current)) {
        current = target;
        pos = _positionFor(current);
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

  /// The last move you played at or before the cursor, or null.
  GameNode? get lastOwnMove {
    for (var n = current; n.parent != null; n = n.parent!) {
      if (n.move!.pla == humanColor && !n.move!.isPass) return n;
    }
    return null;
  }

  bool get canReviewOwnMove => lastOwnMove != null || reviewing;

  /// Where review was entered from, so leaving it puts everything back.
  ({GameNode node, HeatmapMode heatmap})? _reviewReturn;

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
      await _goToNode(ret.node, keepReview: true);
      return;
    }
    final own = lastOwnMove;
    if (own == null) return;
    _reviewReturn = (node: current, heatmap: heatmapMode);
    heatmapMode = HeatmapMode.target;
    // The position you faced is the one before the move, so step to its parent.
    await _goToNode(own.parent!, keepReview: true);
  }

  GameNode _up(GameNode from, int steps) {
    var n = from;
    for (var i = 0; i < steps && n.parent != null; i++) {
      n = n.parent!;
    }
    return n;
  }

  GameNode _down(GameNode from, int steps) {
    var n = from;
    for (var i = 0; i < steps && n.children.isNotEmpty; i++) {
      n = n.children.first;
    }
    return n;
  }

  Future<void> goFirst() => _goToNode(root);
  Future<void> goLast() => _goToNode(current.endOfMainLine);

  /// Step back one exchange, so you land on your own move rather than the reply.
  Future<void> goPrev() => _goToNode(_up(current, autoplayOpponent ? 2 : 1));
  Future<void> goNext() => _goToNode(_down(current, autoplayOpponent ? 2 : 1));

  Future<void> newGame({int? size}) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      root = GameNode();
      current = root;
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
    await _refresh();
  }

  /// SGF for the whole tree, variations and all.
  String toSgf() {
    final b = StringBuffer('(;GM[1]FF[4]CA[UTF-8]SZ[$boardSize]KM[6.5]RU[Japanese]');
    b.write('PB[${humanColor == Board.black ? rankLabel(playerRank) : rankLabel(opponentRank)}]');
    b.write('PW[${humanColor == Board.white ? rankLabel(playerRank) : rankLabel(opponentRank)}]');
    _writeSgfChildren(b, root);
    b.write(')');
    return b.toString();
  }

  void _writeSgfChildren(StringBuffer b, GameNode node) {
    var n = node;
    while (n.children.isNotEmpty) {
      // A single continuation stays in the same sequence; a branch point opens one
      // parenthesised variation per child, which is what SGF readers expect.
      if (n.children.length == 1) {
        b.write(_sgfMove(n.children.first.move!));
        n = n.children.first;
        continue;
      }
      for (final c in n.children) {
        b.write('(');
        b.write(_sgfMove(c.move!));
        _writeSgfChildren(b, c);
        b.write(')');
      }
      return;
    }
  }

  String _sgfMove(Move m) {
    final tag = m.pla == Board.black ? 'B' : 'W';
    if (m.isPass) return ';$tag[]';
    final x = pos.board.locX(m.loc);
    final y = pos.board.locY(m.loc);
    return ';$tag[${String.fromCharCode(97 + x)}${String.fromCharCode(97 + y)}]';
  }
}
