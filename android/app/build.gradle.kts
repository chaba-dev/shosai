import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter passes both --dart-define and --dart-define-from-file here. Keep
// the browser callback scheme aligned with Dart, including fork registrations.
val dartDefines = (project.findProperty("dart-defines") as? String)
    .orEmpty().split(",").filter { it.isNotEmpty() }.associate {
        val value = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
        value.substringBefore("=") to value.substringAfter("=", "")
    }
val production = dartDefines["SHOSAI_PRODUCTION"] == "true"
val devDropboxKey = "3yy8xd4pncextkh"
val dropboxKey = dartDefines["SHOSAI_DROPBOX_APP_KEY"] ?: if (production) "" else devDropboxKey
require(dropboxKey.matches(Regex("[a-zA-Z0-9]*"))) { "Invalid Dropbox app key" }
require(!production || dropboxKey != devDropboxKey) {
    "Use a separate production Dropbox app key or leave Dropbox disabled"
}

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

    testOptions { unitTests.isIncludeAndroidResources = true }

    sourceSets.configureEach {
        if (name == "debug" || name == "profile") {
            res.srcDir("src/dev/res")
        }
    }

    defaultConfig {
        applicationId = if (production) "dev.shosai.reader" else "dev.shosai.shosai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = if (production) "Shōsai" else "Shōsai Dev"
        // Dropbox uses AppAuth's browser callback. Google still uses GIS.
        manifestPlaceholders["appAuthRedirectScheme"] =
            if (production && dropboxKey.isEmpty()) "dev.shosai.reader.dropbox-disabled" else "db-$dropboxKey"
    }

    signingConfigs {
        if (production) {
            create("production") {
                fun required(name: String) = providers.environmentVariable(name).orNull
                    ?.takeIf { it.isNotBlank() } ?: error("Set $name for production signing")
                storeFile = file(required("SHOSAI_ANDROID_KEYSTORE"))
                storePassword = required("SHOSAI_ANDROID_STORE_PASSWORD")
                keyAlias = required("SHOSAI_ANDROID_KEY_ALIAS")
                keyPassword = required("SHOSAI_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (production) "production" else "debug")
        }
    }
}

androidComponents.beforeVariants { variant ->
    if (production && variant.buildType != "release") variant.enable = false
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
