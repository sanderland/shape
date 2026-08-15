allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // Swap ONNX Runtime for its QNN-enabled twin, which bundles the Qualcomm AI
    // Engine Direct libraries (libQnnHtp.so and friends) needed to reach the NPU.
    // flutter_onnxruntime depends on the plain artifact and already knows how to
    // request the QNN provider, so substituting the module is enough.
    //
    // NNAPI measured identical to CPU on a Snapdragon S24 (245 vs 242 ms): NNAPI
    // was deprecated in Android 15 and only ever accelerated quantized graphs,
    // so ORT partitions this fp32 net back onto the CPU. QNN HTP supports fp16
    // directly, so this route does not require quantizing the model.
    //
    // Costs: a much larger APK, and it only helps Qualcomm SoCs. The provider
    // fallback chain in ShapeEngine.load means it degrades to CPU elsewhere.
    configurations.all {
        resolutionStrategy.dependencySubstitution {
            substitute(module("com.microsoft.onnxruntime:onnxruntime-android"))
                .using(module("com.microsoft.onnxruntime:onnxruntime-android-qnn:1.23.0"))
                .because("QNN execution provider needs the QNN-bundled AAR")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
