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

// Workaround: package:jni (pulled in transitively by path_provider_android
// 2.3.1) only applies the Kotlin Gradle plugin when AGP < 9, but its build
// script always configures a top-level `kotlin { }` block. On AGP 9 with
// Flutter's `android.builtInKotlin=false`, that block has no owner and
// evaluating the module fails with "Could not find method kotlin()".
//
// Flutter's own auto-apply doesn't cover it: its detector greps the build file
// for `apply plugin: 'kotlin-android'` and finds jni's line, not noticing that
// it sits inside an `if (agpMajor < 9)` branch that never runs here.
//
// So apply KGP ourselves, scoped to that module, and only once AGP has been
// applied inside it — which lands between jni's `com.android.library` line and
// its `kotlin { }` block. Remove when jni ships an AGP 9-clean build script.
subprojects {
    if (name == "jni") {
        pluginManager.withPlugin("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
