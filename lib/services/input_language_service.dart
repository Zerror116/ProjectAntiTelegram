import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class InputLanguageService {
  InputLanguageService._();

  static final InputLanguageService instance = InputLanguageService._();

  static const EventChannel _macosChannel = EventChannel(
    'project_fenix/input_language',
  );
  static const MethodChannel _macosMethodChannel = MethodChannel(
    'project_fenix/input_language_query',
  );

  final ValueNotifier<String> currentCode = ValueNotifier('EN');

  StreamSubscription<dynamic>? _subscription;
  Timer? _pollTimer;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    currentCode.value = _normalizeCode(
      WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }

    _subscription = _macosChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        final next = _normalizeCode(event?.toString());
        if (next != currentCode.value) {
          currentCode.value = next;
        }
      },
      onError: (_) {},
    );
    await _refreshFromPlatform();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _refreshFromPlatform(),
    );
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _initialized = false;
  }

  Future<void> _refreshFromPlatform() async {
    try {
      final value = await _macosMethodChannel.invokeMethod<String>(
        'getCurrentLanguage',
      );
      final next = _normalizeCode(value);
      if (next != currentCode.value) {
        currentCode.value = next;
      }
    } catch (_) {}
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
