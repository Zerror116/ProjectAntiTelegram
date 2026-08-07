import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/main.dart' as app;

void main() {
  test('platform dispatcher errors are handled in release builds only', () {
    expect(
      app.debugShouldHandlePlatformDispatcherErrorForTesting(
        releaseMode: false,
      ),
      isFalse,
    );
    expect(
      app.debugShouldHandlePlatformDispatcherErrorForTesting(releaseMode: true),
      isTrue,
    );
  });

  testWidgets('release error fallback hides exception and stack details', (
    tester,
  ) async {
    final details = FlutterErrorDetails(
      exception: Exception('internal startup secret'),
      stack: StackTrace.fromString('internal stack trace'),
      library: 'test',
    );

    await tester.pumpWidget(
      app.debugBuildFlutterErrorFallbackForTesting(details, showDetails: false),
    );

    expect(find.text('Произошла ошибка'), findsOneWidget);
    expect(find.textContaining('Обновите страницу'), findsOneWidget);
    expect(find.textContaining('internal startup secret'), findsNothing);
    expect(find.textContaining('internal stack trace'), findsNothing);
  });

  testWidgets('debug error fallback keeps exception details for developers', (
    tester,
  ) async {
    final details = FlutterErrorDetails(
      exception: Exception('debug startup detail'),
      stack: StackTrace.fromString('debug stack trace'),
      library: 'test',
    );

    await tester.pumpWidget(
      app.debugBuildFlutterErrorFallbackForTesting(details, showDetails: true),
    );

    expect(find.textContaining('debug startup detail'), findsOneWidget);
    expect(find.textContaining('debug stack trace'), findsOneWidget);
  });
}
