import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:projectantitelegram/main.dart' as app;

class _ApiStubState {
  int healthStatus = 200;
  int setupStatus = 200;
}

Response<dynamic> _jsonResponse(
  RequestOptions requestOptions,
  int statusCode,
  Map<String, dynamic> data,
) {
  return Response<dynamic>(
    requestOptions: requestOptions,
    statusCode: statusCode,
    data: data,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final apiState = _ApiStubState();
  late InterceptorsWrapper interceptor;

  setUpAll(() {
    app.debugEnsureAuthServiceForTesting();
    app.debugSetApiBaseUrlForTesting('http://integration.test');

    interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/health') {
          final code = apiState.healthStatus;
          handler.resolve(
            _jsonResponse(options, code, {
              'ok': code >= 200 && code < 300,
            }),
          );
          return;
        }
        if (options.path == '/api/setup') {
          final code = apiState.setupStatus;
          handler.resolve(
            _jsonResponse(options, code, {
              'ok': code >= 200 && code < 300,
            }),
          );
          return;
        }
        if (options.path == '/api/profile') {
          handler.resolve(
            _jsonResponse(options, 404, const {'ok': false}),
          );
          return;
        }
        handler.resolve(
          _jsonResponse(options, 200, const {'ok': true}),
        );
      },
    );
    app.dio.interceptors.add(interceptor);
  });

  tearDownAll(() {
    app.dio.interceptors.remove(interceptor);
  });

  testWidgets('ensureDatabaseExists uses /health when backend is alive', (
    tester,
  ) async {
    apiState.healthStatus = 200;
    apiState.setupStatus = 500;

    final ok = await app.ensureDatabaseExists();
    expect(ok, isTrue);
  });

  testWidgets('ensureDatabaseExists falls back to /api/setup', (tester) async {
    apiState.healthStatus = 503;
    apiState.setupStatus = 200;

    final ok = await app.ensureDatabaseExists();
    expect(ok, isTrue);
  });

  testWidgets('SetupFailedScreen retry rechecks backend', (tester) async {
    apiState.healthStatus = 503;
    apiState.setupStatus = 503;

    await tester.pumpWidget(
      const MaterialApp(home: app.SetupFailedScreen()),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Не удалось инициализировать базу данных на сервере.'),
      findsOneWidget,
    );

    apiState.healthStatus = 200;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(
      find.text('Не удалось инициализировать базу данных на сервере.'),
      findsNothing,
    );
  });
}
