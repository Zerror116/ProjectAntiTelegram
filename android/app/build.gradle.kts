import java.util.Properties

fun buildConfigString(value: String): String {
    val escaped = value
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
    return "\"$escaped\""
}

val defaultUpdateManifestPublicKey = """
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA3q2i6PehgDQjJGDh632o6N43lDFbQUpSbOnaerrTgmk=
-----END PUBLIC KEY-----
""".trimIndent()

val updateManifestPublicKey = System.getenv("APP_UPDATE_MANIFEST_PUBLIC_KEY")
    ?.replace("\\n", "\n")
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
    ?: defaultUpdateManifestPublicKey

val updateManifestKeyId = System.getenv("APP_UPDATE_MANIFEST_KEY_ID")
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
    ?: "dev-ed25519"

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { stream ->
        keystoreProperties.load(stream)
    }
}
val isReleaseTask = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("Release", ignoreCase = true)
}

if (isReleaseTask && !keystorePropertiesFile.exists()) {
    throw GradleException(
        "Release build requires android/key.properties and a real signing keystore.",
    )
}

if (isReleaseTask && updateManifestKeyId == "dev-ed25519") {
    throw GradleException(
        "Release build requires APP_UPDATE_MANIFEST_KEY_ID to be a real production key id.",
    )
}

if (isReleaseTask && updateManifestPublicKey == defaultUpdateManifestPublicKey) {
    throw GradleException(
        "Release build requires a real APP_UPDATE_MANIFEST_PUBLIC_KEY instead of the dev fallback.",
    )
}

android {
    namespace = "com.garphoenix.projectphoenix"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.garphoenix.projectphoenix"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField(
            "String",
            "UPDATE_MANIFEST_PUBLIC_KEY",
            buildConfigString(updateManifestPublicKey),
        )
        buildConfigField(
            "String",
            "UPDATE_MANIFEST_KEY_ID",
            buildConfigString(updateManifestKeyId),
        )
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                val storeFilePath = keystoreProperties["storeFile"]?.toString()?.trim().orEmpty()
                val storePasswordValue = keystoreProperties["storePassword"]?.toString()?.trim().orEmpty()
                val keyAliasValue = keystoreProperties["keyAlias"]?.toString()?.trim().orEmpty()
                val keyPasswordValue = keystoreProperties["keyPassword"]?.toString()?.trim().orEmpty()

                if (storeFilePath.isNotEmpty()) {
                    storeFile = rootProject.file(storeFilePath)
                }
                if (storePasswordValue.isNotEmpty()) {
                    storePassword = storePasswordValue
                }
                if (keyAliasValue.isNotEmpty()) {
                    keyAlias = keyAliasValue
                }
                if (keyPasswordValue.isNotEmpty()) {
                    keyPassword = keyPasswordValue
                }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
