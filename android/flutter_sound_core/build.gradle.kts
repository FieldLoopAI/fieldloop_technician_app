// Vendored flutter_sound_core 9.30.0 (https://github.com/canardoux/flutter_sound_core,
// tag 9.30.0, commit 7036dd1d), MPL-2.0 — see LICENSE and README.md here.
// Substituted for the `com.github.canardoux:flutter_sound_core:9.30.0` JitPack
// artifact that the flutter_sound plugin depends on (see ../build.gradle.kts).
// This file replaces upstream's build.gradle (which pins AGP 8.6 and carries
// publishing tasks); the android/dependencies settings below are upstream's.
plugins {
    id("com.android.library")
}

android {
    namespace = "com.github.canardoux"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core:1.3.2")
    implementation("androidx.media:media:1.4.1")
    implementation("androidx.appcompat:appcompat:1.2.0")
}
