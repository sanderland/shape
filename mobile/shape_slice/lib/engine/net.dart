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
  final double winrate;

  const NetOutputs(this.policy, this.lead, this.winrate);
}

/// The net, loaded and callable. Abstract so the game loop can be tested against
/// a fake instead of a 107 MB model on a device.
abstract class NetRunner {
  String get label;
  Future<NetOutputs> run(Float32List bin, Float32List global, Float32List meta);
  Future<void> close();
}

class MnnRunner implements NetRunner {
  static const MethodChannel _channel = MethodChannel('shape/mnn');

  @override
  String get label => 'MNN CPU';

  static Future<MnnRunner> load() async {
    await _channel.invokeMethod<void>('load', {'path': await _extract()});
    return MnnRunner();
  }

  /// MNN needs a filesystem path, so the model is copied out of the bundle once.
  ///
  /// Extraction happens here rather than in Kotlin because opening the asset there
  /// through AssetManager returned FileNotFoundException on device despite the
  /// entry being present in the APK, while rootBundle reads it without trouble.
  static Future<String> _extract() async {
    final dir = await _channel.invokeMethod<String>('cacheDir');
    final file = File('$dir/${kMnnAsset.split('/').last}');
    final data = await rootBundle.load(kMnnAsset);

    // Re-extract if a previous run was interrupted part-way through writing.
    if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
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
      // value is a softmax over {win, loss, noresult} for the side to move.
      (out['value'] as Float32List).first,
    );
  }

  @override
  Future<void> close() => _channel.invokeMethod<void>('release');
}
