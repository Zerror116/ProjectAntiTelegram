import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DeepLinkService {
  static const MethodChannel _channel = MethodChannel(
    'com.garphoenix.projectphoenix/deep_links',
  );

  static Future<Uri?> getInitialUri() async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _channel.invokeMethod<String>('getInitialLink');
      final value = raw?.trim() ?? '';
      if (value.isEmpty) return null;
      return Uri.tryParse(value);
    } catch (_) {
      return null;
    }
  }

  static Future<Uri?> consumeLatestUri() async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _channel.invokeMethod<String>('consumeLatestLink');
      final value = raw?.trim() ?? '';
      if (value.isEmpty) return null;
      return Uri.tryParse(value);
    } catch (_) {
      return null;
    }
  }
}
