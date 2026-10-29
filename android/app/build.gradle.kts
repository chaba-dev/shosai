import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter passes both --dart-define and --dart-define-from-file here. Keep
// the SDK callback scheme aligned with Dart, including fork registrations.
val dartDefines = (project.findProperty("dart-defines") as? String)
    .orEmpty().split(",").filter { it.isNotEmpty() }.associate {
        val value = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
        value.substringBefore("=") to value.substringAfter("=", "")
    }
val dropboxKey = dartDefines["SHOSAI_DROPBOX_APP_KEY"] ?: "3yy8xd4pncextkh"
require(dropboxKey.matches(Regex("[a-zA-Z0-9]*"))) { "Invalid Dropbox app key" }

android {
    namespace = "dev.shosai.shosai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures { buildConfig = true }
    testOptions { unitTests.isIncludeAndroidResources = true }

    sourceSets.configureEach {
        if (name == "debug" || name == "profile") {
            res.srcDir("src/dev/res")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.shosai.shosai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Debug and profile builds (Flutter's profile type starts from debug)
        // are told apart from the released app on the launcher.
        manifestPlaceholders["appLabel"] = "Shōsai Dev"
        manifestPlaceholders["dropboxKey"] = dropboxKey
        buildConfigField("String", "DROPBOX_APP_KEY", "\"$dropboxKey\"")
        // AppAuth is used only on iOS. Android Google authorization uses GIS,
        // never this plugin's custom-scheme redirect receiver.
        manifestPlaceholders["appAuthRedirectScheme"] = "dev.shosai.unused-appauth"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            manifestPlaceholders["appLabel"] = "Shōsai"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Last SDK supporting API 21+ / Java 17; 7.1+ requires API 26, 8.x Java 21.
    implementation("com.dropbox.core:dropbox-android-sdk:7.0.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
