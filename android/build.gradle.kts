allprojects {
    repositories {
        google()
        mavenCentral()
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

// Some plugin AARs (e.g. flutter_pcm_sound) hardcode their own, older
// compileSdkVersion in their bundled android/build.gradle — set independently
// of :app's compileSdk (android/app/build.gradle.kts), so bumping only that
// doesn't help. androidx transitive deps then fail :checkDebugAarMetadata,
// demanding compileSdk 34+. Forces every subproject that applies an Android
// plugin to compile against the same compileSdk as :app (36) instead of
// patching each plugin's cached sources individually. targetSdk/minSdk are
// untouched — this only affects what API surface is compiled against.
subprojects {
    // Must win a race on BOTH sides:
    // - Must run AFTER the subproject's own script, not at plugin-apply time
    //   (`pluginManager.withPlugin` fires the moment `apply plugin:` runs,
    //   which for flutter_pcm_sound is BEFORE its own later
    //   `compileSdkVersion 33` line — so that line would still win and
    //   silently overwrite this override back to 33).
    // - But plain `afterEvaluate` throws "Cannot run Project.afterEvaluate
    //   (Action) when the project is already evaluated" for :app
    //   specifically, because the `evaluationDependsOn(":app")` block above
    //   already forces :app to fully evaluate earlier, before this action
    //   reaches it in the `subprojects {}` iteration.
    val overrideCompileSdk: () -> Unit = {
        if (plugins.hasPlugin("com.android.application") || plugins.hasPlugin("com.android.library")) {
            extensions.configure<com.android.build.gradle.BaseExtension> {
                compileSdkVersion(36)
            }
        }
    }
    if (state.executed) {
        overrideCompileSdk()
    } else {
        afterEvaluate { overrideCompileSdk() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// flutter_sound's plugin module depends on the prebuilt
// `com.github.canardoux:flutter_sound_core:9.30.0` from JitPack; every
// subproject gets the vendored, patched copy in ./flutter_sound_core instead
// (same version, one class changed — see flutter_sound_core/README.md).
subprojects {
    configurations.all {
        resolutionStrategy.dependencySubstitution {
            substitute(module("com.github.canardoux:flutter_sound_core"))
                .using(project(":flutter_sound_core"))
        }
    }
}
