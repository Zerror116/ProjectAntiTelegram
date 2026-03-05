import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class InputLanguageService {
  InputLanguageService._();

  static final InputLanguageService instance = InputLanguageService._();

  static const MethodChannel _macosMethodChannel = MethodChannel(
    'project_fenix/input_language_query',
  );

  final ValueNotifier<String> currentCode = ValueNotifier('EN');

  Timer? _pollTimer;
  bool _initialized = false;
  bool _nativeLookupAvailable = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    currentCode.value = _normalizeCode(
      WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }

    final initial = await _queryFromPlatform();
    if (initial == null) {
      // Плагин может отсутствовать на desktop/web debug сборках.
      return;
    }
    _nativeLookupAvailable = true;
    _updateCode(initial);
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _refreshFromPlatform(),
    );
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _initialized = false;
    _nativeLookupAvailable = false;
  }

  Future<void> _refreshFromPlatform() async {
    if (!_nativeLookupAvailable) return;
    final value = await _queryFromPlatform();
    if (value == null) {
      _nativeLookupAvailable = false;
      return;
    }
    _updateCode(value);
  }

  Future<String?> _queryFromPlatform() async {
    try {
      return await _macosMethodChannel.invokeMethod<String>(
        'getCurrentLanguage',
      );
    } on MissingPluginException {
      return null;
    } catch (_) {}
    return null;
  }

  void _updateCode(String? raw) {
    final next = _normalizeCode(raw);
    if (next != currentCode.value) {
      currentCode.value = next;
    }
  }

  String _normalizeCode(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return 'EN';
    final code = value.split(RegExp(r'[-_]')).first.trim();
    if (code.isEmpty) return 'EN';
    return code.toUpperCase();
  }
}

final inputLanguageService = InputLanguageService.instance;
