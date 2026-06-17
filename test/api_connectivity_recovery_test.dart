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
}
