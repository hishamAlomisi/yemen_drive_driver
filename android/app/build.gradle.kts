plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

// Java properties retain surrounding quotes; passing those quotes to Maps
// produces a valid platform view with no map tiles on the device.
val googleMapsApiKey = localProperties.getProperty("GOOGLE_MAPS_API_KEY", "")
    .trim().removeSurrounding("\"").removeSurrounding("'").trim()
require(googleMapsApiKey.matches(Regex("AIza[0-9A-Za-z_-]{35}"))) {
    "Set a valid GOOGLE_MAPS_API_KEY in android/local.properties before building."
}

android {
    namespace = "com.example.yemen_drive_driver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.yemen_drive_driver"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["GOOGLE_MAPS_API_KEY"] =
            googleMapsApiKey
    }

    buildTypes {
        release {
            // A temporary debug signing key is sufficient for local release
            // testing. Replace it with the production keystore before store
            // distribution.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-auth-api-phone:18.3.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
