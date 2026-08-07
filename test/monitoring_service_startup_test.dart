import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/main.dart' as app;
import 'package:projectphoenix/services/monitoring_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'monitoring capture is safe before auth service initialization',
    () async {
      expect(app.debugIsAuthServiceInitializedForTesting(), isFalse);

      await MonitoringService.debugCaptureEventForTests(
        subsystem: 'client',
        code: 'flutter_error',
        message: 'startup failure before auth initialization',
      );

      expect(app.debugIsAuthServiceInitializedForTesting(), isFalse);
    },
  );
}
