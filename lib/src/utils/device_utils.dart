import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _deviceFingerprintKey = 'stable_device_fingerprint_v1';

/// Генерирует SHA256‑хеш отпечатка устройства.
/// Помещать в безопасное место; не включает чувствительные данные.
/// Если нужен полностью стабильный fingerprint (без изменения со временем),
/// убери timestamp из raw.
Future<String> generateDeviceFingerprint() async {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(_deviceFingerprintKey)?.trim();
  if (cached != null && cached.isNotEmpty) {
    return cached;
  }

  final di = DeviceInfoPlugin();
  final info = await di.deviceInfo;
  final infoMap = info.data;

  // Собираем набор полей, которые обычно присутствуют на разных платформах.
  // Не используем поля, которые могут содержать чувствительную информацию.
  final model = infoMap['model'] ?? infoMap['name'] ?? '';
  final manufacturer = infoMap['manufacturer'] ?? '';
  final osVersion = infoMap['osVersion'] ?? infoMap['systemVersion'] ?? '';
  final id = infoMap['identifierForVendor'] ?? infoMap['id'] ?? '';

  final raw = '$model|$manufacturer|$osVersion|$id';

  final bytes = utf8.encode(raw);
  final digest = sha256.convert(bytes);
  final fingerprint = digest.toString();
  await prefs.setString(_deviceFingerprintKey, fingerprint);
  return fingerprint;
}
