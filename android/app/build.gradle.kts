plugins {
    id("com.android.application")
    id("com.google.android.libraries.mapsplatform.secrets-gradle-plugin")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = mapOf(
    "storeFile" to providers.environmentVariable("NEXT_TRANSFER_RELEASE_STORE_FILE").orNull,
    "storePassword" to providers.environmentVariable("NEXT_TRANSFER_RELEASE_STORE_PASSWORD").orNull,
    "keyAlias" to providers.environmentVariable("NEXT_TRANSFER_RELEASE_KEY_ALIAS").orNull,
    "keyPassword" to providers.environmentVariable("NEXT_TRANSFER_RELEASE_KEY_PASSWORD").orNull,
).mapValues { (_, value) -> value?.trim()?.takeIf(String::isNotEmpty) }
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val releaseSigningComplete = releaseSigningValues.values.all { it != null }

if (releaseRequested && !releaseSigningComplete) {
    throw GradleException(
        "Release signing requires all NEXT_TRANSFER_RELEASE_* environment variables.",
    )
}

android {
    namespace = "com.nexttransfer.rmplanner"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.nexttransfer.rmplanner"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningComplete) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("storeFile")!!)
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (releaseSigningComplete) {
                signingConfig = signingConfigs.getByName("release")
            }
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
    // Android 12 system splash API, used only to make the required platform
    // launch stage continuous with the approved Flutter intro artwork.
    implementation("androidx.core:core-splashscreen:1.0.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // M4 recovery receiver enqueues one bounded canonical WorkManager task.
    // Same version the workmanager plugin itself compiles against; the merged
    // manifest is unchanged because the plugin already contributes androidx.work.
    implementation("androidx.work:work-runtime:2.11.2")
}

secrets {
    propertiesFileName = "secrets.properties"
    defaultPropertiesFileName = "secrets.defaults.properties"
}
