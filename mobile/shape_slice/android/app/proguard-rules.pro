# ONNX Runtime's native code looks these classes up by name via JNI (GetMethodID /
# FindClass), so R8 cannot see the references and strips them. Without this, a release
# build dies at the first session.run() with:
#   ClassNotFoundException: ai.onnxruntime.TensorInfo
#   JNI DETECTED ERROR IN APPLICATION: java_class == null in call to GetMethodID
# The flutter_onnxruntime plugin ships no consumer rules, so keep them here.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
