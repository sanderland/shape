package io.github.sanderland.goshape

import android.os.Build
import com.taobao.android.mnn.MNNNetNative
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Bridge to MNN, which runs the human-SL net.
 *
 * MNN ships prebuilt Android .so files with a complete JNI, so this is a thin
 * method channel rather than an NDK build. Only what the engine needs: load the
 * model, run one three-input/two-output evaluation, release.
 */
class MainActivity : FlutterActivity() {
    private var netPtr = 0L
    private var sessionPtr = 0L
    private val inputs = HashMap<String, Long>()
    private val outputs = HashMap<String, Long>()

    private companion object {
        const val CHANNEL = "shape/host"

        /** MNNForwardType MNN_FORWARD_CPU. The GPU backends were measured and are
         *  not worth having: OpenCL matched the CPU to within a millisecond and
         *  Vulkan crashed during inference. */
        const val FORWARD_CPU = 0
        const val NUM_THREADS = 4
        val INPUT_NAMES = arrayOf("bin_input", "global_input", "input_meta")
        val OUTPUT_NAMES = arrayOf("policy", "lead")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "cacheDir" -> result.success(cacheDir.absolutePath)
                        "version" -> result.success(appVersion())
                        "load" -> {
                            load(call.argument<String>("path")!!)
                            result.success(null)
                        }
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

    /** Version name and code, straight from the installed package. */
    private fun appVersion(): String {
        val info = packageManager.getPackageInfo(packageName, 0)
        return "${info.versionName} (${info.longVersionCode})"
    }

    /**
     * [path] is a real file, extracted on the Dart side via rootBundle.
     *
     * Deliberately not read through AssetManager here: opening flutter_assets/...
     * that way returns FileNotFoundException on device even though the entry is in
     * the APK. Moving extraction back into Kotlin will hit that again.
     */

    /**
     * True on the Android emulator, which cannot run this library.
     *
     * MNN picks its kernels from the CPU features the machine advertises, and the
     * emulator claims ARMv8.2 extensions (SVE2 among them) that it does not
     * implement, so libMNN dispatches to instructions that fault with SIGILL. That
     * is a native fault: it kills the process outright, and no Kotlin or Dart catch
     * can contain it. The only way not to crash is not to call it, so refuse here
     * and let the app fall back to running without an engine.
     */
    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.lowercase().contains("emulator") ||
            Build.MODEL.contains("sdk_gphone") ||
            Build.MODEL.contains("Emulator") ||
            Build.PRODUCT.contains("sdk") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu")

    private fun load(path: String) {
        check(!isEmulator()) {
            "not supported on the Android emulator, which advertises CPU features " +
                "it does not implement"
        }
        releaseMnn()
        MNNNetNative.ensureLoaded()
        check(File(path).exists()) { "model not found at $path" }

        netPtr = MNNNetNative.nativeCreateNetFromFile(path)
        check(netPtr != 0L) { "MNN could not load $path" }

        sessionPtr = MNNNetNative.nativeCreateSession(
            netPtr, FORWARD_CPU, NUM_THREADS, emptyArray(), OUTPUT_NAMES
        )
        check(sessionPtr != 0L) { "MNN could not create a session" }

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
