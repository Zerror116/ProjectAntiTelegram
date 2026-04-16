import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../src/utils/device_utils.dart';
import '../src/utils/local_time_zone.dart';
import 'native_update_installer.dart';
import 'web_notification_service.dart';
import 'web_push_client_service.dart';

class NotificationDeviceService {
  const NotificationDeviceService._();

  static Future<void>? _syncInFlight;
  static bool _syncRetryRequested = false;
  static Map<String, dynamic> _lastSyncSnapshot = const <String, dynamic>{
    'status': 'idle',
  };

  static Map<String, dynamic> get lastSyncSnapshot =>
      Map<String, dynamic>.from(_lastSyncSnapshot);

  static String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'unknown';
    }
  }

  static Future<String> _permissionState() async {
    if (kIsWeb) {
      final state = await WebNotificationService.getPermissionState();
      switch (state) {
        case WebNotificationPermissionState.granted:
          return 'granted';
        case WebNotificationPermissionState.denied:
          return 'denied';
        case WebNotificationPermissionState.defaultState:
          return 'default';
        case WebNotificationPermissionState.unsupported:
          return 'unsupported';
      }
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final allowed = await NativeUpdateInstaller.canPostNotifications();
      return allowed ? 'granted' : 'denied';
    }

    return 'unknown';
  }

  static Map<String, dynamic> _capabilities() {
    final webSupported = kIsWeb && WebPushClientService.isSupported;
    return <String, dynamic>{
      'push': webSupported,
      'in_app': true,
      'badge': kIsWeb,
      'media_rich': true,
      'conversation': defaultTargetPlatform == TargetPlatform.android,
      'standalone_web':
          kIsWeb && WebNotificationService.isStandaloneDisplayMode,
    };
  }

  static Future<void> _syncCurrentEndpointNow(Dio dio) async {
    final deviceKey = await generateDeviceFingerprint();
    final packageInfo = await PackageInfo.fromPlatform();
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    _lastSyncSnapshot = <String, dynamic>{
      'status': 'syncing',
      'platform': _platformName(),
      'transport': 'device_heartbeat',
      'device_key': deviceKey,
      'app_version': '${packageInfo.version}+${packageInfo.buildNumber}',
      'updated_at': DateTime.now().toIso8601String(),
    };
    await dio.post(
      '/api/notifications/endpoints/refresh',
      data: <String, dynamic>{
        'platform': _platformName(),
        'transport': 'device_heartbeat',
        'device_key': deviceKey,
        'permission_state': await _permissionState(),
        'capabilities': _capabilities(),
        'app_version': '${packageInfo.version}+${packageInfo.buildNumber}',
        'locale': locale,
        'timezone': await resolveLocalTimeZoneId(),
      },
    );
    _lastSyncSnapshot = <String, dynamic>{
      ..._lastSyncSnapshot,
      'status': 'ok',
      'updated_at': DateTime.now().toIso8601String(),
    };
  }

  static Future<void> syncCurrentEndpoint(Dio dio) async {
    if (_syncInFlight != null) {
      _syncRetryRequested = true;
      return _syncInFlight!;
    }
    final future = (() async {
      do {
        _syncRetryRequested = false;
        try {
          await _syncCurrentEndpointNow(dio);
        } catch (e) {
          _lastSyncSnapshot = <String, dynamic>{
            ..._lastSyncSnapshot,
            'status': 'error',
            'error': '$e',
            'updated_at': DateTime.now().toIso8601String(),
          };
          debugPrint(
            'NotificationDeviceService.syncCurrentEndpoint skipped: $e',
          );
        }
      } while (_syncRetryRequested);
    })();
    _syncInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_syncInFlight, future)) {
        _syncInFlight = null;
      }
    }
  }

  static Future<void> unregisterCurrentEndpoint(Dio dio) async {
    try {
      final deviceKey = await generateDeviceFingerprint();
      await dio.post(
        '/api/notifications/endpoints/unregister',
        data: <String, dynamic>{
          'platform': _platformName(),
          'transport': 'device_heartbeat',
          'device_key': deviceKey,
        },
      );
      _lastSyncSnapshot = <String, dynamic>{
        'status': 'unregistered',
        'platform': _platformName(),
        'transport': 'device_heartbeat',
        'device_key': deviceKey,
        'updated_at': DateTime.now().toIso8601String(),
      };
    } catch (e) {
      _lastSyncSnapshot = <String, dynamic>{
        ..._lastSyncSnapshot,
        'status': 'unregister_error',
        'error': '$e',
        'updated_at': DateTime.now().toIso8601String(),
      };
      debugPrint(
        'NotificationDeviceService.unregisterCurrentEndpoint skipped: $e',
      );
    }
  }
}
