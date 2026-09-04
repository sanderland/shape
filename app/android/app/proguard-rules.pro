# MNN's native code resolves this class and its methods by name through JNI
# (Java_com_taobao_android_mnn_MNNNetNative_*), so R8 cannot see the references and
# would strip or rename them. A release build would then die at the first native
# call with UnsatisfiedLinkError.
-keep class com.taobao.android.mnn.** { *; }
-keepclassmembers class com.taobao.android.mnn.** { *; }
