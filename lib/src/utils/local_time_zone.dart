import 'local_time_zone_stub.dart'
    if (dart.library.html) 'local_time_zone_web.dart' as impl;

Future<String?> resolveLocalTimeZoneId() {
  return impl.resolveLocalTimeZoneId();
}
