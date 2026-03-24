import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _deviceFingerprintKey = 'stable_device_fingerprint_v2';
const _deviceInstallSaltKey = 'stable_device_install_salt_v1';

Future<String> _getOrCreateInstallSalt(SharedPreferences prefs) async {
  final cached = prefs.getString(_deviceInstallSaltKey)?.trim();
  if (cached != null && cached.isNotEmpty) return cached;
  final rnd = Random.secure();
  final entropy = List<int>.generate(24, (_) => rnd.nextInt(256));
  final created = base64UrlEncode(entropy);
  await prefs.setString(_deviceInstallSaltKey, created);
  return created;
}

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
  final installSalt = await _getOrCreateInstallSalt(prefs);

  String raw = '';
  try {
    final di = DeviceInfoPlugin();
    final info = await di.deviceInfo;
    final infoMap = info.data;

    // Собираем набор полей, которые обычно присутствуют на разных платформах.
    // Не используем поля, которые могут содержать чувствительную информацию.
    final model = infoMap['model'] ?? infoMap['name'] ?? '';
    final manufacturer = infoMap['manufacturer'] ?? '';
    final osVersion = infoMap['osVersion'] ?? infoMap['systemVersion'] ?? '';
    final id = infoMap['identifierForVendor'] ?? infoMap['id'] ?? '';
    raw = '$model|$manufacturer|$osVersion|$id|$installSalt';
  } catch (_) {
    // fallback ниже
  }
  if (raw.trim().isEmpty) {
    final rnd = Random.secure();
    final entropy = List<int>.generate(32, (_) => rnd.nextInt(256));
    raw = '${base64UrlEncode(entropy)}|$installSalt';
  }

  final bytes = utf8.encode(raw);
  final digest = sha256.convert(bytes);
  final fingerprint = digest.toString();
  await prefs.setString(_deviceFingerprintKey, fingerprint);
  return fingerprint;
}
