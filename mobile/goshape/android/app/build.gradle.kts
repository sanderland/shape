import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}

fun signingValue(propertyName: String, environmentName: String): String? =
    providers.environmentVariable(environmentName).orNull?.takeIf { it.isNotBlank() }
        ?: signingProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val releaseStorePath = signingValue("storeFile", "SHAPE_ANDROID_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "SHAPE_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "SHAPE_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "SHAPE_ANDROID_KEY_PASSWORD")
val missingSigningValues =
    listOf(
        "storeFile" to releaseStorePath,
        "storePassword" to releaseStorePassword,
        "keyAlias" to releaseKeyAlias,
        "keyPassword" to releaseKeyPassword,
    ).filter { it.second == null }.map { it.first }
val releaseSigningReady = missingSigningValues.isEmpty()

if (
    gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } &&
        !releaseSigningReady
) {
    throw GradleException(
        "Release signing is not configured. Missing: ${missingSigningValues.joinToString()}. " +
            "Set android/key.properties or the SHAPE_ANDROID_* environment variables.",
    )
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

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
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
