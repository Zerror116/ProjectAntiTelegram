import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/services/web_service_worker_version.dart';

void main() {
  test('service worker URL is versioned by web build token', () {
    expect(
      buildVersionedPhoenixServiceWorkerUrl(''),
      phoenixRootServiceWorkerUrl,
    );
    expect(
      buildVersionedPhoenixServiceWorkerUrl('1.0.69|70|token with spaces'),
      '/flutter_service_worker.js?v=1.0.69%7C70%7Ctoken%20with%20spaces',
    );
  });
}
