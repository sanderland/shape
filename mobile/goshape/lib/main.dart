// SHAPE mobile: play Go against a human-like KataGo opponent at a chosen rank,
// and see how each move looks to your rank versus the rank you're aiming at.
//
// Everything runs on device: the featurizer is a port of KataGo's board.py +
// features.py (pinned by test/featurizer_test.dart) feeding the human-SL net
// through MNN.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'board_painter.dart';
import 'feedback_card.dart';
import 'engine/analysis.dart';
import 'game/shape_game.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ShapeApp());
}

class ShapeApp extends StatelessWidget {
  const ShapeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SHAPE',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6E2E), useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ShapeGame? game;
  Object? loadError;
  String status = 'loading model…';

  /// Intersection currently under the finger, if any.
  (int, int)? _crosshair;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The board is worth having even when the engine is not available, so a failure
  /// to load one degrades the app rather than replacing it with an error screen.
  Future<void> _load() async {
    ShapeEngine? engine;
    String? engineError;
    try {
      engine = await ShapeEngine.load();
    } catch (e, st) {
      debugPrint('$e\n$st');
      engineError = describeFailure(e);
    }
    try {
      final g = ShapeGame(engine, boardSize: 19)..engineError = engineError;
      g.addListener(_onGameChanged);
      setState(() {
        game = g;
        status = 'analyzing…';
      });
      await g.start();
      setState(() => status = 'ready');
    } catch (e, st) {
      debugPrint('$e\n$st');
      setState(() => loadError = e);
    }
  }

  void _onGameChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    game?.removeListener(_onGameChanged);
    super.dispose();
  }

  PolicyData? get _overlayPolicy {
    final g = game;
    final profile = g?.heatmapProfile;
    if (profile == null) return null;
    return g!.analysisFor(profile)?.policy;
  }

  @override
  Widget build(BuildContext context) {
    if (loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('SHAPE')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Text('$loadError', style: const TextStyle(color: Colors.red, fontSize: 12)),
          ),
        ),
      );
    }
    final g = game;
    if (g == null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(status),
          ]),
        ),
      );
    }

    final navEnabled = !g.busy;
    return Scaffold(
      appBar: AppBar(
        title: _menu(g),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'First move',
            onPressed: navEnabled && g.canGoBack ? g.goFirst : null,
            icon: const Icon(Icons.first_page),
          ),
          IconButton(
            tooltip: 'Back',
            onPressed: navEnabled && g.canGoBack ? g.goPrev : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: g.reviewing
                ? 'Back to the game'
                : 'What would ${rankLabel(g.targetRank)} have played?',
            onPressed:
                navEnabled && g.hasEngine && g.canReviewOwnMove ? g.toggleReview : null,
            icon: Icon(g.reviewing ? Icons.lightbulb : Icons.lightbulb_outline),
            color: g.reviewing ? const Color(0xFFF9A825) : null,
          ),
          IconButton(
            tooltip: 'Forward',
            onPressed: navEnabled && g.canGoForward ? g.goNext : null,
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            tooltip: 'Latest move',
            onPressed: navEnabled && g.canGoForward ? g.goLast : null,
            icon: const Icon(Icons.last_page),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // The board takes what is left after the panel, rather than the panel
            // being pushed off the bottom by a fixed-size board.
            Flexible(child: _board(g)),
            if (g.busy) const LinearProgressIndicator(minHeight: 2),
            _panel(g),
          ],
        ),
      ),
    );
  }

  /// Everything that is not needed on every move lives here, so the board and the
  /// controls that are can fit on one screen without scrolling.
  Widget _menu(ShapeGame g) => PopupMenuButton<String>(
        tooltip: 'Menu',
        position: PopupMenuPosition.under,
        onSelected: (v) async {
          final target = game;
          if (target == null) return;
          switch (v) {
            case 'pass':
              await target.pass();
            case 'new':
              await _newGame(target);
            case 'ranks':
              await _editRanks(target);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'pass',
            enabled: !g.busy && !g.gameOver && g.humanToPlay,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.skip_next),
              title: Text('Pass'),
            ),
          ),
          PopupMenuItem(
            value: 'new',
            enabled: !g.busy,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.refresh),
              title: Text('New game'),
            ),
          ),
          PopupMenuItem(
            value: 'ranks',
            enabled: !g.busy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune),
              title: const Text('Ranks'),
              subtitle: Text('${rankLabel(g.playerRank)} · ${rankLabel(g.targetRank)} '
                  '· ${rankLabel(g.opponentRank)}'),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            enabled: false,
            child: DefaultTextStyle(
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11, color: Colors.black54),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g.boardSize}x${g.boardSize}   move ${g.cursor}/${g.line.length}'),
                Text(g.hasEngine
                    ? '${g.engine!.provider}   ${g.analysisMs} ms/move'
                    : 'no engine'),
              ]),
            ),
          ),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('SHAPE', style: Theme.of(context).textTheme.titleLarge),
          const Icon(Icons.arrow_drop_down),
        ]),
      );

  bool _canPlay(ShapeGame g) =>
      !g.busy && g.humanToPlay && !g.gameOver;

  void _aim(ShapeGame g, BoardGeometry geom, Offset local) {
    if (!_canPlay(g)) return;
    final p = geom.nearest(local);
    if (p != _crosshair) setState(() => _crosshair = p);
  }

  Widget _board(ShapeGame g) {
    final lastMove = g.cursor == 0 || g.line[g.cursor - 1].isPass
        ? null
        : (
            g.pos.board.locX(g.line[g.cursor - 1].loc),
            g.pos.board.locY(g.line[g.cursor - 1].loc),
          );
    final fb = g.feedback;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final geom = BoardGeometry(
              Size(constraints.maxWidth, constraints.maxHeight),
              g.boardSize,
            );
            // Raw pointer events rather than a tap or drag recogniser: both a quick
            // tap and a long adjusting drag have to behave the same way, which is
            // aim while held, place on release.
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => _aim(g, geom, e.localPosition),
              onPointerMove: (e) => _aim(g, geom, e.localPosition),
              onPointerUp: (_) {
                final p = _crosshair;
                setState(() => _crosshair = null);
                if (p != null && _canPlay(g)) g.playAt(p.$1, p.$2);
              },
              onPointerCancel: (_) => setState(() => _crosshair = null),
              child: CustomPaint(
                painter: BoardPainter(
                  board: g.pos.board,
                  heatmap: _overlayPolicy,
                  lastMove: lastMove,
                  flaggedMove: (fb != null && fb.isMistake) ? (fb.x, fb.y) : null,
                  crosshair: _crosshair,
                  crosshairPlayer: g.pos.nextPlayer,
                ),
                size: Size.infinite,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _panel(ShapeGame g) {
    final controlsEnabled = !g.busy;
    // Feedback and heatmaps are the engine's output, so without one they are not
    // merely empty, they are unavailable.
    final analysisEnabled = controlsEnabled && g.hasEngine;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GameNotice(
            gameOver: g.gameOver,
            opponentPassed: g.opponentJustPassed,
            opponentRank: g.opponentRank,
            scoreLeadForBlack: g.scoreLeadForBlack,
          ),
          if (_showCard(g)) ...[
            FeedbackCard(
              feedback: g.feedback,
              playerRank: g.playerRank,
              targetRank: g.targetRank,
              boardSize: g.boardSize,
            ),
            const SizedBox(height: 6),
          ],
          _labelled('Feedback after your move', SegmentedButton<FeedbackMode>(
            segments: const [
              ButtonSegment(value: FeedbackMode.off, label: Text('Off')),
              ButtonSegment(value: FeedbackMode.mistakesOnly, label: Text('Mistakes')),
              ButtonSegment(value: FeedbackMode.all, label: Text('Every move')),
            ],
            selected: {g.feedbackMode},
            onSelectionChanged:
                analysisEnabled ? (s) => g.setFeedbackMode(s.first) : null,
          )),
          const SizedBox(height: 6),
          _labelled('Show policy', SegmentedButton<HeatmapMode>(
            segments: const [
              ButtonSegment(value: HeatmapMode.off, label: Text('Off')),
              ButtonSegment(value: HeatmapMode.yourRank, label: Text('Your rank')),
              ButtonSegment(value: HeatmapMode.target, label: Text('Target')),
            ],
            selected: {g.heatmapMode},
            onSelectionChanged:
                analysisEnabled ? (s) => g.setHeatmapMode(s.first) : null,
          )),
          if (g.engineError != null) ...[
            const SizedBox(height: 4),
            Text('No engine — board only, no opponent or feedback. '
                '${g.engineError}',
                style: const TextStyle(color: Color(0xFFE65100), fontSize: 11)),
          ],
          if (g.error != null) ...[
            const SizedBox(height: 4),
            Text(g.error!, style: const TextStyle(color: Colors.red, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  /// Asks for a board size first, defaulting to the one already in play.
  Future<void> _newGame(ShapeGame g) async {
    final size = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('New game'),
        children: [
          for (final s in kBoardSizes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Row(children: [
                Icon(s == g.boardSize ? Icons.check : Icons.grid_on,
                    size: 18,
                    color: s == g.boardSize ? const Color(0xFF0B6E2E) : Colors.black38),
                const SizedBox(width: 10),
                Text('$s × $s'),
              ]),
            ),
        ],
      ),
    );
    if (size != null) await g.newGame(size: size);
  }

  /// Mistakes-only hides the card unless the move was actually flagged.
  bool _showCard(ShapeGame g) => switch (g.feedbackMode) {
        FeedbackMode.off => false,
        FeedbackMode.all => true,
        FeedbackMode.mistakesOnly => g.feedback?.isMistake ?? false,
      };

  /// Stretches [child] to full width: a SegmentedButton otherwise sizes to its
  /// labels, leaving the two rows different widths.
  Widget _labelled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 3),
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ),
          child,
        ],
      );

  Future<void> _editRanks(ShapeGame g) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: EdgeInsets.fromLTRB(
                16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _rankPicker('Your rank', g.playerRank, (v) async {
                await g.setRanks(player: v);
                setSheetState(() {});
              }, enabled: true),
              const SizedBox(height: 10),
              _rankPicker('Aiming at', g.targetRank, (v) async {
                await g.setRanks(target: v);
                setSheetState(() {});
              }, enabled: true),
              const SizedBox(height: 10),
              _rankPicker('Opponent', g.opponentRank, (v) async {
                await g.setRanks(opponent: v);
                setSheetState(() {});
              }, enabled: true),
            ]),
          ),
        ),
      );

  Widget _rankPicker(
    String label,
    String value,
    Future<void> Function(String) onChanged, {
    required bool enabled,
  }) =>
      InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: value,
            items: kRanks
                .map((r) => DropdownMenuItem(value: r, child: Text(rankLabel(r))))
                .toList(),
            onChanged: enabled
                ? (v) {
                    if (v != null) onChanged(v);
                  }
                : null,
          ),
        ),
      );
}
