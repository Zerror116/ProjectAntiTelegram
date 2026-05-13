import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PhoenixPasskeyPlatform {
  static const MethodChannel _channel = MethodChannel(
    'com.garphoenix.projectphoenix/passkeys',
  );

  static Future<bool> isSupported() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') == true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> create(
    Map<String, dynamic> options,
  ) async {
    final result = await _channel.invokeMethod<String>(
      'create',
      jsonEncode(options),
    );
    final decoded = jsonDecode(result ?? '{}');
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Passkey response is not an object');
  }

  static Future<Map<String, dynamic>> get(Map<String, dynamic> options) async {
    final result = await _channel.invokeMethod<String>(
      'get',
      jsonEncode(options),
    );
    final decoded = jsonDecode(result ?? '{}');
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Passkey response is not an object');
  }
}
