import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:projectphoenix/services/notification_coordinator_service.dart';
import 'package:projectphoenix/services/notification_device_service.dart';
import 'package:projectphoenix/services/notification_runtime_preference_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDioAdapter implements HttpClientAdapter {
  _FakeDioAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return await handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(int statusCode, Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

Map<String, dynamic> _requestData(RequestOptions options) {
  final data = options.data;
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  return const <String, dynamic>{};
}

Future<void> _waitForCondition(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _seedPlatformState() {
  SharedPreferences.setMockInitialValues({
    'notifications_enabled-policy-user-a': true,
    'notifications_enabled-policy-user-b': true,
  });
  PackageInfo.setMockInitialValues(
    appName: 'ProjectPhoenixTest',
    packageName: 'com.example.projectphoenix.test',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );
  NotificationRuntimePreferenceService.debugResetForTests();
  NotificationDeviceService.debugResetForTests();
  NotificationCoordinatorService.debugResetForTests();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_seedPlatformState);

  test(
    'notification policy refresh is isolated per user while in flight',
    () async {
      final dio = Dio();
      final firstRequestStarted = Completer<void>();
      final releaseFirstRequest = Completer<void>();
      var preferenceCalls = 0;

      dio.httpClientAdapter = _FakeDioAdapter((options) async {
        if (options.path == '/api/notifications/preferences') {
          preferenceCalls += 1;
          final call = preferenceCalls;
          if (call == 1) {
            firstRequestStarted.complete();
            await releaseFirstRequest.future;
          }
          return _jsonResponse(200, {
            'data': {
              'message_preview_enabled': call != 1,
              'sound_enabled': true,
              'show_when_active': call == 2,
            },
          });
        }
        return _jsonResponse(200, const <String, dynamic>{});
      });

      final first = NotificationRuntimePreferenceService.refreshServerPolicy(
        dio,
        userId: 'policy-user-a',
      );
      await firstRequestStarted.future.timeout(const Duration(seconds: 2));

      final second = NotificationRuntimePreferenceService.refreshServerPolicy(
        dio,
        userId: 'policy-user-b',
      );
      await _waitForCondition(() => preferenceCalls >= 2);
      expect(preferenceCalls, 2);

      releaseFirstRequest.complete();
      final policies = await Future.wait([first, second]);
      expect(policies[0].messagePreviewEnabled, isFalse);
      expect(policies[1].messagePreviewEnabled, isTrue);
      expect(policies[1].showWhenActive, isTrue);

      final cachedSecond =
          await NotificationRuntimePreferenceService.getCachedPolicyForUser(
            'policy-user-b',
          );
      expect(cachedSecond.messagePreviewEnabled, isTrue);
      expect(cachedSecond.showWhenActive, isTrue);
    },
  );

  test(
    'device endpoint sync retries with latest pending runtime payload',
    () async {
      final dio = Dio();
      final firstRequestStarted = Completer<void>();
      final releaseFirstRequest = Completer<void>();
      final profiles = <String>[];
      final enabledValues = <bool>[];

      dio.httpClientAdapter = _FakeDioAdapter((options) async {
        if (options.path == '/api/notifications/endpoints/refresh') {
          final data = _requestData(options);
          profiles.add((data['device_profile'] ?? '').toString());
          final policy = data['app_runtime_policy'] is Map
              ? Map<String, dynamic>.from(data['app_runtime_policy'] as Map)
              : const <String, dynamic>{};
          enabledValues.add(policy['enabled'] == true);
          if (profiles.length == 1) {
            firstRequestStarted.complete();
            await releaseFirstRequest.future;
          }
        }
        return _jsonResponse(200, const <String, dynamic>{});
      });

      final first = NotificationDeviceService.syncCurrentEndpoint(
        dio,
        userId: 'endpoint-user-a',
        runtimePolicySnapshot: const {'enabled': true},
        deviceProfile: 'first-profile',
      );
      await firstRequestStarted.future.timeout(const Duration(seconds: 2));

      final second = NotificationDeviceService.syncCurrentEndpoint(
        dio,
        userId: 'endpoint-user-b',
        runtimePolicySnapshot: const {'enabled': false},
        deviceProfile: 'second-profile',
      );

      releaseFirstRequest.complete();
      await Future.wait([first, second]);
      expect(profiles, ['first-profile', 'second-profile']);
      expect(enabledValues, [true, false]);
    },
  );

  test(
    'notification coordinator applies latest pending user runtime sync',
    () async {
      final dio = Dio();
      final firstRequestStarted = Completer<void>();
      final releaseFirstRequest = Completer<void>();
      final profiles = <String>[];
      final soundValues = <bool>[];

      dio.httpClientAdapter = _FakeDioAdapter((options) async {
        if (options.path == '/api/notifications/endpoints/refresh') {
          final data = _requestData(options);
          profiles.add((data['device_profile'] ?? '').toString());
          final policy = data['app_runtime_policy'] is Map
              ? Map<String, dynamic>.from(data['app_runtime_policy'] as Map)
              : const <String, dynamic>{};
          soundValues.add(policy['sound_enabled'] == true);
          if (profiles.length == 1) {
            firstRequestStarted.complete();
            await releaseFirstRequest.future;
          }
        }
        return _jsonResponse(200, const <String, dynamic>{});
      });

      final first = NotificationCoordinatorService.reconcile(
        dio,
        enabled: true,
        userId: 'coordinator-user-a',
        runtimePolicySnapshot: const {'enabled': true, 'sound_enabled': true},
        deviceProfile: 'coordinator-first',
      );
      await firstRequestStarted.future.timeout(const Duration(seconds: 2));

      final second = NotificationCoordinatorService.reconcile(
        dio,
        enabled: true,
        userId: 'coordinator-user-b',
        runtimePolicySnapshot: const {'enabled': true, 'sound_enabled': false},
        deviceProfile: 'coordinator-second',
      );

      releaseFirstRequest.complete();
      await Future.wait([first, second]);
      expect(profiles, ['coordinator-first', 'coordinator-second']);
      expect(soundValues, [true, false]);
    },
  );
}
