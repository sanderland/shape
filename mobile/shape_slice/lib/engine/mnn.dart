// Thin Dart side of the MNN bridge in MainActivity.kt.
//
// Exists because ONNX Runtime has no Android GPU backend: measuring whether this
// phone's GPU beats its CPU requires a runtime that has one. MNN converts the
// same ONNX model exactly (see tools/mnn/), so the comparison is like for like.

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

  /// Loads [asset] onto [backend]. Throws if the backend is unavailable, which
  /// is the expected outcome for a GPU the device or driver does not support.
  static Future<void> load(
    String asset,
    MnnBackend backend, {
    int numThread = 4,
  }) async {
    await _channel.invokeMethod<void>('load', {
      'asset': asset,
      'forwardType': backend.forwardType,
      'numThread': numThread,
    });
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
}
