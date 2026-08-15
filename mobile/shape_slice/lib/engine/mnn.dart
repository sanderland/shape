// Thin Dart side of the MNN bridge in MainActivity.kt.
//
// Exists because ONNX Runtime has no Android GPU backend: measuring whether this
// phone's GPU beats its CPU requires a runtime that has one. MNN converts the
// same ONNX model exactly (see tools/mnn/), so the comparison is like for like.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// MNNForwardType values from MNN's public enum.
enum MnnBackend {
  cpu(0, 'MNN CPU'),
  openCL(3, 'MNN OpenCL'),
  vulkan(7, 'MNN Vulkan');

  const MnnBackend(this.forwardType, this.label);
  final int forwardType;
  final String label;
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
}
