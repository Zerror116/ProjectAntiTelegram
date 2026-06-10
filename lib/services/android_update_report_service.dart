import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'native_update_installer.dart';

class AndroidUpdateReportService {
  AndroidUpdateReportService._();

  static final Set<String> _sentKeys = <String>{};

  static bool get _isAndroid {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  static Future<void> report(
    Dio dio, {
    required String eventType,
    String? status,
    String? stage,
    String? errorCode,
    String? errorMessage,
    String? packageName,
    String? updateVersion,
    int? updateBuild,
    bool? requiredUpdate,
    String? manifestUrl,
    String? downloadUrl,
    Map<String, dynamic>? payload,
    bool dedupe = true,
  }) async {
    if (!_isAndroid) return;

    final dedupeKey = [
      eventType,
      status ?? '',
      errorCode ?? '',
      updateVersion ?? '',
      updateBuild ?? '',
    ].join('|');
    if (dedupe && _sentKeys.contains(dedupeKey)) return;
    if (dedupe) {
      _sentKeys.add(dedupeKey);
      if (_sentKeys.length > 80) {
        _sentKeys.remove(_sentKeys.first);
      }
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      bool? installPermission;
      bool? notificationPermission;
      try {
        installPermission =
            await NativeUpdateInstaller.canRequestPackageInstalls();
      } catch (_) {
        installPermission = null;
      }
      try {
        notificationPermission =
            await NativeUpdateInstaller.canPostNotifications();
      } catch (_) {
        notificationPermission = null;
      }

      await dio.post(
        '/api/app/update/android/report',
        data: <String, dynamic>{
          'event_type': eventType,
          'status': status,
          'stage': stage,
          'error_code': errorCode,
          'error_message': errorMessage,
          'app_version': packageInfo.version,
          'app_build': int.tryParse(packageInfo.buildNumber) ?? 0,
          'package_name': packageName ?? packageInfo.packageName,
          'update_version': updateVersion,
          'update_build': updateBuild,
          'required_update': requiredUpdate,
          'install_permission': installPermission,
          'notification_permission': notificationPermission,
          'device_model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'android_sdk': androidInfo.version.sdkInt,
          'manifest_url': manifestUrl,
          'download_url': downloadUrl,
          'payload': payload ?? const <String, dynamic>{},
        },
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          extra: const <String, dynamic>{
            'skip_android_update_required_handler': true,
          },
        ),
      );
    } catch (e) {
      debugPrint('androidUpdateReport ignored: $e');
    }
  }
}
