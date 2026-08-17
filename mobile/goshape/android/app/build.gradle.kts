plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.sanderland.goshape"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // A 107MB asset has to be stored uncompressed for anything to read it as a
    // file. Same reason TFLite projects always set this.
    androidResources {
        noCompress += listOf("mnn")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.sanderland.goshape"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Committed on purpose. Gradle generates ~/.android/debug.keystore per machine,
    // so every CI runner signed with a different key and each new APK refused to
    // install over the last one ("App not installed"). A fixed key makes updates
    // work. It is worth nothing as a secret -- anyone with this repo can sign an
    // APK that updates over a sideloaded build -- so it must be replaced with a
    // real key kept out of the repo before this is published anywhere.
    signingConfigs {
        create("sideload") {
            storeFile = file("sideload.p12")
            storePassword = "sideload"
            keyAlias = "sideload"
            keyPassword = "sideload"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("sideload")
            // MNN resolves classes from JNI by name; see proguard-rules.pro.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
