// SHAPE mobile: play Go against a human-like KataGo opponent at a chosen rank,
// and see how each move looks to your rank versus the rank you're aiming at.
//
// Everything runs on device: the featurizer is a port of KataGo's board.py +
// features.py (pinned by test/featurizer_test.dart) feeding the human-SL net
// through ONNX Runtime.

import 'package:flutter/material.dart';

import 'board_painter.dart';
import 'engine/analysis.dart';
import 'game/shape_game.dart';

const kModelAsset = 'assets/b18c384nbt-humanv0.onnx';

void main() => runApp(const ShapeApp());

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

enum Overlay { none, yourRank, targetRank }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ShapeGame? game;
  Object? loadError;
  String status = 'loading model…';
  Overlay overlay = Overlay.targetRank;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final engine = await ShapeEngine.load(kModelAsset);
      final g = ShapeGame(engine, boardSize: 19);
      g.addListener(() => setState(() {}));
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

  PolicyData? get _overlayPolicy {
    final g = game;
    if (g == null || overlay == Overlay.none) return null;
    final profile = overlay == Overlay.yourRank ? g.playerRank : g.targetRank;
    return g.analysisFor(profile)?.policy;
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('SHAPE'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: g.canUndo && !g.busy ? g.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'New game',
            onPressed: g.busy ? null : () => g.newGame(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _board(g),
            if (g.busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: SingleChildScrollView(child: _panel(g))),
          ],
        ),
      ),
    );
  }

  Widget _board(ShapeGame g) {
    final last = g.pos.moves.isEmpty || g.pos.moves.last.isPass
        ? null
        : (g.pos.board.locX(g.pos.moves.last.loc), g.pos.board.locY(g.pos.moves.last.loc));
    final fb = g.lastFeedback;
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
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                if (g.busy || !g.humanToPlay || g.gameOver) return;
                final p = geom.hit(d.localPosition);
                if (p != null) g.playAt(p.$1, p.$2);
              },
              child: CustomPaint(
                painter: BoardPainter(
                  board: g.pos.board,
                  heatmap: _overlayPolicy,
                  lastMove: last,
                  flaggedMove: (fb != null && fb.isMistake) ? (fb.x, fb.y) : null,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _feedbackCard(g),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _rankPicker('Your rank', g.playerRank, (v) => g.setRanks(player: v))),
            const SizedBox(width: 8),
            Expanded(child: _rankPicker('Aiming at', g.targetRank, (v) => g.setRanks(target: v))),
          ]),
          const SizedBox(height: 4),
          _rankPicker('Opponent', g.opponentRank, (v) => g.setRanks(opponent: v)),
          const SizedBox(height: 8),
          SegmentedButton<Overlay>(
            segments: const [
              ButtonSegment(value: Overlay.none, label: Text('No hints')),
              ButtonSegment(value: Overlay.yourRank, label: Text('Your rank')),
              ButtonSegment(value: Overlay.targetRank, label: Text('Target')),
            ],
            selected: {overlay},
            onSelectionChanged: (s) => setState(() => overlay = s.first),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: g.busy || g.gameOver ? null : g.pass,
                icon: const Icon(Icons.skip_next),
                label: const Text('Pass'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: g.canRedo && !g.busy ? g.redo : null,
                icon: const Icon(Icons.redo),
                label: const Text('Redo'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          DefaultTextStyle(
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.black54),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('move ${g.moveCount}   '
                  '${g.gameOver ? "game over" : (g.humanToPlay ? "your turn" : "opponent…")}   '
                  '${g.analysisMs} ms'),
              if (g.error != null)
                Text(g.error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _feedbackCard(ShapeGame g) {
    final fb = g.lastFeedback;
    if (fb == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('Play a move to see how it looks to each rank.'),
        ),
      );
    }
    final pointsLost = fb.pointsLost;
    final good = fb.targetWouldPlay && !fb.isMistake;
    final color = fb.isMistake
        ? const Color(0xFFE53935)
        : (good ? const Color(0xFF0B6E2E) : Colors.orange.shade800);
    final headline = fb.isMistake
        ? 'Lost ${pointsLost!.toStringAsFixed(1)} points'
        : (good ? 'Good — a ${rankLabel(g.targetRank)} move' : 'Playable');

    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(fb.isMistake ? Icons.warning_amber : Icons.check_circle_outline,
                color: color, size: 20),
            const SizedBox(width: 6),
            Text('${coordLabel(fb.x, fb.y, g.boardSize)} · $headline',
                style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          ]),
          const SizedBox(height: 8),
          _bar('${rankLabel(g.playerRank)} would play this', fb.playerProb, fb.playerRel),
          _bar('${rankLabel(g.targetRank)} would play this', fb.targetProb, fb.targetRel),
          const SizedBox(height: 4),
          Text(
            'Looks like ${rankLabel(g.targetRank)} rather than ${rankLabel(g.playerRank)}: '
            '${(fb.moveLikeTarget * 100).toStringAsFixed(0)}%'
            '${pointsLost == null ? "" : "   ·   ${pointsLost >= 0 ? "-" : "+"}${pointsLost.abs().toStringAsFixed(1)} pts"}',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
      ),
    );
  }

  Widget _bar(String label, double prob, double rel) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(
            width: 190,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
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

  Widget _rankPicker(String label, String value, Future<void> Function(String) onChanged) =>
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
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      );
}
