import java.util.Properties

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

android {
    namespace = "com.garphoenix.projectphoenix"
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
        applicationId = "com.garphoenix.projectphoenix"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
