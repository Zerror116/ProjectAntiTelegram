import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class FirebaseRuntimeOptions {
  const FirebaseRuntimeOptions._();

  static FirebaseOptions? get currentPlatform {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _android;
      case TargetPlatform.iOS:
        return _ios;
      case TargetPlatform.macOS:
        return _macos;
      default:
        return null;
    }
  }

  static bool get isConfigured => currentPlatform != null;

  static FirebaseOptions? get _android {
    const apiKey = String.fromEnvironment(
      'FENIX_FIREBASE_ANDROID_API_KEY',
      defaultValue: '',
    );
    const appId = String.fromEnvironment(
      'FENIX_FIREBASE_ANDROID_APP_ID',
      defaultValue: '',
    );
    const messagingSenderId = String.fromEnvironment(
      'FENIX_FIREBASE_ANDROID_MESSAGING_SENDER_ID',
      defaultValue: '',
    );
    const projectId = String.fromEnvironment(
      'FENIX_FIREBASE_ANDROID_PROJECT_ID',
      defaultValue: '',
    );
    const storageBucket = String.fromEnvironment(
      'FENIX_FIREBASE_ANDROID_STORAGE_BUCKET',
      defaultValue: '',
    );
    if (apiKey.isEmpty ||
        appId.isEmpty ||
        messagingSenderId.isEmpty ||
        projectId.isEmpty) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      storageBucket: storageBucket.isEmpty ? null : storageBucket,
    );
  }

  static FirebaseOptions? get _ios {
    const apiKey = String.fromEnvironment(
      'FENIX_FIREBASE_IOS_API_KEY',
      defaultValue: '',
    );
    const appId = String.fromEnvironment(
      'FENIX_FIREBASE_IOS_APP_ID',
      defaultValue: '',
    );
    const messagingSenderId = String.fromEnvironment(
      'FENIX_FIREBASE_IOS_MESSAGING_SENDER_ID',
      defaultValue: '',
    );
    const projectId = String.fromEnvironment(
      'FENIX_FIREBASE_IOS_PROJECT_ID',
      defaultValue: '',
    );
    const storageBucket = String.fromEnvironment(
      'FENIX_FIREBASE_IOS_STORAGE_BUCKET',
      defaultValue: '',
    );
    const iosBundleId = String.fromEnvironment(
      'FENIX_FIREBASE_IOS_BUNDLE_ID',
      defaultValue: '',
    );
    if (apiKey.isEmpty ||
        appId.isEmpty ||
        messagingSenderId.isEmpty ||
        projectId.isEmpty) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      storageBucket: storageBucket.isEmpty ? null : storageBucket,
      iosBundleId: iosBundleId.isEmpty ? null : iosBundleId,
    );
  }

  static FirebaseOptions? get _macos {
    const apiKey = String.fromEnvironment(
      'FENIX_FIREBASE_MACOS_API_KEY',
      defaultValue: '',
    );
    const appId = String.fromEnvironment(
      'FENIX_FIREBASE_MACOS_APP_ID',
      defaultValue: '',
    );
    const messagingSenderId = String.fromEnvironment(
      'FENIX_FIREBASE_MACOS_MESSAGING_SENDER_ID',
      defaultValue: '',
    );
    const projectId = String.fromEnvironment(
      'FENIX_FIREBASE_MACOS_PROJECT_ID',
      defaultValue: '',
    );
    const storageBucket = String.fromEnvironment(
      'FENIX_FIREBASE_MACOS_STORAGE_BUCKET',
      defaultValue: '',
    );
    const iosBundleId = String.fromEnvironment(
      'FENIX_FIREBASE_MACOS_BUNDLE_ID',
      defaultValue: '',
    );
    if (apiKey.isEmpty ||
        appId.isEmpty ||
        messagingSenderId.isEmpty ||
        projectId.isEmpty) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      storageBucket: storageBucket.isEmpty ? null : storageBucket,
      iosBundleId: iosBundleId.isEmpty ? null : iosBundleId,
    );
  }
}
