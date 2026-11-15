plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nigraantv.audiobox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Release signing is a FOLLOW-UP (see README): create a keystore and
    // add a signingConfigs block like TJ Earn's before any public build.
    // Until then, release builds fall back to the debug key (local
    // development only) — never ship a build signed with a different key
    // later, or installed users would need to uninstall before updating.
    defaultConfig {
        // FIXED FOREVER: com.nigraantv.audiobox. Never change this.
        applicationId = "com.nigraantv.audiobox"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
