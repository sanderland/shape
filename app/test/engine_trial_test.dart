import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/engine/net.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unfinished engine trial is consumed once', () async {
    final temp = Directory.systemTemp.createTempSync('shape-engine-trial-');
    addTearDown(() => temp.deleteSync(recursive: true));
    const channel = MethodChannel('shape/host');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cacheDir') return temp.path;
          throw MissingPluginException(call.method);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    expect(await EngineTrial.takePreviousFailure(), isFalse);
    await EngineTrial.begin();
    expect(await EngineTrial.takePreviousFailure(), isTrue);
    expect(
      await EngineTrial.takePreviousFailure(),
      isFalse,
      reason: 'the next launch may try the model again',
    );
  });
}
