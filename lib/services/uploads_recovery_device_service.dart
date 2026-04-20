import 'uploads_recovery_device_service_stub.dart'
    if (dart.library.io) 'uploads_recovery_device_service_io.dart'
    as impl;

class UploadsRecoveryDeviceService {
  const UploadsRecoveryDeviceService._();

  static bool get isSupported => impl.isSupported();

  static Future<void> maybeRun({
    required String userId,
    required String role,
    bool force = false,
  }) {
    return impl.maybeRun(userId: userId, role: role, force: force);
  }
}
