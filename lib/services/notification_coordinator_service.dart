import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'native_push_service.dart';
import 'notification_device_service.dart';
import 'web_push_client_service.dart';

class NotificationCoordinatorService {
  const NotificationCoordinatorService._();

  static Future<void>? _reconcileInFlight;
  static _NotificationReconcileRequest? _pendingRequest;

  @visibleForTesting
  static void debugResetForTests() {
    _reconcileInFlight = null;
    _pendingRequest = null;
  }

  static Future<void> reconcile(
    Dio dio, {
    required bool enabled,
    String? userId,
    Map<String, dynamic>? runtimePolicySnapshot,
    String? deviceProfile,
  }) async {
    _pendingRequest = _NotificationReconcileRequest(
      dio: dio,
      enabled: enabled,
      userId: userId,
      runtimePolicySnapshot: runtimePolicySnapshot,
      deviceProfile: deviceProfile,
    );
    final inFlight = _reconcileInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = (() async {
      while (true) {
        final current = _pendingRequest;
        if (current == null) return;
        _pendingRequest = null;
        await _applyOnce(
          current.dio,
          enabled: current.enabled,
          userId: current.userId,
          runtimePolicySnapshot: current.runtimePolicySnapshot,
          deviceProfile: current.deviceProfile,
        );
      }
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

class _NotificationReconcileRequest {
  const _NotificationReconcileRequest({
    required this.dio,
    required this.enabled,
    required this.userId,
    required this.runtimePolicySnapshot,
    required this.deviceProfile,
  });

  final Dio dio;
  final bool enabled;
  final String? userId;
  final Map<String, dynamic>? runtimePolicySnapshot;
  final String? deviceProfile;
}
