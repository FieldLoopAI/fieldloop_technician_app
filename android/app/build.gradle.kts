import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fieldloop.fielloop"
    // Pinned to 36 (rather than flutter.compileSdkVersion) — flutter_pcm_sound's
    // Android dependencies require compileSdk 34+; AAR metadata errors pointed
    // at 36 as the recommended value.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications on Android — it relies on
        // java.time APIs that need desugaring support below API 26.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fieldloop.fielloop"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Pinned to 26 (Android 8.0) rather than flutter.minSdkVersion: background
        // location (ACCESS_BACKGROUND_LOCATION) and its permission-request flow
        // behave differently, or aren't meaningfully supported, below API 26.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // flutter_local_notifications 22.x requires 2.1.4+ (2.0.4 fails
    // :app:checkDebugAarMetadata with "requires desugar_jdk_libs version to
    // be 2.1.4 or above").
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

// Regenerates lib/build_info.dart (build number + build timestamp shown on
// the login screen — see tool/generate_build_info.dart) before every
// Android build, so that label always reflects the actual build instead of
// a value someone forgot to update by hand. `workingDir` is the Flutter
// project root (two levels up from android/app, matching `source` above),
// since the script's relative paths (build_number.txt, lib/build_info.dart)
// assume that as the current directory.
//
// CONFIRMED: a bare `commandLine("dart", ...)` fails here with "A problem
// occurred starting process 'command 'dart''" — Gradle's process launcher
// on Windows doesn't resolve a `.bat` shim off PATH the way a shell does.
// Resolved via the SAME `flutter.sdk` property in local.properties the
// Flutter Gradle plugin itself already relies on, rather than a
// machine-specific hardcoded path.
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}
val flutterSdkPath = localProperties.getProperty("flutter.sdk")
val dartExecutable = if (flutterSdkPath != null) {
    val exeName = if (org.gradle.internal.os.OperatingSystem.current().isWindows) "dart.bat" else "dart"
    "$flutterSdkPath/bin/$exeName"
} else {
    "dart"
}

tasks.register<Exec>("generateBuildInfo") {
    workingDir = file("../..")
    commandLine(dartExecutable, "run", "tool/generate_build_info.dart")
}

tasks.named("preBuild") {
    dependsOn("generateBuildInfo")
}
