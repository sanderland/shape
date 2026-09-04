# SHAPE

SHAPE is a portrait-only Android app for practising Go against KataGo's
human-policy model. It compares each move with the policies for your current rank
and target rank. It can show likely moves, a rough score, and move-specific
feedback. All inference runs on the phone.

The Flutter app lives in [`app`](app). Its README covers
the controls, gameplay model, SGF support, tests, builds, signing, and known
limits.

The remaining Python under `tools/` exports the KataGo checkpoint, fixtures, and
MNN model used by the Android build. CI runs those exporters before it builds the
APK, so the model binary does not need to be committed.

## Check the app

```sh
cd app
flutter analyze
flutter test
```

The Android build supports arm64 devices running Android 8.0 or newer. It does
not support landscape orientation.
