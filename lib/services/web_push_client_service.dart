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
  static Future<void>? _syncUnreadBadgeInFlight;

  static Future<WebPushSyncResult> ensureSubscribed(Dio dio) {
    final inFlight = _ensureSubscribedInFlight;
    if (inFlight != null) return inFlight;
    final future = impl.ensureSubscribed(dio);
    _ensureSubscribedInFlight = future;
    future.whenComplete(() {
      if (identical(_ensureSubscribedInFlight, future)) {
        _ensureSubscribedInFlight = null;
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
    return impl.unsubscribe(dio);
  }

  static Future<int> sendServerTestPush(Dio dio) {
    return impl.sendServerTestPush(dio);
  }
}
