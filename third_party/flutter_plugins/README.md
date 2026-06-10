# Local Flutter plugin patches

These local plugin copies remove explicit Android Kotlin Gradle Plugin (`apply plugin: 'kotlin-android'`) usage from packages whose latest pub.dev releases have not migrated to Flutter Built-in Kotlin yet.

Flutter applies Kotlin to Android plugin modules automatically when `android.builtInKotlin=true`, so the source code stays unchanged while the future Flutter build-breaking KGP warning is removed.

When upstream packages release Built-in Kotlin-compatible versions, remove these dependency overrides and update `pubspec.yaml` / `pubspec.lock` back to pub.dev packages.
