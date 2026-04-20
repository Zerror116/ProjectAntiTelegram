import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../main.dart';
import '../src/utils/device_utils.dart';

class MonitoringService {
  MonitoringService._();

  static const int _maxRecentFingerprints = 48;
  static final List<String> _recentFingerprints = <String>[];
  static final Map<String, DateTime> _recentFingerprintTimestamps =
      <String, DateTime>{};
  static DateTime? _mutedUntil;

  static String _fingerprintFor({
    required String subsystem,
    required String code,
    required String message,
  }) {
    return '${subsystem.trim().toLowerCase()}|${code.trim().toLowerCase()}|${message.trim()}';
  }

  static bool _shouldSkipDuplicate(String fingerprint) {
    final now = DateTime.now();
    final last = _recentFingerprintTimestamps[fingerprint];
    if (last != null && now.difference(last).inSeconds < 20) {
      return true;
    }
    _recentFingerprintTimestamps[fingerprint] = now;
    _recentFingerprints.remove(fingerprint);
    _recentFingerprints.add(fingerprint);
    if (_recentFingerprints.length > _maxRecentFingerprints) {
      final oldest = _recentFingerprints.removeAt(0);
      _recentFingerprintTimestamps.remove(oldest);
    }
    return false;
  }

  static bool _isMuted() {
    final mutedUntil = _mutedUntil;
    if (mutedUntil == null) return false;
    if (DateTime.now().isAfter(mutedUntil)) {
      _mutedUntil = null;
      return false;
    }
    return true;
  }

  static bool _shouldIgnoreKnownNoise({
    required String subsystem,
    required String code,
    required String message,
  }) {
    final normalizedSubsystem = subsystem.trim().toLowerCase();
    final normalizedCode = code.trim().toLowerCase();
    final normalizedMessage = message.trim().toLowerCase();
    final isClientRuntime = normalizedSubsystem == 'client' &&
        (normalizedCode == 'flutter_error' ||
            normalizedCode == 'platform_dispatcher_error');

    if (!isClientRuntime) return false;

    if (normalizedMessage.contains('statuscode: 404') &&
        normalizedMessage.contains('/uploads/')) {
      return true;
    }
    if (normalizedMessage.contains('flutter.js.map') &&
        normalizedMessage.contains('statuscode: 404')) {
      return true;
    }
    if (normalizedMessage.contains('statuscode: 429') &&
        normalizedMessage.contains('/api/admin/ops/monitoring/events')) {
      return true;
    }
    return false;
  }

  static Future<void> captureEvent({
    required String subsystem,
    required String code,
    required String message,
    String level = 'warn',
    String scope = 'client',
    String? source,
    Map<String, dynamic> details = const <String, dynamic>{},
  }) async {
    final user = authService.currentUser;
    if (user == null) return;
    if (_isMuted()) return;
    if (_shouldIgnoreKnownNoise(
      subsystem: subsystem,
      code: code,
      message: message,
    )) {
      return;
    }
    final fingerprint = _fingerprintFor(
      subsystem: subsystem,
      code: code,
      message: message,
    );
    if (_shouldSkipDuplicate(fingerprint)) return;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceKey = await generateDeviceFingerprint();
      await authService.dio.post(
        '/api/admin/ops/monitoring/events',
        data: <String, dynamic>{
          'scope': scope,
          'subsystem': subsystem,
          'level': level,
          'code': code,
          'message': message,
          'source': source,
          'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
          'app_version': packageInfo.version,
          'app_build': int.tryParse(packageInfo.buildNumber),
          'device_label': deviceKey,
          'release_channel': 'stable',
          'session_state': authService.isSessionDegraded
              ? 'degraded'
              : 'normal',
          'details': details,
        },
      );
    } catch (err) {
      if (err is DioException && err.response?.statusCode == 429) {
        _mutedUntil = DateTime.now().add(const Duration(minutes: 2));
      }
      // Monitoring must never interrupt product flows.
    }
  }

  static Future<void> captureError(
    Object error,
    StackTrace? stackTrace, {
    required String subsystem,
    required String code,
    String level = 'error',
    String? source,
    Map<String, dynamic> details = const <String, dynamic>{},
  }) async {
    await captureEvent(
      subsystem: subsystem,
      code: code,
      level: level,
      source: source,
      message: error.toString(),
      details: <String, dynamic>{
        ...details,
        if (stackTrace != null) 'stack': stackTrace.toString(),
      },
    );
  }
}
