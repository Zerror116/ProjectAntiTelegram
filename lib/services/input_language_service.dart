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
  Timer? _retryTimer;
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

    await _bootstrapNativeLookup();
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _initialized = false;
    _nativeLookupAvailable = false;
  }

  Future<void> _bootstrapNativeLookup() async {
    for (var attempt = 0; attempt < 6; attempt += 1) {
      final initial = await _queryFromPlatform();
      if (initial != null) {
        _nativeLookupAvailable = true;
        _updateCode(initial);
        _ensurePolling();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _nativeLookupAvailable = false;
    _scheduleRetry();
  }

  void _ensurePolling() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _refreshFromPlatform(),
    );
  }

  void _scheduleRetry() {
    if (!_initialized || _retryTimer != null) return;
    _retryTimer = Timer(const Duration(seconds: 1), () async {
      _retryTimer = null;
      if (!_initialized) return;
      await _bootstrapNativeLookup();
    });
  }

  Future<void> _refreshFromPlatform() async {
    if (!_nativeLookupAvailable) return;
    final value = await _queryFromPlatform();
    if (value == null) {
      _nativeLookupAvailable = false;
      _scheduleRetry();
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
