import 'package:dio/dio.dart';

import 'web_push_client_service.dart';

bool isSupported() => false;

Future<WebPushSyncResult> ensureSubscribed(Dio dio) async {
  return const WebPushSyncResult(
    supported: false,
    enabledOnServer: false,
    subscribed: false,
    reason: 'unsupported',
  );
}

Future<void> syncUnreadBadge(Dio dio) async {}

Future<void> unsubscribe(Dio dio) async {}

Future<int> sendServerTestPush(Dio dio) async => 0;
