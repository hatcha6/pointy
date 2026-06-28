import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Optional release signing. CI (or a local release build) drops an
// `android/key.properties` file that points at a keystore; when it is absent we
// fall back to debug signing so day-to-day `flutter run --release` still works
// for developers who have no production key. See the release workflow for the
// secrets it expects (ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
// ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseSigning = keystorePropertiesFile.exists()

// Oldest Android we serve: API 24 (Android 7.0 Nougat). We bumped from 23 because
// image_picker_android (and other plugins) now require minSdk 24, and Flutter
// itself is deprecating 23 and will soon drop support for it. 24 is also Flutter's
// current `flutter.minSdkVersion` default.
//
// Kept as a variable rather than a bare `minSdk = 24` so we stay clear of Flutter's
// gradle migrator, which rewrites literal `minSdk = 16..23` back to
// `flutter.minSdkVersion` on every `flutter build`. The val keeps the floor
// explicit and self-documenting.
val oldestSupportedApi = 24

android {
    namespace = "ly.daftr"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ly.daftr"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        //
        // Oldest supported Android (API 24 / Android 7.0). See oldestSupportedApi
        // above for why this is a variable and not a literal.
        minSdk = oldestSupportedApi
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only declared when a keystore is supplied; otherwise the release build
        // below stays on debug signing.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the real upload key when CI provides one, otherwise fall back to
            // debug signing so `flutter run --release` keeps working locally.
            signingConfig = if (hasReleaseSigning) {
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
