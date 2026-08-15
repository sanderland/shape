package com.example.shape_slice

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import com.taobao.android.mnn.MNNNetNative
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Minimal bridge to MNN, so the app can compare ONNX Runtime against MNN's CPU,
 * OpenCL and Vulkan backends on real hardware.
 *
 * ONNX Runtime has no Android GPU backend, so measuring whether this phone's GPU
 * beats its CPU means running a second runtime. MNN ships prebuilt .so files with
 * a complete JNI, so this is a thin channel rather than an NDK build.
 *
 * Only what the benchmark needs: load a model on a chosen backend, run one
 * three-input/three-output evaluation, release.
 */
class MainActivity : FlutterActivity() {
    private var netPtr = 0L
    private var sessionPtr = 0L
    private val inputs = HashMap<String, Long>()
    private val outputs = HashMap<String, Long>()

    private companion object {
        const val CHANNEL = "shape/mnn"
        val INPUT_NAMES = arrayOf("bin_input", "global_input", "input_meta")
        val OUTPUT_NAMES = arrayOf("policy", "value", "lead")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "cacheDir" -> result.success(cacheDir.absolutePath)
                        "lastExit" -> result.success(lastExit())
                        "load" -> result.success(
                            load(
                                call.argument<String>("path")!!,
                                call.argument<Int>("forwardType")!!,
                                call.argument<Int>("numThread") ?: 4,
                            )
                        )
                        "run" -> result.success(
                            run(
                                call.argument<FloatArray>("bin")!!,
                                call.argument<FloatArray>("global")!!,
                                call.argument<FloatArray>("meta")!!,
                            )
                        )
                        "release" -> {
                            releaseMnn()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    releaseMnn()
                    result.error("mnn", "${e.javaClass.simpleName}: ${e.message ?: e}", null)
                }
            }
    }

    /**
     * Why the process died last time, straight from Android.
     *
     * A native crash kills the process before any in-app logging can be trusted,
     * so ask the platform instead: getHistoricalProcessExitReasons survives the
     * death and carries the signal and, for native crashes, the tombstone.
     */
    private fun lastExit(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = am.getHistoricalProcessExitReasons(packageName, 0, 5)
            .firstOrNull { it.reason != ApplicationExitInfo.REASON_USER_REQUESTED }
            ?: return null

        val reason = when (info.reason) {
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
            ApplicationExitInfo.REASON_CRASH -> "java crash"
            ApplicationExitInfo.REASON_SIGNALED -> "signalled"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "low memory"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "resource limit"
            else -> "reason ${info.reason}"
        }

        // No tombstone here: traceInputStream returns a protobuf for native crashes,
        // and rendering it as text produced only mojibake. The journal's last step is
        // the useful signal; logcat has the trace for anyone with the device attached.
        return mapOf(
            "reason" to reason,
            "description" to info.description,
            "rssKb" to info.rss,
            "importance" to info.importance,
        )
    }

    /**
     * [path] is a real file, extracted by the Dart side via rootBundle.
     *
     * Extraction deliberately does NOT go through AssetManager here: opening
     * flutter_assets/... that way returned FileNotFoundException on device even
     * though the entry is present in the APK. rootBundle already loads the 107MB
     * ONNX without trouble, so the Dart side writes the model out and hands over
     * a path.
     */
    private fun load(path: String, forwardType: Int, numThread: Int): Map<String, Any> {
        releaseMnn()
        MNNNetNative.ensureLoaded()
        check(File(path).exists()) { "model not found at $path" }

        netPtr = MNNNetNative.nativeCreateNetFromFile(path)
        check(netPtr != 0L) { "MNN could not load $path" }

        sessionPtr = MNNNetNative.nativeCreateSession(
            netPtr, forwardType, numThread, emptyArray(), OUTPUT_NAMES
        )
        // A GPU backend that is unavailable returns a null session rather than
        // throwing, so treat that as the failure it is instead of crashing later.
        check(sessionPtr != 0L) { "MNN backend $forwardType unavailable" }

        for (name in INPUT_NAMES) {
            val t = MNNNetNative.nativeGetSessionInput(netPtr, sessionPtr, name)
            check(t != 0L) { "missing input $name" }
            inputs[name] = t
        }

        // The ONNX export has a dynamic batch axis, which the Interpreter API leaves
        // unresolved -- writing into such a tensor segfaults inside libMNN. Pin the
        // shapes and re-plan the session before touching any data. (MNN's Module API,
        // used by the desktop parity check, resizes on its own; this one does not.)
        MNNNetNative.nativeReshapeTensor(netPtr, inputs["bin_input"]!!, intArrayOf(1, 22, 19, 19))
        MNNNetNative.nativeReshapeTensor(netPtr, inputs["global_input"]!!, intArrayOf(1, 19))
        MNNNetNative.nativeReshapeTensor(netPtr, inputs["input_meta"]!!, intArrayOf(1, 192))
        MNNNetNative.nativeReshapeSession(netPtr, sessionPtr)

        // Output tensors must be fetched after the reshape, or they describe the
        // pre-resize plan.
        for (name in OUTPUT_NAMES) {
            val t = MNNNetNative.nativeGetSessionOutput(netPtr, sessionPtr, name)
            check(t != 0L) { "missing output $name" }
            outputs[name] = t
        }
        return mapOf("ok" to true)
    }

    private fun run(bin: FloatArray, global: FloatArray, meta: FloatArray): Map<String, FloatArray> {
        check(sessionPtr != 0L) { "no MNN session" }
        MNNNetNative.nativeSetInputFloatData(netPtr, inputs["bin_input"]!!, bin)
        MNNNetNative.nativeSetInputFloatData(netPtr, inputs["global_input"]!!, global)
        MNNNetNative.nativeSetInputFloatData(netPtr, inputs["input_meta"]!!, meta)

        MNNNetNative.nativeRunSession(netPtr, sessionPtr)

        return OUTPUT_NAMES.associateWith { name ->
            val t = outputs[name]!!
            // Size from the declared dimensions rather than the null-probe overload,
            // which is one more thing that could be wrong in native code.
            var n = 1
            for (d in MNNNetNative.nativeTensorGetDimensions(t)) n *= d
            val buf = FloatArray(n)
            MNNNetNative.nativeTensorGetData(t, buf)
            buf
        }
    }

    private fun releaseMnn() {
        if (sessionPtr != 0L && netPtr != 0L) MNNNetNative.nativeReleaseSession(netPtr, sessionPtr)
        if (netPtr != 0L) MNNNetNative.nativeReleaseNet(netPtr)
        sessionPtr = 0L
        netPtr = 0L
        inputs.clear()
        outputs.clear()
    }

    override fun onDestroy() {
        releaseMnn()
        super.onDestroy()
    }
}
