import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/services/auth_service.dart';
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

User _user({
  required String id,
  required String email,
  required String tenantCode,
  required String tenantName,
}) {
  return User(
    id: id,
    email: email,
    name: tenantName,
    role: 'client',
    tenantCode: tenantCode,
    tenantName: tenantName,
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
    });
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      <String, String>{},
    );
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

  test('failed saved tenant switch restores previous session', () async {
    final bootstrapAuthHeaders = <String>[];
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter((options) {
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
    final sessions = await auth.listSavedTenantSessions();
    expect(
      sessions.any(
        (row) => (row['id'] ?? '').toString() == 'target@example.test::target',
      ),
      isFalse,
    );
  });
}
