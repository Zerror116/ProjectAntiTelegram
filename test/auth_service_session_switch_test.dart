import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:projectphoenix/services/auth_service.dart';
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

bool _isNotificationEndpointLifecycleRequest(RequestOptions options) {
  return options.path == '/api/notifications/endpoints/unregister' ||
      options.path == '/api/notifications/endpoints/refresh';
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

User _user({
  required String id,
  required String email,
  required String tenantCode,
  required String tenantName,
  String? phoneAccessState,
}) {
  return User(
    id: id,
    email: email,
    name: tenantName,
    role: 'client',
    tenantCode: tenantCode,
    tenantName: tenantName,
    phoneAccessState: phoneAccessState,
  );
}

Map<String, dynamic> _userMap({
  required String id,
  required String email,
  required String tenantCode,
  required String tenantName,
}) {
  return {
    'id': id,
    'email': email,
    'name': tenantName,
    'role': 'client',
    'tenant_code': tenantCode,
    'tenant_name': tenantName,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'notifications_enabled_previous-user': false,
      'notifications_enabled_target-user': false,
      'notifications_enabled_client-user': false,
    });
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      <String, String>{},
    );
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
  });

  Future<AuthService> seedTwoSavedSessions(Dio dio) async {
    final auth = AuthService(dio: dio);
    final future = DateTime.now().toUtc().add(const Duration(hours: 1));
    final past = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final previous = _user(
      id: 'previous-user',
      email: 'previous@example.test',
      tenantCode: 'previous',
      tenantName: 'Previous',
    );
    final target = _user(
      id: 'target-user',
      email: 'target@example.test',
      tenantCode: 'target',
      tenantName: 'Target',
    );

    await auth.setSessionTokens(
      accessToken: 'previous-token',
      refreshToken: 'previous-refresh',
      accessExpiresAt: future,
      user: previous,
      keepExistingRefreshToken: false,
    );
    await auth.setSessionTokens(
      accessToken: 'target-token',
      accessExpiresAt: past,
      user: target,
      keepExistingRefreshToken: false,
    );
    await auth.setSessionTokens(
      accessToken: 'previous-token',
      refreshToken: 'previous-refresh',
      accessExpiresAt: future,
      user: previous,
      keepExistingRefreshToken: false,
    );
    return auth;
  }

  test(
    'switching saved tenant bootstraps target token, not previous refresh',
    () async {
      final bootstrapAuthHeaders = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) {
        if (options.path == '/api/auth/refresh/bootstrap') {
          bootstrapAuthHeaders.add(
            (options.headers['Authorization'] ?? '').toString(),
          );
          return _jsonResponse(200, {
            'token': 'target-token-fresh',
            'refresh_token': 'target-refresh-new',
            'access_expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
            'user': _userMap(
              id: 'target-user',
              email: 'target@example.test',
              tenantCode: 'target',
              tenantName: 'Target',
            ),
          });
        }
        if (options.path == '/api/profile') {
          return _jsonResponse(200, {
            'user': _userMap(
              id: 'target-user',
              email: 'target@example.test',
              tenantCode: 'target',
              tenantName: 'Target',
            ),
          });
        }
        return _jsonResponse(200, <String, dynamic>{});
      });
      final auth = await seedTwoSavedSessions(dio);

      final switched = await auth.switchToSavedTenantSession(
        'target@example.test::target',
      );

      expect(switched, isTrue);
      expect(bootstrapAuthHeaders, ['Bearer target-token']);
      expect(await auth.getToken(), 'target-token-fresh');
      expect(await auth.getRefreshToken(), 'target-refresh-new');
      expect(auth.currentUser?.email, 'target@example.test');
      expect(auth.currentUser?.tenantCode, 'target');
    },
  );

  test('full auth response stores refresh token and tenant session', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter((options) {
      if (_isNotificationEndpointLifecycleRequest(options)) {
        return _jsonResponse(200, {'ok': true});
      }
      if (options.path == '/api/notifications/preferences') {
        return _jsonResponse(200, {
          'data': {
            'message_preview_enabled': true,
            'sound_enabled': true,
            'show_when_active': false,
          },
        });
      }
      if (options.path == '/api/notifications/badge-count') {
        return _jsonResponse(200, {
          'data': {'count': 0},
        });
      }
      return _jsonResponse(200, <String, dynamic>{});
    });
    final auth = AuthService(dio: dio);

    final response = Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: '/api/auth/magic-link/consume'),
      statusCode: 200,
      data: {
        'token': 'magic-access-token',
        'refresh_token': 'tenant-refresh-token',
        'access_expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'user': _userMap(
          id: 'magic-user',
          email: 'magic@example.test',
          tenantCode: 'tenant-a',
          tenantName: 'Tenant A',
        ),
        'tenant': {'code': 'tenant-a', 'name': 'Tenant A'},
      },
    );

    await auth.applyAuthResponse(response);

    expect(await auth.getToken(), 'magic-access-token');
    expect(await auth.getRefreshToken(), 'tenant-refresh-token');
    expect(await auth.getTenantCode(), 'tenant-a');
    expect(auth.currentUser?.email, 'magic@example.test');
    expect(auth.currentUser?.tenantCode, 'tenant-a');

    final sessions = await auth.listSavedTenantSessions();
    final saved = sessions.singleWhere(
      (row) => (row['id'] ?? '').toString() == 'magic@example.test::tenant-a',
    );
    expect(saved['token'], 'magic-access-token');
    expect(saved['refresh_token'], 'tenant-refresh-token');
  });

  test('failed saved tenant switch restores previous session', () async {
    final previousDebugPrint = debugPrint;
    final debugMessages = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) debugMessages.add(message);
    };
    addTearDown(() {
      debugPrint = previousDebugPrint;
    });

    final bootstrapAuthHeaders = <String>[];
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter((options) {
      if (_isNotificationEndpointLifecycleRequest(options)) {
        return _jsonResponse(200, {
          'ok': true,
          'data': {'deactivated': true},
        });
      }
      if (options.path == '/api/auth/refresh/bootstrap') {
        bootstrapAuthHeaders.add(
          (options.headers['Authorization'] ?? '').toString(),
        );
        return _jsonResponse(401, {'error': 'expired'});
      }
      return _jsonResponse(500, {'error': 'unexpected'});
    });
    final auth = await seedTwoSavedSessions(dio);

    final switched = await auth.switchToSavedTenantSession(
      'target@example.test::target',
    );

    expect(switched, isFalse);
    expect(bootstrapAuthHeaders, ['Bearer target-token']);
    expect(await auth.getToken(), 'previous-token');
    expect(await auth.getRefreshToken(), 'previous-refresh');
    expect(auth.currentUser?.email, 'previous@example.test');
    expect(auth.currentUser?.tenantCode, 'previous');
    expect(
      auth.lastSavedTenantSwitchFailureReason,
      'bootstrap_session_auth_rejected',
    );
    final sessions = await auth.listSavedTenantSessions();
    expect(
      sessions.any(
        (row) => (row['id'] ?? '').toString() == 'target@example.test::target',
      ),
      isFalse,
    );
    expect(
      debugMessages.where(
        (message) =>
            message.contains('unregisterCurrentEndpoint skipped') ||
            message.contains('DioException [bad response]'),
      ),
      isEmpty,
    );
  });

  test(
    'transient saved tenant switch failure keeps target session saved',
    () async {
      final bootstrapAuthHeaders = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) {
        if (_isNotificationEndpointLifecycleRequest(options)) {
          return _jsonResponse(200, {
            'ok': true,
            'data': {'deactivated': true},
          });
        }
        if (options.path == '/api/auth/refresh/bootstrap') {
          bootstrapAuthHeaders.add(
            (options.headers['Authorization'] ?? '').toString(),
          );
          return _jsonResponse(500, {'error': 'temporary'});
        }
        return _jsonResponse(500, {'error': 'unexpected'});
      });
      final auth = await seedTwoSavedSessions(dio);

      final switched = await auth.switchToSavedTenantSession(
        'target@example.test::target',
      );

      expect(switched, isFalse);
      expect(bootstrapAuthHeaders, ['Bearer target-token']);
      expect(await auth.getToken(), 'previous-token');
      expect(await auth.getRefreshToken(), 'previous-refresh');
      expect(auth.currentUser?.email, 'previous@example.test');
      expect(auth.currentUser?.tenantCode, 'previous');
      expect(
        auth.lastSavedTenantSwitchFailureReason,
        'bootstrap_session_transient_error',
      );
      final sessions = await auth.listSavedTenantSessions();
      expect(
        sessions.any(
          (row) =>
              (row['id'] ?? '').toString() == 'target@example.test::target',
        ),
        isTrue,
      );
    },
  );

  test('restricted saved tenant switch keeps target session saved', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter((options) {
      if (_isNotificationEndpointLifecycleRequest(options)) {
        return _jsonResponse(200, {
          'ok': true,
          'data': {'deactivated': true},
        });
      }
      if (options.path == '/api/auth/refresh/bootstrap') {
        return _jsonResponse(200, {
          'token': 'target-token-fresh',
          'refresh_token': 'target-refresh-new',
          'access_expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .toIso8601String(),
          'user': _userMap(
            id: 'target-user',
            email: 'target@example.test',
            tenantCode: 'target',
            tenantName: 'Target',
          ),
        });
      }
      if (options.path == '/api/profile') {
        return _jsonResponse(403, {
          'error': 'Доступ ограничен',
          'code': 'phone_access_pending',
        });
      }
      return _jsonResponse(500, {'error': 'unexpected'});
    });
    final auth = await seedTwoSavedSessions(dio);

    final switched = await auth.switchToSavedTenantSession(
      'target@example.test::target',
    );

    expect(switched, isFalse);
    expect(await auth.getToken(), 'previous-token');
    expect(await auth.getRefreshToken(), 'previous-refresh');
    expect(auth.currentUser?.email, 'previous@example.test');
    expect(auth.currentUser?.tenantCode, 'previous');
    expect(
      auth.lastSavedTenantSwitchFailureReason,
      'saved_tenant_switch_restricted',
    );
    final sessions = await auth.listSavedTenantSessions();
    expect(
      sessions.any(
        (row) => (row['id'] ?? '').toString() == 'target@example.test::target',
      ),
      isTrue,
    );
  });

  test(
    'fresh profile without phone access state clears stale local pending',
    () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) {
        if (_isNotificationEndpointLifecycleRequest(options)) {
          return _jsonResponse(200, {'ok': true});
        }
        return _jsonResponse(200, <String, dynamic>{});
      });
      final auth = AuthService(dio: dio);
      await auth.setSessionTokens(
        accessToken: 'client-token',
        accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        user: _user(
          id: 'client-user',
          email: 'client@example.test',
          tenantCode: 'tenant',
          tenantName: 'Tenant',
          phoneAccessState: 'pending',
        ),
        keepExistingRefreshToken: false,
      );

      auth.updateCurrentUserFromMap(
        _userMap(
          id: 'client-user',
          email: 'client@example.test',
          tenantCode: 'tenant',
          tenantName: 'Tenant',
        ),
      );

      expect(auth.currentUser?.phoneAccessState, 'none');
    },
  );

  test(
    'partial profile keeps local fields only for same tenant user',
    () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) {
        if (_isNotificationEndpointLifecycleRequest(options)) {
          return _jsonResponse(200, {'ok': true});
        }
        return _jsonResponse(200, <String, dynamic>{});
      });
      final auth = AuthService(dio: dio);

      await auth.setSessionTokens(
        accessToken: 'client-token',
        accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        user: User(
          id: 'client-user',
          email: 'client@example.test',
          name: 'Client Name',
          role: 'client',
          phone: '79990001122',
          tenantId: '11111111-1111-4111-8111-111111111111',
          tenantCode: 'tenant',
          tenantName: 'Tenant',
          permissions: {'cart.view': true},
          featureSettings: {'client_group_switcher_enabled': true},
        ),
        keepExistingRefreshToken: false,
      );

      auth.updateCurrentUserFromMap({
        'id': 'client-user',
        'email': 'client@example.test',
        'role': 'client',
        'tenant_id': '11111111-1111-4111-8111-111111111111',
        'tenant_code': 'tenant',
        'tenant_name': 'Tenant',
      });

      expect(auth.currentUser?.name, 'Client Name');
      expect(auth.currentUser?.phone, '79990001122');
      expect(auth.currentUser?.permissions, {'cart.view': true});
      expect(auth.currentUser?.featureSettings, {
        'client_group_switcher_enabled': true,
      });
      expect(auth.currentUser?.phoneAccessState, 'none');
    },
  );

  test(
    'partial profile from another tenant user does not inherit stale fields',
    () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) {
        if (_isNotificationEndpointLifecycleRequest(options)) {
          return _jsonResponse(200, {'ok': true});
        }
        return _jsonResponse(200, <String, dynamic>{});
      });
      final auth = AuthService(dio: dio);

      await auth.setSessionTokens(
        accessToken: 'previous-token',
        accessExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        user: User(
          id: 'previous-user',
          email: 'previous@example.test',
          name: 'Previous Name',
          role: 'client',
          phone: '79990001122',
          tenantId: '11111111-1111-4111-8111-111111111111',
          tenantCode: 'previous',
          tenantName: 'Previous',
          permissions: {'all': true},
          featureSettings: {
            'phone_access_approval_enabled': true,
            'client': {'phone_access_approval_enabled': true},
          },
        ),
        keepExistingRefreshToken: false,
      );

      auth.updateCurrentUserFromMap({
        'id': 'target-user',
        'email': 'target@example.test',
        'role': 'client',
        'tenant_id': '22222222-2222-4222-8222-222222222222',
        'tenant_code': 'target',
        'tenant_name': 'Target',
      });

      expect(auth.currentUser?.name, isNull);
      expect(auth.currentUser?.phone, isNull);
      expect(auth.currentUser?.permissions, isEmpty);
      expect(auth.currentUser?.featureSettings, isEmpty);
      expect(auth.currentUser?.phoneAccessState, 'none');
    },
  );

  test(
    'post auth notification sync reruns for latest user while first sync is in flight',
    () async {
      SharedPreferences.setMockInitialValues({
        'notifications_enabled-sync-user-a': true,
        'notifications_enabled-sync-user-b': true,
      });
      NotificationRuntimePreferenceService.debugResetForTests();
      NotificationDeviceService.debugResetForTests();
      NotificationCoordinatorService.debugResetForTests();

      final firstPreferencesStarted = Completer<void>();
      final releaseFirstPreferences = Completer<void>();
      final preferenceAuthHeaders = <String>[];
      final endpointAuthHeaders = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) async {
        if (options.path == '/api/notifications/preferences') {
          preferenceAuthHeaders.add(
            (options.headers['Authorization'] ?? '').toString(),
          );
          if (preferenceAuthHeaders.length == 1) {
            firstPreferencesStarted.complete();
            await releaseFirstPreferences.future;
          }
          return _jsonResponse(200, {
            'data': {
              'message_preview_enabled': true,
              'sound_enabled': true,
              'show_when_active': false,
            },
          });
        }
        if (options.path == '/api/notifications/endpoints/refresh') {
          endpointAuthHeaders.add(
            (options.headers['Authorization'] ?? '').toString(),
          );
          return _jsonResponse(200, {'ok': true});
        }
        if (options.path == '/api/notifications/badge-count') {
          return _jsonResponse(200, {
            'data': {'count': 0},
          });
        }
        return _jsonResponse(200, <String, dynamic>{});
      });
      final auth = AuthService(dio: dio);

      await auth.setSessionTokens(
        accessToken: 'sync-token-a',
        user: _user(
          id: 'sync-user-a',
          email: 'sync-a@example.test',
          tenantCode: 'sync-a',
          tenantName: 'Sync A',
        ),
        keepExistingRefreshToken: false,
      );
      await firstPreferencesStarted.future.timeout(const Duration(seconds: 2));

      await auth.setSessionTokens(
        accessToken: 'sync-token-b',
        user: _user(
          id: 'sync-user-b',
          email: 'sync-b@example.test',
          tenantCode: 'sync-b',
          tenantName: 'Sync B',
        ),
        keepExistingRefreshToken: false,
      );

      releaseFirstPreferences.complete();
      await _waitForCondition(() => preferenceAuthHeaders.length >= 2);
      await _waitForCondition(() => endpointAuthHeaders.isNotEmpty);

      expect(preferenceAuthHeaders.first, 'Bearer sync-token-a');
      expect(preferenceAuthHeaders, contains('Bearer sync-token-b'));
      expect(auth.currentUser?.id, 'sync-user-b');
    },
  );
}
