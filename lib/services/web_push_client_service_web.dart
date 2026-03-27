// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter, avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;

import 'package:dio/dio.dart';

import 'web_notification_service.dart';
import 'web_push_client_service.dart';

const _rootWorkerUrl = '/flutter_service_worker.js';

bool isSupported() {
  return html.window.navigator.serviceWorker != null &&
      WebNotificationService.isSupported;
}

Future<dynamic> _jsPromiseToFuture(dynamic promise) {
  final completer = Completer<dynamic>();
  if (promise == null) {
    completer.complete(null);
    return completer.future;
  }

  final jsPromise = promise is js.JsObject
      ? promise
      : js.JsObject.fromBrowserObject(promise);
  final onFulfilled = js.JsFunction.withThis((_, dynamic value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  });
  final onRejected = js.JsFunction.withThis((_, dynamic error) {
    if (!completer.isCompleted) {
      completer.completeError(error ?? 'js_promise_rejected');
    }
  });
  jsPromise.callMethod('then', [onFulfilled, onRejected]);
  return completer.future;
}

js.JsObject _asJsObject(dynamic value) {
  return value is js.JsObject ? value : js.JsObject.fromBrowserObject(value);
}

String? _normalizeSubscriptionJson(String? rawJson) {
  final normalized = rawJson?.trim() ?? '';
  if (normalized.isEmpty || normalized == 'null') {
    return null;
  }
  return normalized;
}

Map<String, dynamic>? _deserializeSubscriptionJson(String? rawJson) {
  final normalized = _normalizeSubscriptionJson(rawJson);
  if (normalized == null) {
    return null;
  }
  final decoded = jsonDecode(normalized);
  if (decoded is! Map) return null;
  final map = Map<String, dynamic>.from(decoded);
  final endpoint = (map['endpoint'] ?? '').toString().trim();
  if (endpoint.isEmpty) return null;
  final keys = map['keys'] is Map
      ? Map<String, dynamic>.from(map['keys'] as Map)
      : const <String, dynamic>{};
  final p256dh = (keys['p256dh'] ?? '').toString().trim();
  final auth = (keys['auth'] ?? '').toString().trim();
  if (p256dh.isEmpty || auth.isEmpty) return null;
  return {
    'endpoint': endpoint,
    'expirationTime': map['expirationTime'],
    'keys': {'p256dh': p256dh, 'auth': auth},
  };
}

Future<dynamic> _callPushHelper(String method, [List<dynamic> args = const []]) async {
  final helper = js.context['projectPhoenixPush'];
  if (helper == null) {
    print('[web-push] helper missing: method=$method');
    return null;
  }
  try {
    return await _jsPromiseToFuture(_asJsObject(helper).callMethod(method, args));
  } catch (e) {
    print('[web-push] helper call failed: method=$method error=$e');
    return null;
  }
}

Future<html.ServiceWorkerRegistration?> _getRegistration() async {
  final sw = html.window.navigator.serviceWorker;
  if (sw == null) {
    print('[web-push] _getRegistration: serviceWorker unsupported');
    return null;
  }

  try {
    final dynamic existing = await sw.getRegistration();
    if (existing != null) {
      final registration = existing as html.ServiceWorkerRegistration;
      print(
        '[web-push] _getRegistration: existing scope=${registration.scope}',
      );
      return _waitForRegistrationActivation(registration);
    }
    print('[web-push] _getRegistration: existing=false');
  } catch (e) {
    print('[web-push] _getRegistration: getRegistration error=$e');
  }

  try {
    final registration = await sw.register(_rootWorkerUrl);
    print(
      '[web-push] _getRegistration: registered scope=${registration.scope}',
    );
    return _waitForRegistrationActivation(registration);
  } catch (e) {
    print('[web-push] _getRegistration: register error=$e');
    return null;
  }
}

Future<html.ServiceWorkerRegistration> _waitForRegistrationActivation(
  html.ServiceWorkerRegistration registration,
) async {
  for (var attempt = 0; attempt < 25; attempt++) {
    final active = registration.active;
    if (active != null && active.state == 'activated') {
      print(
        '[web-push] _waitForRegistrationActivation: active on attempt=$attempt',
      );
      return registration;
    }

    final worker = registration.installing ?? registration.waiting ?? active;
    final state = worker?.state ?? 'none';
    print(
      '[web-push] _waitForRegistrationActivation: attempt=$attempt state=$state',
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  print('[web-push] _waitForRegistrationActivation: timeout');
  return registration;
}

Future<Map<String, dynamic>?> _getPushSubscriptionPayload() async {
  final rawJson = await _callPushHelper('getSubscriptionJson');
  return _deserializeSubscriptionJson(rawJson?.toString());
}

Future<Map<String, dynamic>?> _subscribeToPushPayload(String publicKey) async {
  final rawJson = await _callPushHelper('subscribeJson', [publicKey]);
  return _deserializeSubscriptionJson(rawJson?.toString());
}

Future<void> _syncWindowBadge(int unreadCount) async {
  final navigator = js.context['navigator'];
  final normalized = unreadCount < 0 ? 0 : unreadCount;
  try {
    if (navigator is js.JsObject && navigator.hasProperty('setAppBadge')) {
      if (normalized > 0) {
        await _jsPromiseToFuture(navigator.callMethod('setAppBadge', [normalized]));
      } else if (navigator.hasProperty('clearAppBadge')) {
        await _jsPromiseToFuture(navigator.callMethod('clearAppBadge'));
      } else {
        await _jsPromiseToFuture(navigator.callMethod('setAppBadge', [0]));
      }
    }
  } catch (e) {
    print('[web-push] _syncWindowBadge failed: $e');
  }
}

Future<void> _postBadgeSyncToWorker(int unreadCount) async {
  await _syncWindowBadge(unreadCount);
  final registration = await _getRegistration();
  final worker =
      registration?.active ?? registration?.waiting ?? registration?.installing;
  worker?.postMessage({'type': 'badge-sync', 'count': unreadCount});
}

Future<WebPushSyncResult> ensureSubscribed(Dio dio) async {
  print('[web-push] ensureSubscribed: start');
  if (!isSupported()) {
    print('[web-push] ensureSubscribed: unsupported');
    return const WebPushSyncResult(
      supported: false,
      enabledOnServer: false,
      subscribed: false,
      reason: 'unsupported',
    );
  }

  final permission = await WebNotificationService.getPermissionState();
  print('[web-push] ensureSubscribed: permission=$permission');
  if (permission != WebNotificationPermissionState.granted) {
    return const WebPushSyncResult(
      supported: true,
      enabledOnServer: false,
      subscribed: false,
      reason: 'permission_not_granted',
    );
  }

  late final Response<dynamic> configResp;
  try {
    configResp = await dio.get('/api/web-push/config');
  } catch (e) {
    print('[web-push] ensureSubscribed: config_request_failed error=$e');
    return const WebPushSyncResult(
      supported: true,
      enabledOnServer: false,
      subscribed: false,
      reason: 'config_request_failed',
    );
  }

  final root = configResp.data;
  final enabled = root is Map && root['enabled'] == true;
  final publicKey = root is Map
      ? (root['public_key'] ?? '').toString().trim()
      : '';
  if (!enabled || publicKey.isEmpty) {
    print(
      '[web-push] ensureSubscribed: server_not_configured enabled=$enabled keyEmpty=${publicKey.isEmpty}',
    );
    return const WebPushSyncResult(
      supported: true,
      enabledOnServer: false,
      subscribed: false,
      reason: 'server_not_configured',
    );
  }

  final registration = await _getRegistration();
  print(
    '[web-push] ensureSubscribed: registration=${registration != null} pushManager=${registration?.pushManager != null}',
  );
  if (registration == null || registration.pushManager == null) {
    return const WebPushSyncResult(
      supported: true,
      enabledOnServer: true,
      subscribed: false,
      reason: 'push_manager_unavailable',
    );
  }

  var payload = await _getPushSubscriptionPayload();
  if (payload == null) {
    print('[web-push] ensureSubscribed: subscribing');
    payload = await _subscribeToPushPayload(publicKey);
  }
  if (payload == null) {
    print('[web-push] ensureSubscribed: subscribe_failed');
    return const WebPushSyncResult(
      supported: true,
      enabledOnServer: true,
      subscribed: false,
      reason: 'subscribe_failed',
    );
  }

  print('[web-push] ensureSubscribed: serialized=true');
  try {
    await dio.post(
      '/api/web-push/subscriptions',
      data: {'subscription': payload},
    );
  } catch (e) {
    print('[web-push] ensureSubscribed: sync_failed error=$e');
    return const WebPushSyncResult(
      supported: true,
      enabledOnServer: true,
      subscribed: false,
      reason: 'sync_failed',
    );
  }

  await syncUnreadBadge(dio);
  print('[web-push] ensureSubscribed: success');

  return const WebPushSyncResult(
    supported: true,
    enabledOnServer: true,
    subscribed: true,
    reason: null,
  );
}

Future<void> syncUnreadBadge(Dio dio) async {
  if (!isSupported()) return;
  try {
    final resp = await dio.get('/api/web-push/badge-count');
    final root = resp.data;
    final count = root is Map
        ? (root['unread_count'] as num?)?.toInt() ?? 0
        : 0;
    await _postBadgeSyncToWorker(count);
    print('[web-push] syncUnreadBadge: count=$count');
  } catch (e) {
    print('[web-push] syncUnreadBadge: failed error=$e');
  }
}

Future<void> unsubscribe(Dio dio) async {
  if (!isSupported()) return;
  try {
    final payload = await _getPushSubscriptionPayload();
    if (payload == null) {
      await _postBadgeSyncToWorker(0);
      return;
    }
    final endpoint = (payload['endpoint'] ?? '').toString().trim();
    if (endpoint.isNotEmpty) {
      try {
        await dio.delete(
          '/api/web-push/subscriptions',
          data: {'endpoint': endpoint},
        );
      } catch (_) {
        // ignore
      }
    }
    await _callPushHelper('unsubscribeCurrent');
    await _postBadgeSyncToWorker(0);
  } catch (e) {
    print('[web-push] unsubscribe failed error=$e');
  }
}

Future<int> sendServerTestPush(Dio dio) async {
  if (!isSupported()) return 0;
  try {
    final resp = await dio.post('/api/web-push/test');
    final root = resp.data;
    if (root is Map) {
      return (root['sent'] as num?)?.toInt() ?? 0;
    }
  } catch (e) {
    print('[web-push] sendServerTestPush failed error=$e');
  }
  return 0;
}
