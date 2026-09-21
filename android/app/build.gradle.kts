plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.xstocker.tabletbrowser"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Application id frozen by docs/CONTRACT.md.
        applicationId = "com.xstocker.tabletbrowser"
        // Android 7.0 (API 24): the minimum the WebView platform view layer targets.
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://flutter.dev/to/build-apk-splits)
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

    testOptions {
        unitTests {
            // Lets :app:testDebugUnitTest read src/test/resources/policy_test_vectors.json
            // and keeps android.jar stubs from breaking JVM unit tests.
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // android.jar only ships org.json stubs on the unit-test classpath, so the
    // real implementation is added explicitly.
    testImplementation("org.json:json:20240303")
}

// Gradle 9's strict validation rejects the unit-test packaging tasks consuming
// the merged-assets directory that the Flutter plugin also writes into via
// `copyFlutterAssets<Variant>`, because no explicit dependency exists. Declare
// the edge so `:app:testDebugUnitTest` can run.
tasks.matching { task ->
    task.name.startsWith("package") && task.name.endsWith("UnitTestForUnitTest")
}.configureEach {
    val variant = name.removePrefix("package").removeSuffix("UnitTestForUnitTest")
    dependsOn(project.tasks.matching { it.name == "copyFlutterAssets$variant" })
}

flutter {
    source = "../.."
}
