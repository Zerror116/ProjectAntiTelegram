import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'native_push_service.dart';
import 'notification_device_service.dart';
import 'web_push_client_service.dart';

class NotificationCoordinatorService {
  const NotificationCoordinatorService._();

  static Future<void>? _reconcileInFlight;
  static bool _nextEnabledState = true;

  static Future<void> reconcile(
    Dio dio, {
    required bool enabled,
    String? userId,
    Map<String, dynamic>? runtimePolicySnapshot,
    String? deviceProfile,
  }) async {
    _nextEnabledState = enabled;
    final inFlight = _reconcileInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = (() async {
      bool currentEnabled;
      do {
        currentEnabled = _nextEnabledState;
        await _applyOnce(
          dio,
          enabled: currentEnabled,
          userId: userId,
          runtimePolicySnapshot: runtimePolicySnapshot,
          deviceProfile: deviceProfile,
        );
      } while (_nextEnabledState != currentEnabled);
    })();

    _reconcileInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_reconcileInFlight, future)) {
        _reconcileInFlight = null;
      }
    }
  }

  static Future<void> clear(
    Dio dio, {
    String? userId,
    Map<String, dynamic>? runtimePolicySnapshot,
    String? deviceProfile,
  }) async {
    await reconcile(
      dio,
      enabled: false,
      userId: userId,
      runtimePolicySnapshot: runtimePolicySnapshot,
      deviceProfile: deviceProfile,
    );
  }

  static Future<void> _applyOnce(
    Dio dio, {
    required bool enabled,
    String? userId,
    Map<String, dynamic>? runtimePolicySnapshot,
    String? deviceProfile,
  }) async {
    NativePushService.setEndpointSyncEnabled(enabled);
    if (enabled) {
      if (kIsWeb) {
        try {
          await WebPushClientService.ensureSubscribed(dio);
        } catch (_) {}
      }
      try {
        await NotificationDeviceService.syncCurrentEndpoint(
          dio,
          userId: userId,
          runtimePolicySnapshot: runtimePolicySnapshot,
          deviceProfile: deviceProfile,
        );
      } catch (_) {}
      try {
        await NativePushService.syncCurrentEndpoint(
          dio,
          userId: userId,
          runtimePolicySnapshot: runtimePolicySnapshot,
          deviceProfile: deviceProfile,
        );
      } catch (_) {}
      return;
    }

    try {
      await NotificationDeviceService.unregisterCurrentEndpoint(
        dio,
        userId: userId,
      );
    } catch (_) {}
    try {
      await NativePushService.unregisterCurrentEndpoint(dio, userId: userId);
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
