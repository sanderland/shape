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

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ShapeGame? game;
  Object? loadError;
  String status = 'loading model…';
  bool benchmarking = false;

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
        title: const Text('SHAPE'),
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
            _board(g),
            if (g.busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: SingleChildScrollView(child: _panel(g))),
          ],
        ),
      ),
    );
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
                  lastMove: lastMove,
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
          if (_showCard(g)) ...[
            _feedbackCard(g),
            const SizedBox(height: 8),
          ],
          Row(children: [
            Expanded(child: _rankPicker('Your rank', g.playerRank, (v) => g.setRanks(player: v))),
            const SizedBox(width: 8),
            Expanded(child: _rankPicker('Aiming at', g.targetRank, (v) => g.setRanks(target: v))),
          ]),
          const SizedBox(height: 4),
          _rankPicker('Opponent', g.opponentRank, (v) => g.setRanks(opponent: v)),
          const SizedBox(height: 8),
          _labelled('Feedback after your move', SegmentedButton<FeedbackMode>(
            segments: const [
              ButtonSegment(value: FeedbackMode.off, label: Text('Off')),
              ButtonSegment(value: FeedbackMode.mistakesOnly, label: Text('Mistakes')),
              ButtonSegment(value: FeedbackMode.all, label: Text('Every move')),
            ],
            selected: {g.feedbackMode},
            onSelectionChanged: (s) => g.setFeedbackMode(s.first),
          )),
          const SizedBox(height: 6),
          _labelled('Show the policy before you move', SegmentedButton<HeatmapMode>(
            segments: const [
              ButtonSegment(value: HeatmapMode.off, label: Text('Off')),
              ButtonSegment(value: HeatmapMode.yourRank, label: Text('Your rank')),
              ButtonSegment(value: HeatmapMode.target, label: Text('Target')),
            ],
            selected: {g.heatmapMode},
            onSelectionChanged: (s) => g.setHeatmapMode(s.first),
          )),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: g.busy || g.gameOver || !g.humanToPlay ? null : g.pass,
                icon: const Icon(Icons.skip_next),
                label: const Text('Pass'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: g.busy ? null : () => g.newGame(),
                icon: const Icon(Icons.refresh),
                label: const Text('New game'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          DefaultTextStyle(
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.black54),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('move ${g.cursor}/${g.line.length}   '
                  '${g.gameOver ? "game over" : (g.humanToPlay ? "your turn" : "opponent…")}   '
                  '${g.analysisMs} ms   ${g.engine.provider}'),
              if (g.error != null)
                Text(g.error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ]),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: g.busy || benchmarking ? null : () => _benchmark(g),
              icon: const Icon(Icons.speed, size: 18),
              label: Text(benchmarking ? 'Benchmarking…' : 'Benchmark providers'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _benchmark(ShapeGame g) async {
    setState(() => benchmarking = true);
    List<ProviderTiming> results;
    try {
      results = await ShapeEngine.benchmarkProviders(kModelAsset, g.pos);
    } catch (e) {
      results = [ProviderTiming('benchmark failed', null, '$e')];
    }
    if (!mounted) return;
    setState(() => benchmarking = false);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Per-eval time'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in results)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  r.ok ? '${r.provider.padRight(18)} ${r.msPerEval} ms' : '${r.provider}: ${r.error}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: r.ok ? Colors.black87 : Colors.red,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'A provider can accept the model and still run most ops on CPU, so '
              'compare the numbers rather than trusting the name. The /pos rows '
              'are a whole 4-profile position: if batch x4 beats seq x4, flip '
              'useBatchedAnalysis; if an intra=N row beats CPU, pin the threads.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  /// Mistakes-only hides the card unless the move was actually flagged.
  bool _showCard(ShapeGame g) => switch (g.feedbackMode) {
        FeedbackMode.off => false,
        FeedbackMode.all => true,
        FeedbackMode.mistakesOnly => g.feedback?.isMistake ?? false,
      };

  Widget _labelled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 3),
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ),
          child,
        ],
      );

  Widget _feedbackCard(ShapeGame g) {
    final fb = g.feedback;
    if (fb == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('Play a move to see how it looks to each rank.'),
        ),
      );
    }

    final (color, headline) = switch (fb.verdict) {
      MoveVerdict.mistake => (
          const Color(0xFFE53935),
          'Lost ${fb.pointsLost!.toStringAsFixed(1)} points',
        ),
      MoveVerdict.aboveYourLevel => (
          const Color(0xFF0B6E2E),
          'Above your level — a ${rankLabel(g.targetRank)} move',
        ),
      MoveVerdict.typical => (
          const Color(0xFF37474F),
          'Typical ${rankLabel(g.playerRank)} move',
        ),
    };

    // Desktop's rule deliberately doesn't flag a costly move your target rank would
    // also play; say so rather than silently dropping it.
    final excused = fb.costly && fb.verdict != MoveVerdict.mistake;
    final pl = fb.pointsLost;

    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(
              fb.isMistake ? Icons.warning_amber : Icons.check_circle_outline,
              color: color,
              size: 20,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${coordLabel(fb.x, fb.y, g.boardSize)} · $headline',
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
          const SizedBox(height: 8),
          _bar('${rankLabel(g.playerRank)} would play this', fb.playerProb, fb.playerRel),
          _bar('${rankLabel(g.targetRank)} would play this', fb.targetProb, fb.targetRel),
          const SizedBox(height: 4),
          Text(
            'Looks like ${rankLabel(g.targetRank)} rather than ${rankLabel(g.playerRank)}: '
            '${(fb.moveLikeTarget * 100).toStringAsFixed(0)}%'
            '${pl == null ? "" : "   ·   ${pl >= 0 ? "−" : "+"}${pl.abs().toStringAsFixed(1)} pts"}',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          if (excused)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Costly, but ${rankLabel(g.targetRank)} would play it too — not flagged.',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          if (fb.isRare)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Rare move: under 1% at both ranks.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
        ]),
      ),
    );
  }

  Widget _bar(String label, double prob, double rel) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 180, child: Text(label, style: const TextStyle(fontSize: 12))),
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
