// Thin Dart side of the MNN bridge in MainActivity.kt.
//
// Exists because ONNX Runtime has no Android GPU backend: measuring whether this
// phone's GPU beats its CPU requires a runtime that has one. MNN converts the
// same ONNX model exactly (see tools/mnn/), so the comparison is like for like.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// MNNForwardType values from MNN's public enum.
///
/// Vulkan (7) is deliberately absent. On a Galaxy S24+ it loads the model and then
/// dies inside libMNN during inference -- an uncatchable native fault -- while CPU
/// and OpenCL both return correct output at the same speed (104 vs 105 ms). It
/// costs a crash and buys nothing, so it is not offered.
enum MnnBackend {
  cpu(0, 'MNN CPU'),
  openCL(3, 'MNN OpenCL');

  const MnnBackend(this.forwardType, this.label);
  final int forwardType;
  final String label;
}

/// A breadcrumb that outlives the process, so MNN gets exactly one chance.
///
/// MNN dispatches on advertised CPU features, and a machine that lies about them
/// -- the Android emulator on Apple Silicon claims SVE2 -- dies with SIGILL inside
/// libMNN. That is a native fault: no Dart or Kotlin catch can contain it and the
/// process is gone before anything can be recorded. So the marker goes down
/// *before* the first MNN call and is cleared once it returns. Still there at the
/// next launch means MNN killed us, and gameplay takes ONNX Runtime from then on.
///
/// This governs gameplay only. The benchmark button stays an explicit opt-in to
/// try MNN anyway, which is also how a user can find out it now works.
class MnnTrial {
  static File? _file;

  static Future<File> _handle() async =>
      _file ??= File('${await MnnRunner.cacheDir()}/mnn_trial');

  /// True if a previous launch died with a trial in progress.
  static Future<bool> crashedBefore() async => (await _handle()).existsSync();

  static Future<void> begin() async =>
      (await _handle()).writeAsStringSync('trying MNN', flush: true);

  static Future<void> succeeded() async {
    final f = await _handle();
    if (f.existsSync()) f.deleteSync();
  }
}

class MnnRunner {
  static const MethodChannel _channel = MethodChannel('shape/mnn');

  /// Copies [asset] out of the bundle once, then loads it onto [backend].
  ///
  /// MNN needs a filesystem path, and reading the bundle from Kotlin via
  /// AssetManager failed with FileNotFoundException on device despite the entry
  /// being in the APK. rootBundle demonstrably works -- it is how the ONNX of the
  /// same size gets loaded -- so extraction happens here instead.
  static Future<void> load(
    String asset,
    MnnBackend backend, {
    int numThread = 4,
  }) async {
    final path = await _extract(asset);
    await _channel.invokeMethod<void>('load', {
      'path': path,
      'forwardType': backend.forwardType,
      'numThread': numThread,
    });
  }

  static String? _cachedPath;

  static Future<String> _extract(String asset) async {
    final cached = _cachedPath;
    if (cached != null && File(cached).existsSync()) return cached;

    final dir = await _channel.invokeMethod<String>('cacheDir');
    final file = File('$dir/${asset.split('/').last}');
    final data = await rootBundle.load(asset);

    // Re-extract if a previous run was interrupted mid-write.
    if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    _cachedPath = file.path;
    return file.path;
  }

  static Future<Map<String, Float32List>> run(
    Float32List bin,
    Float32List global,
    Float32List meta,
  ) async {
    final out = await _channel.invokeMapMethod<String, Object?>('run', {
      'bin': bin,
      'global': global,
      'meta': meta,
    });
    return {
      for (final e in out!.entries) e.key: e.value as Float32List,
    };
  }

  static Future<void> release() => _channel.invokeMethod<void>('release');

  static Future<String> cacheDir() async =>
      (await _channel.invokeMethod<String>('cacheDir'))!;

  /// Android's own record of why the process last died. Survives a native crash,
  /// unlike anything the app could write itself.
  static Future<Map<String, Object?>?> lastExit() async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('lastExit');
    } catch (_) {
      return null;
    }
  }
}
