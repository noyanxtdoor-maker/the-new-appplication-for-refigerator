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

// OWNER REVIEW #4 — the Maps API key gate.
//
// The profile APK previously shipped the TRACKED placeholder
// (`DEFAULT_API_KEY`) because `android/secrets.properties` was absent from the
// worktree. The Google Maps Android SDK cannot authorize against that value, so
// the map could not render on a build that passed every test. A profile/release
// build must now fail loudly instead of shipping a map that cannot load.
//
// Debug builds are deliberately left alone so ordinary `flutter run` and the
// widget/unit suites keep working on a machine with no local secret.
val mapsApiKeyProperty = "MAPS_API_KEY"
val mapsApiKeyPlaceholder = "DEFAULT_API_KEY"
val mapsKeyRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true) ||
        it.contains("Profile", ignoreCase = true)
}

fun readMapsApiKeyOrNull(file: File): String? {
    if (!file.exists()) return null
    return file.readLines()
        .asSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") && !it.startsWith("!") }
        .mapNotNull { line ->
            val separators = listOf(line.indexOf('='), line.indexOf(':'))
                .filter { it >= 0 }
            val separator = separators.minOrNull() ?: return@mapNotNull null
            if (line.substring(0, separator).trim() != mapsApiKeyProperty) {
                null
            } else {
                line.substring(separator + 1).trim()
            }
        }
        .firstOrNull()
}

// Precedence is deliberately permissive in the SAFE direction: any local
// secrets file wins over any defaults file, and a Gradle property or environment
// variable is accepted too, so a valid configuration can never be blocked.
val resolvedMapsApiKey: String? = sequenceOf(
    rootProject.file("secrets.properties"),
    project.file("secrets.properties"),
    rootProject.file("secrets.defaults.properties"),
    project.file("secrets.defaults.properties"),
)
    .mapNotNull { readMapsApiKeyOrNull(it) }
    .firstOrNull()
    ?: providers.gradleProperty(mapsApiKeyProperty).orNull
    ?: providers.environmentVariable(mapsApiKeyProperty).orNull

if (
    mapsKeyRequested &&
    (resolvedMapsApiKey.isNullOrBlank() ||
        resolvedMapsApiKey == mapsApiKeyPlaceholder)
) {
    throw GradleException(
        "Maps API key is not configured. Provide android/secrets.properties " +
            "with $mapsApiKeyProperty=<restricted Google Maps Android key>. " +
            "The tracked secrets.defaults.properties only supplies the " +
            "\"$mapsApiKeyPlaceholder\" placeholder, which the Google Maps " +
            "Android SDK cannot authorize against, so the built map would " +
            "never render on device.",
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
