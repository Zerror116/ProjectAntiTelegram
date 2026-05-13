import 'dart:convert';
import 'dart:js_interop';

@JS('phoenixPasskeys.isSupported')
external bool _phoenixPasskeysIsSupported();

@JS('phoenixPasskeys.create')
external JSPromise<JSString> _phoenixPasskeysCreate(JSString optionsJson);

@JS('phoenixPasskeys.get')
external JSPromise<JSString> _phoenixPasskeysGet(JSString optionsJson);

class PhoenixPasskeyPlatform {
  static Future<bool> isSupported() async {
    try {
      return _phoenixPasskeysIsSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> create(
    Map<String, dynamic> options,
  ) async {
    try {
      final json = (await _phoenixPasskeysCreate(
        jsonEncode(options).toJS,
      ).toDart).toDart;
      final decoded = jsonDecode(json);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('Passkey response is not an object');
    } catch (error) {
      if (error is FormatException) rethrow;
      throw UnsupportedError('Passkey недоступен в этом браузере');
    }
  }

  static Future<Map<String, dynamic>> get(Map<String, dynamic> options) async {
    try {
      final json = (await _phoenixPasskeysGet(
        jsonEncode(options).toJS,
      ).toDart).toDart;
      final decoded = jsonDecode(json);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('Passkey response is not an object');
    } catch (error) {
      if (error is FormatException) rethrow;
      throw UnsupportedError('Passkey недоступен в этом браузере');
    }
  }
}
