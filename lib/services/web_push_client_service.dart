import 'dart:convert';

import 'package:dio/dio.dart';

import 'web_push_client_service_stub.dart'
    if (dart.library.html) 'web_push_client_service_web.dart'
    as impl;

class WebPushSyncResult {
  final bool supported;
  final bool enabledOnServer;
  final bool subscribed;
  final String? reason;

  const WebPushSyncResult({
    required this.supported,
    required this.enabledOnServer,
    required this.subscribed,
    required this.reason,
  });
}

class WebPushClientService {
  const WebPushClientService._();

  static bool get isSupported => impl.isSupported();

  static Future<WebPushSyncResult>? _ensureSubscribedInFlight;
  static String? _ensureSubscribedInFlightKey;
  static Future<void>? _syncUnreadBadgeInFlight;

  static String _runtimePolicySnapshotKey(
    Map<String, dynamic>? runtimePolicySnapshot,
  ) {
    if (runtimePolicySnapshot == null) return '';
    final sortedEntries = runtimePolicySnapshot.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return jsonEncode(Map<String, dynamic>.fromEntries(sortedEntries));
  }

  static Future<WebPushSyncResult> ensureSubscribed(
    Dio dio, {
    Map<String, dynamic>? runtimePolicySnapshot,
  }) async {
    final key = _runtimePolicySnapshotKey(runtimePolicySnapshot);
    while (true) {
      final inFlight = _ensureSubscribedInFlight;
      if (inFlight == null) break;
      if (_ensureSubscribedInFlightKey == key) {
        return inFlight;
      }
      try {
        await inFlight;
      } catch (_) {
        // The next call below will retry with the latest runtime policy.
      }
    }
    final future = impl.ensureSubscribed(
      dio,
      runtimePolicySnapshot: runtimePolicySnapshot,
    );
    _ensureSubscribedInFlight = future;
    _ensureSubscribedInFlightKey = key;
    future.whenComplete(() {
      if (identical(_ensureSubscribedInFlight, future)) {
        _ensureSubscribedInFlight = null;
        _ensureSubscribedInFlightKey = null;
      }
    });
    return future;
  }

  static Future<void> syncUnreadBadge(Dio dio) {
    final inFlight = _syncUnreadBadgeInFlight;
    if (inFlight != null) return inFlight;
    final future = impl.syncUnreadBadge(dio);
    _syncUnreadBadgeInFlight = future;
    future.whenComplete(() {
      if (identical(_syncUnreadBadgeInFlight, future)) {
        _syncUnreadBadgeInFlight = null;
      }
    });
    return future;
  }

  static Future<void> syncUnreadBadgeCount(int count) {
    return impl.syncUnreadBadgeCount(count);
  }

  static Future<void> unsubscribe(Dio dio) {
    final inFlight = _ensureSubscribedInFlight;
    if (inFlight != null) {
      return inFlight
          .catchError(
            (_) => const WebPushSyncResult(
              supported: false,
              enabledOnServer: false,
              subscribed: false,
              reason: 'ignored',
            ),
          )
          .then((_) => impl.unsubscribe(dio));
    }
    return impl.unsubscribe(dio);
  }

  static Future<int> sendServerTestPush(Dio dio) {
    return impl.sendServerTestPush(dio);
  }
}
