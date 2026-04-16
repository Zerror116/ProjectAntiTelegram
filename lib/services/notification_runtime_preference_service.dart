import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_push_service.dart';
import 'notification_device_service.dart';
import 'web_push_client_service.dart';

const _notificationsPrefPrefix = 'notifications_enabled_';

class NotificationRuntimePreferenceService {
  const NotificationRuntimePreferenceService._();

  static String settingsScopeUserId(String? userId) {
    final normalized = (userId ?? '').trim();
    return normalized.isEmpty ? 'guest' : normalized;
  }

  static Future<bool> isEnabledForUser(String? userId) async {
    final prefs = await SharedPreferences.getInstance();
    final scope = settingsScopeUserId(userId);
    return prefs.getBool('$_notificationsPrefPrefix$scope') ?? true;
  }

  static Future<void> persistEnabledForUser(String? userId, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final scope = settingsScopeUserId(userId);
    await prefs.setBool('$_notificationsPrefPrefix$scope', value);
  }

  static Future<void> applyRuntimePreference(
    Dio dio, {
    required bool enabled,
  }) async {
    if (enabled) {
      if (kIsWeb) {
        try {
          await WebPushClientService.ensureSubscribed(dio);
        } catch (_) {}
      }
      try {
        await NotificationDeviceService.syncCurrentEndpoint(dio);
      } catch (_) {}
      try {
        await NativePushService.syncCurrentEndpoint(dio);
      } catch (_) {}
      return;
    }

    try {
      await NotificationDeviceService.unregisterCurrentEndpoint(dio);
    } catch (_) {}
    try {
      await NativePushService.unregisterCurrentEndpoint(dio);
    } catch (_) {}
    if (kIsWeb) {
      try {
        await WebPushClientService.unsubscribe(dio);
      } catch (_) {}
      try {
        await WebPushClientService.syncUnreadBadgeCount(0);
      } catch (_) {}
    }
  }
}
