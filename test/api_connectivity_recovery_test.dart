import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/main.dart' as app;

DioException _connectionError(String message) {
  return DioException(
    requestOptions: RequestOptions(
      path: '/api/worker/channels',
      baseUrl: 'https://garphoenix.com',
    ),
    type: DioExceptionType.connectionError,
    message: message,
  );
}

void main() {
  group('API connectivity recovery', () {
    test('treats connection refused as recoverable connectivity failure', () {
      final error = _connectionError(
        'The connection errored: Connection refused. '
        'This indicates an error which most likely cannot be solved by the library.',
      );

      expect(
        app.debugIsRecoverableApiConnectivityFailureForTesting(error),
        isTrue,
      );
    });

    test('falls back between production API hosts', () {
      expect(
        app.debugFallbackApiBaseForConnectivityFailureForTesting(
          'https://garphoenix.com',
        ),
        'https://www.garphoenix.com',
      );
      expect(
        app.debugFallbackApiBaseForConnectivityFailureForTesting(
          'https://www.garphoenix.com',
        ),
        'https://garphoenix.com',
      );
    });
  });

  group('phone access routing', () {
    test('does not trust stale pending state when feature flag is missing', () {
      expect(
        app.debugShouldShowPhoneAccessPendingForTesting({
          'id': 'client-1',
          'email': 'client@example.test',
          'role': 'client',
          'phone_access_state': 'pending',
        }),
        isFalse,
      );
    });

    test('uses pending route when phone access approval is enabled', () {
      expect(
        app.debugShouldShowPhoneAccessPendingForTesting({
          'id': 'client-1',
          'email': 'client@example.test',
          'role': 'client',
          'phone_access_state': 'pending',
          'feature_settings': {
            'phone_access_approval_enabled': true,
            'client': {'phone_access_approval_enabled': true},
          },
        }),
        isTrue,
      );
    });

    test('recognizes server phone access restriction response', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/api/cart'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/cart'),
          statusCode: 423,
          data: {
            'code': 'phone_access_pending',
            'phone_access': {'state': 'pending'},
          },
        ),
        type: DioExceptionType.badResponse,
      );

      expect(app.debugIsPhoneAccessRestrictionErrorForTesting(error), isTrue);
    });
  });
}
