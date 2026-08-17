// Running the human-SL net on device, through MNN.
//
// MNN rather than ONNX Runtime because it is twice as fast on the same model and
// the same output: 104 ms/eval against 217 on a Galaxy S24+. Its GPU backends were
// measured too and are not worth having -- OpenCL tied the CPU to within a
// millisecond, and Vulkan crashed -- so CPU is the only backend offered.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

const String kMnnAsset = 'assets/humanv0.mnn';

/// One evaluation of the net.
class NetOutputs {
  final Float32List policy;

  /// Score lead for the side to move.
  final double lead;

  const NetOutputs(this.policy, this.lead);
}

/// The net, loaded and callable. Abstract so the game loop can be tested against
/// a fake instead of a 107 MB model on a device.
abstract class NetRunner {
  String get label;
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta);
  Future<void> close();
}

/// A breadcrumb that outlives the process, so a device that faults does so once.
///
/// A SIGILL inside libMNN kills the process before any handler runs, so nothing
/// the app writes at the time survives. The marker therefore goes down *before*
/// the first call and is cleared once one has returned. Finding it still there at
/// the next launch means the engine killed us, and the app starts without one.
class EngineTrial {
  static File? _file;

  static Future<File> _handle() async =>
      _file ??= File('${await MnnRunner.cacheDir()}/engine_trial');

  static Future<bool> crashedBefore() async => (await _handle()).existsSync();

  static Future<void> begin() async =>
      (await _handle()).writeAsStringSync('loading engine', flush: true);

  static Future<void> survived() async {
    final f = await _handle();
    if (f.existsSync()) f.deleteSync();
  }
}

class MnnRunner implements NetRunner {
  static const MethodChannel _channel = MethodChannel('shape/mnn');

  @override
  String get label => 'MNN CPU';

  static Future<MnnRunner> load() async {
    await _channel.invokeMethod<void>('load', {'path': await _extract()});
    return MnnRunner();
  }

  static Future<String> cacheDir() async =>
      (await _channel.invokeMethod<String>('cacheDir'))!;

  /// MNN needs a filesystem path, so the model is copied out of the bundle once.
  ///
  /// Extraction happens here rather than in Kotlin because opening the asset there
  /// through AssetManager returned FileNotFoundException on device despite the
  /// entry being present in the APK, while rootBundle reads it without trouble.
  static Future<String> _extract() async {
    final dir = await _channel.invokeMethod<String>('cacheDir');
    final file = File('$dir/${kMnnAsset.split('/').last}');
    final data = await rootBundle.load(kMnnAsset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    // Written to a temp file and renamed, so a partial write can never appear at
    // the destination and the length is enough to tell a stale copy from a current
    // one. Hashing the model instead costs ~0.5s of every launch to detect
    // something the rename prevents and verifyAgainstReference already catches.
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    }
    return file.path;
  }

  @override
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta) async {
    final out = await _channel.invokeMapMethod<String, Object?>('run', {
      'bin': bin,
      'global': global,
      'meta': meta,
    });
    return NetOutputs(
      out!['policy'] as Float32List,
      (out['lead'] as Float32List).first,
    );
  }

  @override
  Future<void> close() => _channel.invokeMethod<void>('release');
}
