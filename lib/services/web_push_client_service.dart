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

  static Future<WebPushSyncResult> ensureSubscribed(Dio dio) {
    return impl.ensureSubscribed(dio);
  }

  static Future<void> syncUnreadBadge(Dio dio) {
    return impl.syncUnreadBadge(dio);
  }

  static Future<void> unsubscribe(Dio dio) {
    return impl.unsubscribe(dio);
  }

  static Future<int> sendServerTestPush(Dio dio) {
    return impl.sendServerTestPush(dio);
  }
}
