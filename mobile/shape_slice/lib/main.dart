// SHAPE mobile slice: run the KataGo human-SL net on device for one fixed position.
//
// bin_input/global_input are precomputed on desktop and shipped as an asset, so the
// only thing under test here is on-device inference plus the Dart meta encoding.
// Switching rank rebuilds input_meta in Dart and re-runs the net, and the result is
// checked against the desktop reference so we prove correctness, not just execution.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'board_painter.dart';
import 'sgf_metadata.dart';

// Swap to the .int8 asset for a ~4x smaller model; expect ~2e-2 policy error
// instead of ~1e-7, so the tolerance below is graded rather than pass/fail.
const kModelAsset = 'assets/b18c384nbt-humanv0.onnx';
const kExactTol = 1e-3; // fp32: should match desktop to float rounding
const kQuantTol = 5e-2; // int8: weights-only quantization error
const kPositionAsset = 'assets/position.bin';
const kReferenceAsset = 'assets/reference.json';

const kBinLen = 22 * kBoardSize * kBoardSize;
const kGlobalLen = 19;

/// Flattens ORT's nested output (List / Float32List / num) into a flat doubles list.
List<double> _flatten(dynamic v) {
  if (v is num) return [v.toDouble()];
  if (v is Float32List) return List<double>.from(v);
  if (v is List) return v.expand(_flatten).toList();
  throw ArgumentError('unexpected ORT output element: ${v.runtimeType}');
}

String _verdict(double d) => d < kExactTol
    ? 'MATCH'
    : d < kQuantTol
        ? 'CLOSE (quantized)'
        : 'MISMATCH';

void main() => runApp(const ShapeSliceApp());

class ShapeSliceApp extends StatelessWidget {
  const ShapeSliceApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SHAPE slice',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6E2E)),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  OrtSession? _session;
  Float32List? _bin;
  Float32List? _global;
  Map<String, dynamic>? _ref;
  List<List<String>> _board =
      List.generate(kBoardSize, (_) => List.filled(kBoardSize, '.'));
  int _nextPlayer = kWhite;

  List<String> _profiles = [];
  String? _profile;
  List<double>? _policy;
  double? _lead;
  int _inferMs = 0;
  int _loadMs = 0;
  double? _maxDiff;
  String _status = 'loading…';
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sw = Stopwatch()..start();

      final posBytes = await rootBundle.load(kPositionAsset);
      final all = posBytes.buffer
          .asFloat32List(posBytes.offsetInBytes, kBinLen + kGlobalLen);
      _bin = Float32List.fromList(all.sublist(0, kBinLen));
      _global = Float32List.fromList(all.sublist(kBinLen));

      _ref = jsonDecode(await rootBundle.loadString(kReferenceAsset));
      _board = (_ref!['board'] as List)
          .map<List<String>>((r) => (r as List).map((e) => e as String).toList())
          .toList();
      _nextPlayer = _ref!['nextPlayer'] == 'W' ? kWhite : kBlack;
      _profiles = (_ref!['profiles'] as Map).keys.cast<String>().toList();

      setState(() => _status = 'loading model (107 MB)…');
      _session = await OnnxRuntime().createSessionFromAsset(kModelAsset);
      _loadMs = sw.elapsedMilliseconds;

      _profile = _profiles.firstWhere((p) => p == 'rank_5k',
          orElse: () => _profiles.first);
      await _run();
    } catch (e, st) {
      debugPrint('$e\n$st');
      setState(() {
        _error = e;
        _status = 'failed';
      });
    }
  }

  Future<void> _run() async {
    final session = _session;
    final profile = _profile;
    if (session == null || profile == null) return;
    setState(() => _status = 'running $profile…');

    final meta =
        getProfile(profile).getMetadataRow(_nextPlayer, kBoardSize * kBoardSize);

    final inputs = {
      'bin_input': await OrtValue.fromList(
          _bin!, [1, 22, kBoardSize, kBoardSize]),
      'global_input': await OrtValue.fromList(_global!, [1, kGlobalLen]),
      'input_meta': await OrtValue.fromList(meta, [1, kMetadataChannels]),
    };

    final sw = Stopwatch()..start();
    final outputs = await session.run(inputs);
    final ms = sw.elapsedMilliseconds;

    // asList() hands back the tensor's nested shape (e.g. [1,362] -> a List
    // holding one Float32List row), so flatten rather than cast element-wise.
    final policy = _flatten(await outputs['policy']!.asList());
    final lead = _flatten(await outputs['lead']!.asList()).first;

    for (final v in inputs.values) {
      v.dispose();
    }

    // Compare against the desktop reference: same position, same profile.
    final refTop = (_ref!['profiles'][profile]['top'] as List);
    var maxDiff = 0.0;
    for (final e in refTop) {
      final d = (policy[e['idx'] as int] - (e['p'] as num).toDouble()).abs();
      if (d > maxDiff) maxDiff = d;
    }

    setState(() {
      _policy = policy;
      _lead = lead;
      _inferMs = ms;
      _maxDiff = maxDiff;
      _status = 'ok';
    });
  }

  @override
  Widget build(BuildContext context) {
    final best = _policy == null
        ? null
        : List<int>.generate(kBoardSize * kBoardSize, (i) => i)
            .reduce((a, b) => _policy![a] >= _policy![b] ? a : b);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SHAPE · human-SL on device'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: Text('$_error',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: CustomPaint(
                        painter:
                            BoardPainter(board: _board, policy: _policy),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: [
                        const Text('Rank  '),
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _profile,
                            items: _profiles
                                .map((p) => DropdownMenuItem(
                                    value: p, child: Text(p)))
                                .toList(),
                            onChanged: _session == null
                                ? null
                                : (v) {
                                    setState(() => _profile = v);
                                    _run();
                                  },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: DefaultTextStyle(
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: Colors.black87),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('status      $_status'),
                            Text('model load  $_loadMs ms'),
                            Text('inference   $_inferMs ms'),
                            if (best != null)
                              Text('top move    ${idxToGtp(best)}'
                                  '  ${(_policy![best] * 100).toStringAsFixed(1)}%'),
                            if (_lead != null)
                              Text('scoreLead   ${_lead!.toStringAsFixed(2)}'),
                            if (_maxDiff != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'vs desktop  ${_maxDiff!.toStringAsExponential(2)}'
                                '  ${_verdict(_maxDiff!)}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                  color: _maxDiff! < kQuantTol
                                      ? const Color(0xFF0B6E2E)
                                      : Colors.red,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
