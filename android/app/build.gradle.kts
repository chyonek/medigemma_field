plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.medigemma.medigemma_field"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    // ndkVersion = flutter.ndkVersion  // NDK not needed for pure Dart/Flutter app

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.medigemma.medigemma_field"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // flutter_gemma の .litertlm / Vision / Embedding は arm64-v8a のみで動く。
        // 他の ABI を含めると x86_64 エミュレータや古い armeabi-v7a 端末で
        // UnsatisfiedLinkError + クラッシュ。Play Store にも壊れた APK が
        // 配布されてしまうので arm64-v8a に限定。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // flutter_gemma が release build で UnsatisfiedLinkError や
            // missing class を起こさないようコード難読化を無効化。
            // (本アプリは APK サイズ削減より動作優先)
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
