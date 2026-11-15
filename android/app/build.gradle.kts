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

// Release signing — PERMANENT key (created 15 Nov 2026). The keystore
    // is stored ENCRYPTED in the repo (android/app/release.keystore.enc)
    // and decrypted in CI with the KEYSTORE_PASSPHRASE repo secret; the
    // same passphrase is the keystore password AND the key password.
    // Every release build is signed with the SAME key, so installed apps
    // update without uninstalling. Never commit the plaintext
    // release.keystore — it is gitignored and backed up outside the repo.
    val keystoreFile = System.getenv("KEYSTORE_FILE")
    val keystorePassword = System.getenv("KEYSTORE_PASSWORD")
    val keyAlias = System.getenv("KEY_ALIAS")
    val keyPassword = System.getenv("KEY_PASSWORD")
    defaultConfig {
        // FIXED FOREVER: com.nigraantv.audiobox. Never change this.
        applicationId = "com.nigraantv.audiobox"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystoreFile != null) {
                storeFile = rootProject.file(keystoreFile)
                storePassword = keystorePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
            }
        }
    }

    buildTypes {
        release {
            // Signed with the permanent key when the env vars are set
            // (CI); plain debug key only for local development builds.
            signingConfig = if (keystoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
