package com.taobao.android.mnn;

/**
 * Declarations matching the JNI already exported by MNN's prebuilt libmnncore.so.
 *
 * MNN publishes prebuilt Android .so files but no AAR, so rather than building the
 * library from source with the NDK we just declare the native methods it already
 * exposes. The package and class name must stay exactly as they are -- the JNI
 * symbols are Java_com_taobao_android_mnn_MNNNetNative_* -- but the methods are
 * public here (the upstream demo has them protected) so callers outside this
 * package can use them.
 *
 * Taken from MNN's own demo app; see
 * project/android/demo/app/src/main/java/com/taobao/android/mnn/MNNNetNative.java
 */
public class MNNNetNative {
    static {
        System.loadLibrary("MNN");
        System.loadLibrary("MNN_Express");
        System.loadLibrary("mnncore");
    }

    /** Forces the static initialiser to run, so library loading errors surface early. */
    public static void ensureLoaded() {}

    // Net
    public static native long nativeCreateNetFromFile(String modelName);

    public static native long nativeReleaseNet(long netPtr);

    // Session. forwardType is MNNForwardType: 0 CPU, 3 OpenCL, 7 Vulkan.
    public static native long nativeCreateSession(
            long netPtr, int forwardType, int numThread, String[] saveTensors, String[] outputTensors);

    public static native void nativeReleaseSession(long netPtr, long sessionPtr);

    public static native int nativeRunSession(long netPtr, long sessionPtr);

    public static native int nativeReshapeSession(long netPtr, long sessionPtr);

    public static native long nativeGetSessionInput(long netPtr, long sessionPtr, String name);

    public static native long nativeGetSessionOutput(long netPtr, long sessionPtr, String name);

    // Tensor
    public static native void nativeReshapeTensor(long netPtr, long tensorPtr, int[] dims);

    public static native int[] nativeTensorGetDimensions(long tensorPtr);

    public static native void nativeSetInputFloatData(long netPtr, long tensorPtr, float[] data);

    /** Returns the element count when dest is null, otherwise fills dest. */
    public static native int nativeTensorGetData(long tensorPtr, float[] dest);
}
