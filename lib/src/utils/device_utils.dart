import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Генерирует SHA256‑хеш отпечатка устройства.
/// Помещать в безопасное место; не включает чувствительные данные.
/// Если нужен полностью стабильный fingerprint (без изменения со временем),
/// убери timestamp из raw.
Future<String> generateDeviceFingerprint() async {
  final di = DeviceInfoPlugin();
  final info = await di.deviceInfo;
  final infoMap = info.toMap();

  // Собираем набор полей, которые обычно присутствуют на разных платформах.
  // Не используем поля, которые могут содержать чувствительную информацию.
  final model = infoMap['model'] ?? infoMap['name'] ?? '';
  final manufacturer = infoMap['manufacturer'] ?? '';
  final osVersion = infoMap['osVersion'] ?? infoMap['systemVersion'] ?? '';
  final id = infoMap['identifierForVendor'] ?? infoMap['id'] ?? '';

  // Добавляем timestamp при первом создании для дополнительной уникальности.
  // Если нужен стабильный fingerprint — удалите часть с DateTime.now().
  final raw = '$model|$manufacturer|$osVersion|$id|${DateTime.now().millisecondsSinceEpoch}';

  final bytes = utf8.encode(raw);
  final digest = sha256.convert(bytes);
  return digest.toString();
}
