// lib/main.dart
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'screens/auth_screen.dart';
import 'screens/phone_name_screen.dart';
import 'screens/main_shell.dart';
import 'services/auth_service.dart';
import 'services/input_language_service.dart';
import 'theme/app_theme.dart';
import 'widgets/phoenix_loader.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
const String _rawApiBaseUrl = String.fromEnvironment(
  'FENIX_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:3000',
);
final String _initialApiBaseUrl = _resolveApiBaseUrl(_rawApiBaseUrl);
String _runtimeApiBaseUrl = _initialApiBaseUrl;
final Dio dio = Dio(
  BaseOptions(
    baseUrl: _runtimeApiBaseUrl,
    connectTimeout: const Duration(seconds: 8),
    sendTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
  ),
);
late final AuthService authService;

// Socket and event bus for chat events
io.Socket? socket;
final StreamController<Map<String, dynamic>> chatEventsController =
    StreamController.broadcast();
final ValueNotifier<bool> notificationsEnabledNotifier = ValueNotifier(true);
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);
final ValueNotifier<Color> lightThemeSeedNotifier = ValueNotifier(
  const Color(0xFF2F6BFF),
);
final ValueNotifier<Color> darkThemeSeedNotifier = ValueNotifier(
  const Color(0xFF7A4DFF),
);
final ValueNotifier<String> uiDensityNotifier = ValueNotifier('standard');
final ValueNotifier<String> uiCardSizeNotifier = ValueNotifier('standard');
final ValueNotifier<bool> performanceModeNotifier = ValueNotifier(false);
final ValueNotifier<int> themeStyleVersionNotifier = ValueNotifier(0);
final ValueNotifier<String?> activeChatIdNotifier = ValueNotifier<String?>(
  null,
);

const _notificationsPrefPrefix = 'notifications_enabled_';
const _themePrefPrefix = 'theme_mode_dark_';
const _uiDensityPrefPrefix = 'ui_density_';
const _uiCardSizePrefPrefix = 'ui_card_size_';
const _performanceModePrefPrefix = 'performance_mode_';
String? _lastPlayedMessageId;
bool _handlingAuthFailure = false;
final AudioPlayer _appSoundPlayer = AudioPlayer();
bool _appSoundPlayerPrepared = false;
bool _socketInitInProgress = false;
String? _socketBoundUserId;
String? _socketBoundViewRole;
String _lastConnectivityHint = '';

enum AppNoticeTone { info, success, warning, error }

enum AppUiSound { tap, sent, incoming, success, warning }

String _resolveApiBaseUrl(String raw) {
  const fallback = 'http://127.0.0.1:3000';
  final source = raw.trim();
  if (source.isEmpty) return fallback;

  final candidate = source.contains('://') ? source : 'http://$source';
  Uri uri;
  try {
    uri = Uri.parse(candidate);
  } catch (_) {
    debugPrint('Invalid FENIX_API_BASE_URL="$source", fallback to $fallback');
    return fallback;
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    debugPrint(
      'Unsupported API scheme in FENIX_API_BASE_URL="$source", fallback to $fallback',
    );
    return fallback;
  }

  final host = uri.host.trim();
  if (host.isEmpty) {
    debugPrint(
      'Empty API host in FENIX_API_BASE_URL="$source", fallback to $fallback',
    );
    return fallback;
  }

  // dart:io headers require ASCII-safe host for local dev URLs.
  final isAsciiHost = RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(host);
  if (!isAsciiHost) {
    debugPrint(
      'Non-ASCII API host "$host" in FENIX_API_BASE_URL, fallback to $fallback',
    );
    return fallback;
  }

  final portPart = uri.hasPort ? ':${uri.port}' : '';
  final path = (uri.path == '/' ? '' : uri.path).trim();
  return '$scheme://$host$portPart$path';
}

void _setRuntimeApiBaseUrl(String next) {
  final normalized = _resolveApiBaseUrl(next);
  if (_runtimeApiBaseUrl == normalized && dio.options.baseUrl == normalized) {
    return;
  }
  _runtimeApiBaseUrl = normalized;
  dio.options.baseUrl = normalized;
  debugPrint('API base URL switched to $_runtimeApiBaseUrl');
}

List<String> _buildApiBaseCandidates() {
  final current = _resolveApiBaseUrl(dio.options.baseUrl);
  final out = <String>[current];
  Uri? uri;
  try {
    uri = Uri.parse(current);
  } catch (_) {}

  final host = uri?.host.toLowerCase().trim() ?? '';
  final port = uri?.hasPort == true ? uri!.port : 3000;
  final scheme = (uri?.scheme.isNotEmpty ?? false) ? uri!.scheme : 'http';
  final path = (uri?.path ?? '').trim();
  final pathPart = path.isEmpty || path == '/' ? '' : path;

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (host == '127.0.0.1' || host == 'localhost') {
      out.add('$scheme://10.0.2.2:$port$pathPart');
      out.add('$scheme://10.0.3.2:$port$pathPart');
    }
  }

  const fallbackRaw = String.fromEnvironment(
    'FENIX_API_FALLBACK_BASE_URL',
    defaultValue: '',
  );
  final fallback = fallbackRaw.trim();
  if (fallback.isNotEmpty) {
    out.add(_resolveApiBaseUrl(fallback));
  }

  final unique = <String>{};
  final ordered = <String>[];
  for (final item in out) {
    final normalized = _resolveApiBaseUrl(item);
    if (unique.add(normalized)) ordered.add(normalized);
  }
  return ordered;
}

String _buildConnectivityHint() {
  final base = _runtimeApiBaseUrl;
  final uri = Uri.tryParse(base);
  final host = uri?.host.toLowerCase().trim() ?? '';
  final port = uri?.hasPort == true ? uri!.port : 3000;

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (host == '127.0.0.1' || host == 'localhost') {
      return 'Android использует свой localhost.\n'
          '1) Подключите телефон по USB и выполните:\n'
          '   adb reverse tcp:$port tcp:$port\n'
          '2) Или запустите с LAN IP Mac:\n'
          '   flutter run --dart-define=FENIX_API_BASE_URL=http://<IP_Mac>:$port';
    }
  }
  return 'Проверьте, что сервер запущен и доступен по адресу $base';
}

class _AppNoticePayload {
  final int id;
  final String message;
  final String? title;
  final AppNoticeTone tone;
  final Duration duration;

  const _AppNoticePayload({
    required this.id,
    required this.message,
    required this.title,
    required this.tone,
    required this.duration,
  });
}

final ValueNotifier<_AppNoticePayload?> _appNoticeNotifier =
    ValueNotifier<_AppNoticePayload?>(null);
int _appNoticeSeq = 0;
Timer? _appNoticeTimer;

class _SubscriptionUiPayload {
  final bool blocked;
  final String? blockedTitle;
  final String? blockedMessage;
  final String? warningMessage;
  final DateTime? warningExpiresAt;

  const _SubscriptionUiPayload({
    required this.blocked,
    this.blockedTitle,
    this.blockedMessage,
    this.warningMessage,
    this.warningExpiresAt,
  });

  static const empty = _SubscriptionUiPayload(blocked: false);
}

final ValueNotifier<_SubscriptionUiPayload> _subscriptionUiNotifier =
    ValueNotifier<_SubscriptionUiPayload>(_SubscriptionUiPayload.empty);
DateTime? _stickySubscriptionWarningExpiresAt;

String _settingsScopeUserId() {
  final id = authService.currentUser?.id;
  if (id != null && id.trim().isNotEmpty) return id;
  return 'guest';
}

VisualDensity _resolveVisualDensity() {
  return VisualDensity.standard;
}

double _resolveCardScale() {
  return 1;
}

ThemeData _buildLightTheme() {
  final highContrast = performanceModeNotifier.value;
  final base = AppTheme.light(
    seedColor: lightThemeSeedNotifier.value,
    visualDensity: _resolveVisualDensity(),
    cardScale: _resolveCardScale(),
    highContrast: highContrast,
  );
  if (!performanceModeNotifier.value) return base;
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
  );
}

ThemeData _buildDarkTheme() {
  final highContrast = performanceModeNotifier.value;
  final base = AppTheme.dark(
    seedColor: darkThemeSeedNotifier.value,
    visualDensity: _resolveVisualDensity(),
    cardScale: _resolveCardScale(),
    highContrast: highContrast,
  );
  if (!performanceModeNotifier.value) return base;
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
  );
}

Widget _wrapAppRoot(BuildContext context, Widget child) {
  final reduced = performanceModeNotifier.value;
  final host = _GlobalNoticeHost(child: child);
  if (!reduced) {
    return ScaffoldMessenger(child: host);
  }
  final media = MediaQuery.maybeOf(context);
  if (media == null) {
    return ScaffoldMessenger(child: host);
  }
  return ScaffoldMessenger(
    child: MediaQuery(
      data: media.copyWith(disableAnimations: true),
      child: host,
    ),
  );
}

void _applyPerformanceRuntimeTuning(bool enabled) {
  final cache = PaintingBinding.instance.imageCache;
  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  if (enabled) {
    cache.maximumSizeBytes = 24 * 1024 * 1024;
    cache.maximumSize = 160;
    cache.clearLiveImages();
    cache.clear();
    return;
  }
  cache.maximumSizeBytes = isAndroid ? 72 * 1024 * 1024 : 110 * 1024 * 1024;
  cache.maximumSize = isAndroid ? 800 : 1200;
}

Future<void> refreshUserPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  final notifications =
      prefs.getBool('$_notificationsPrefPrefix$scope') ?? true;
  final darkMode = prefs.getBool('$_themePrefPrefix$scope') ?? false;
  final performanceRaw = prefs.getBool('$_performanceModePrefPrefix$scope');
  final defaultPerformanceMode =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final performanceMode = performanceRaw ?? defaultPerformanceMode;

  notificationsEnabledNotifier.value = notifications;
  themeModeNotifier.value = darkMode ? ThemeMode.dark : ThemeMode.light;
  // Цветовая схема фиксирована: только светлая/тёмная тема без кастомных цветов.
  lightThemeSeedNotifier.value = const Color(0xFF2F6BFF);
  darkThemeSeedNotifier.value = const Color(0xFF7A4DFF);
  // Плотность/масштаб карточек больше не настраиваются пользователем.
  uiDensityNotifier.value = 'standard';
  uiCardSizeNotifier.value = 'standard';
  await prefs.remove('$_uiDensityPrefPrefix$scope');
  await prefs.remove('$_uiCardSizePrefPrefix$scope');
  if (performanceRaw == null && defaultPerformanceMode) {
    await prefs.setBool('$_performanceModePrefPrefix$scope', true);
  }
  performanceModeNotifier.value = performanceMode;
  _applyPerformanceRuntimeTuning(performanceMode);
  themeStyleVersionNotifier.value = themeStyleVersionNotifier.value + 1;
}

Future<void> setNotificationsEnabled(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  await prefs.setBool('$_notificationsPrefPrefix$scope', value);
  notificationsEnabledNotifier.value = value;
}

Future<void> setDarkModeEnabled(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  await prefs.setBool('$_themePrefPrefix$scope', value);
  themeModeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
}

Future<void> setUiDensityPreset(String value) async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  await prefs.remove('$_uiDensityPrefPrefix$scope');
  uiDensityNotifier.value = 'standard';
  themeStyleVersionNotifier.value = themeStyleVersionNotifier.value + 1;
}

Future<void> setUiCardSizePreset(String value) async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  await prefs.remove('$_uiCardSizePrefPrefix$scope');
  uiCardSizeNotifier.value = 'standard';
  themeStyleVersionNotifier.value = themeStyleVersionNotifier.value + 1;
}

Future<void> setPerformanceModeEnabled(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  await prefs.setBool('$_performanceModePrefPrefix$scope', value);
  performanceModeNotifier.value = value;
  _applyPerformanceRuntimeTuning(value);
  themeStyleVersionNotifier.value = themeStyleVersionNotifier.value + 1;
}

Future<void> _prepareAppSoundPlayer() async {
  if (_appSoundPlayerPrepared) return;
  _appSoundPlayerPrepared = true;
  try {
    try {
      await _appSoundPlayer.setPlayerMode(PlayerMode.lowLatency);
    } catch (_) {}
    await _appSoundPlayer.setReleaseMode(ReleaseMode.stop);
  } catch (_) {
    _appSoundPlayerPrepared = false;
  }
}

Future<void> playAppSound(AppUiSound sound) async {
  if (sound == AppUiSound.incoming && !notificationsEnabledNotifier.value) {
    return;
  }

  final assetPath = switch (sound) {
    AppUiSound.tap => 'sounds/tap.wav',
    AppUiSound.sent => 'sounds/sent.wav',
    AppUiSound.incoming => 'sounds/incoming.wav',
    AppUiSound.success => 'sounds/success.wav',
    AppUiSound.warning => 'sounds/warning.wav',
  };

  try {
    await _prepareAppSoundPlayer();
    await _appSoundPlayer.stop();
    await _appSoundPlayer.setReleaseMode(ReleaseMode.stop);
    await _appSoundPlayer.play(AssetSource(assetPath), volume: 1.0);
  } catch (_) {}
}

void showAppNotice(
  BuildContext context,
  String message, {
  String? title,
  AppNoticeTone tone = AppNoticeTone.info,
  Duration duration = const Duration(seconds: 5),
}) {
  _showGlobalNotice(message, title: title, tone: tone, duration: duration);
}

void showGlobalAppNotice(
  String message, {
  String? title,
  AppNoticeTone tone = AppNoticeTone.info,
  Duration duration = const Duration(seconds: 5),
}) {
  _showGlobalNotice(message, title: title, tone: tone, duration: duration);
}

Duration _normalizeNoticeDuration(Duration duration) {
  return const Duration(seconds: 5);
}

bool _isSubscriptionRestrictedRole(String role) {
  final normalized = role.toLowerCase().trim();
  return normalized == 'tenant' ||
      normalized == 'admin' ||
      normalized == 'worker';
}

bool _isSubscriptionWarningRole(String role) {
  return role.toLowerCase().trim() == 'tenant';
}

const Duration _subscriptionExpiredGraceBeforeBlock = Duration(seconds: 8);

DateTime? _parseSubscriptionDateTime(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.toLocal();
}

String _twoDigits(int value) {
  return value.toString().padLeft(2, '0');
}

String _formatSubscriptionDateTime(DateTime dt) {
  return '${_twoDigits(dt.day)}.${_twoDigits(dt.month)}.${dt.year} '
      '${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}';
}

String _formatCountdown(Duration remaining) {
  final totalSeconds = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String _extractApiErrorMessage(DioException err) {
  final data = err.response?.data;
  if (data is Map) {
    final raw = (data['error'] ?? data['message'] ?? '').toString().trim();
    if (raw.isNotEmpty) return raw;
  }
  return (err.message ?? '').trim();
}

bool _isSubscriptionErrorText(String message) {
  final normalized = message.toLowerCase();
  return normalized.contains('подписк') ||
      normalized.contains('tenant_expired') ||
      normalized.contains('tenant_blocked');
}

String _normalizeSubscriptionBlockedMessage(String source) {
  final normalized = source.toLowerCase();
  if (normalized.contains('ист') || normalized.contains('expired')) {
    return 'Срок подписки истек. Свяжитесь с Вазгеном.';
  }
  return 'Подписка отключена. Свяжитесь с Вазгеном.';
}

void _updateSubscriptionUiState({
  String? forcedBlockedMessage,
  bool promoteWarningDeadline = false,
}) {
  final user = authService.currentUser;
  if (user == null) {
    _stickySubscriptionWarningExpiresAt = null;
    _subscriptionUiNotifier.value = _SubscriptionUiPayload.empty;
    return;
  }

  final role = user.role.toLowerCase().trim();
  if (!_isSubscriptionRestrictedRole(role)) {
    _stickySubscriptionWarningExpiresAt = null;
    _subscriptionUiNotifier.value = _SubscriptionUiPayload.empty;
    return;
  }

  final status = (user.tenantStatus ?? '').toLowerCase().trim();
  final previous = _subscriptionUiNotifier.value;
  final parsedExpiresAt = _parseSubscriptionDateTime(
    user.subscriptionExpiresAt,
  );
  if (_isSubscriptionWarningRole(role) && parsedExpiresAt != null) {
    final sticky = _stickySubscriptionWarningExpiresAt;
    if (sticky == null) {
      _stickySubscriptionWarningExpiresAt = parsedExpiresAt;
    } else if (promoteWarningDeadline) {
      // Явное обновление от сокета (например, продление подписки) может
      // увеличивать дедлайн.
      _stickySubscriptionWarningExpiresAt = parsedExpiresAt;
    } else if (parsedExpiresAt.isBefore(sticky)) {
      // Фоновый poll может прийти со старым дедлайном; держим самый "срочный".
      _stickySubscriptionWarningExpiresAt = parsedExpiresAt;
    }
  }
  DateTime? expiresAt = parsedExpiresAt;
  final now = DateTime.now();
  final stickyDeadline = _stickySubscriptionWarningExpiresAt;
  if (_isSubscriptionWarningRole(role) && stickyDeadline != null) {
    if (expiresAt == null) {
      expiresAt = stickyDeadline;
    } else if (!promoteWarningDeadline && expiresAt.isAfter(stickyDeadline)) {
      // Не даём фоновому refresh "повышать" дедлайн и скрывать предупреждение.
      expiresAt = stickyDeadline;
    }
  }

  final blockedByStatus = status.isNotEmpty && status != 'active';
  if (expiresAt == null &&
      _isSubscriptionWarningRole(role) &&
      !blockedByStatus &&
      previous.warningExpiresAt != null) {
    // Если сервер временно не вернул subscription_expires_at, сохраняем
    // последний известный дедлайн, чтобы предупреждение не "мигало".
    expiresAt = previous.warningExpiresAt;
  }
  if (expiresAt == null &&
      _isSubscriptionWarningRole(role) &&
      !blockedByStatus &&
      _stickySubscriptionWarningExpiresAt != null) {
    expiresAt = _stickySubscriptionWarningExpiresAt;
  }
  final isExpiryReached = expiresAt != null && !expiresAt.isAfter(now);
  final expiryGraceActive =
      isExpiryReached &&
      now.difference(expiresAt) < _subscriptionExpiredGraceBeforeBlock;
  final blockedByExpiry = isExpiryReached && !expiryGraceActive;
  final forced = (forcedBlockedMessage ?? '').trim();

  final blocked = forced.isNotEmpty || blockedByStatus || blockedByExpiry;

  String? blockedTitle;
  String? blockedMessage;
  if (blocked) {
    blockedTitle = blockedByExpiry
        ? 'Срок подписки истек'
        : 'Подписка отключена';
    blockedMessage = forced.isNotEmpty
        ? forced
        : '${blockedByExpiry ? 'Срок подписки истек.' : 'Подписка отключена.'} Свяжитесь с Вазгеном.';
  }

  String? warningMessage;
  DateTime? warningExpiresAt;
  if (!blocked && expiresAt != null && _isSubscriptionWarningRole(role)) {
    final remaining = expiresAt.difference(now);
    if (remaining <= const Duration(days: 1) && remaining > Duration.zero) {
      warningMessage =
          'Подписка истекает ${_formatSubscriptionDateTime(expiresAt)}. Продлите заранее.';
      warningExpiresAt = expiresAt;
    } else if (remaining <= Duration.zero && expiryGraceActive) {
      warningMessage = 'Ну, у вас предупреждал...';
      warningExpiresAt = expiresAt;
    }
  }

  if (_isSubscriptionWarningRole(role)) {
    _stickySubscriptionWarningExpiresAt = warningExpiresAt ?? expiresAt;
  }

  _subscriptionUiNotifier.value = _SubscriptionUiPayload(
    blocked: blocked,
    blockedTitle: blockedTitle,
    blockedMessage: blockedMessage,
    warningMessage: warningMessage,
    warningExpiresAt: warningExpiresAt,
  );
}

void _applySubscriptionSocketUpdate(dynamic raw) {
  if (raw is! Map) return;
  final current = authService.currentUser;
  if (current == null) return;
  if (!_isSubscriptionRestrictedRole(current.role)) return;

  final map = Map<String, dynamic>.from(current.toMap());
  final nextStatus = (raw['status'] ?? raw['tenant_status'] ?? '')
      .toString()
      .trim();
  final nextExpiry =
      (raw['subscription_expires_at'] ?? raw['subscriptionExpiresAt'] ?? '')
          .toString()
          .trim();

  if (nextStatus.isNotEmpty) {
    map['tenant_status'] = nextStatus;
  }
  final hasExpiryField =
      raw.containsKey('subscription_expires_at') ||
      raw.containsKey('subscriptionExpiresAt');
  if (hasExpiryField) {
    map['subscription_expires_at'] = nextExpiry;
  }

  authService.updateCurrentUserFromMap(map);
  _updateSubscriptionUiState(
    promoteWarningDeadline: hasExpiryField && nextExpiry.isNotEmpty,
  );
}

void _showGlobalNotice(
  String message, {
  String? title,
  AppNoticeTone tone = AppNoticeTone.info,
  Duration duration = const Duration(seconds: 5),
}) {
  final text = message.trim();
  if (text.isEmpty) return;
  final normalizedDuration = _normalizeNoticeDuration(duration);
  final payload = _AppNoticePayload(
    id: ++_appNoticeSeq,
    message: text,
    title: title?.trim().isNotEmpty == true ? title!.trim() : null,
    tone: tone,
    duration: normalizedDuration,
  );
  _appNoticeNotifier.value = payload;
  _appNoticeTimer?.cancel();
  _appNoticeTimer = Timer(normalizedDuration, () {
    final current = _appNoticeNotifier.value;
    if (current != null && current.id == payload.id) {
      _appNoticeNotifier.value = null;
    }
  });
}

class _GlobalNoticeHost extends StatelessWidget {
  final Widget child;

  const _GlobalNoticeHost({required this.child});

  double _subscriptionWarningBottomOffset(BuildContext context) {
    final media = MediaQuery.of(context);
    final safeBottom = media.viewPadding.bottom;
    return safeBottom + kBottomNavigationBarHeight + 12;
  }

  ({IconData icon, Color accent}) _noticeVisuals(
    BuildContext context,
    AppNoticeTone tone,
  ) {
    final theme = Theme.of(context);
    return switch (tone) {
      AppNoticeTone.success => (
        icon: Icons.check_circle_outline,
        accent: theme.brightness == Brightness.dark
            ? const Color(0xFF8BCF9B)
            : const Color(0xFF2E7D32),
      ),
      AppNoticeTone.warning => (
        icon: Icons.notifications_active_outlined,
        accent: theme.brightness == Brightness.dark
            ? const Color(0xFFFFC870)
            : const Color(0xFFB26A00),
      ),
      AppNoticeTone.error => (
        icon: Icons.error_outline,
        accent: theme.brightness == Brightness.dark
            ? const Color(0xFFFF9C92)
            : const Color(0xFFB3261E),
      ),
      AppNoticeTone.info => (
        icon: Icons.mark_chat_unread_outlined,
        accent: theme.brightness == Brightness.dark
            ? const Color(0xFF9CCBFF)
            : const Color(0xFF215EA6),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reducedMotion =
        performanceModeNotifier.value ||
        (MediaQuery.maybeOf(context)?.disableAnimations == true);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        return Stack(
          fit: StackFit.loose,
          children: [
            Positioned.fill(child: child),
            IgnorePointer(
              ignoring: false,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ValueListenableBuilder<_AppNoticePayload?>(
                    valueListenable: _appNoticeNotifier,
                    builder: (context, notice, _) {
                      return AnimatedSwitcher(
                        duration: reducedMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: notice == null
                            ? const SizedBox.shrink()
                            : Padding(
                                key: ValueKey(notice.id),
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  12,
                                  0,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 760,
                                  ),
                                  child: Material(
                                    color:
                                        theme.colorScheme.surfaceContainerHigh,
                                    elevation: 8,
                                    borderRadius: BorderRadius.circular(16),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: () =>
                                          _appNoticeNotifier.value = null,
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          14,
                                          12,
                                          14,
                                          12,
                                        ),
                                        child: Builder(
                                          builder: (context) {
                                            final visuals = _noticeVisuals(
                                              context,
                                              notice.tone,
                                            );
                                            return Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 1,
                                                      ),
                                                  child: Icon(
                                                    visuals.icon,
                                                    color: visuals.accent,
                                                    size: 20,
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      if (notice.title != null)
                                                        Text(
                                                          notice.title!,
                                                          style: theme
                                                              .textTheme
                                                              .labelLarge
                                                              ?.copyWith(
                                                                color: theme
                                                                    .colorScheme
                                                                    .onSurface,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                        ),
                                                      Text(
                                                        notice.message,
                                                        style: theme
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.copyWith(
                                                              color: theme
                                                                  .colorScheme
                                                                  .onSurface,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      );
                    },
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<_SubscriptionUiPayload>(
              valueListenable: _subscriptionUiNotifier,
              builder: (context, state, _) {
                if (state.blocked || state.warningMessage == null) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  left: 12,
                  right: 12,
                  bottom: _subscriptionWarningBottomOffset(context),
                  child: IgnorePointer(
                    ignoring: true,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: theme.colorScheme.error,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                10,
                                12,
                                10,
                              ),
                              child: StreamBuilder<int>(
                                stream: Stream<int>.periodic(
                                  const Duration(seconds: 1),
                                  (tick) => tick,
                                ),
                                builder: (context, _) {
                                  final expiresAt = state.warningExpiresAt;
                                  Duration? remaining;
                                  if (expiresAt != null) {
                                    remaining = expiresAt.difference(
                                      DateTime.now(),
                                    );
                                  }
                                  final countdown = remaining == null
                                      ? null
                                      : _formatCountdown(remaining);
                                  final subtitle = remaining == null
                                      ? null
                                      : remaining <= Duration.zero
                                      ? 'Срок подписки истек'
                                      : 'До отключения: $countdown';

                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.warning_amber_rounded,
                                        size: 18,
                                        color:
                                            theme.colorScheme.onErrorContainer,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              state.warningMessage!,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onErrorContainer,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            if (subtitle != null) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                subtitle,
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onErrorContainer,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            ValueListenableBuilder<_SubscriptionUiPayload>(
              valueListenable: _subscriptionUiNotifier,
              builder: (context, state, _) {
                if (!state.blocked) return const SizedBox.shrink();
                return Positioned.fill(
                  child: Material(
                    color: theme.colorScheme.scrim.withValues(alpha: 0.78),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: theme.colorScheme.errorContainer,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  blurRadius: 26,
                                  offset: Offset(0, 16),
                                  color: Color(0x33000000),
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                22,
                                22,
                                22,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 44,
                                    color: theme.colorScheme.error,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    state.blockedTitle ?? 'Подписка отключена',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    state.blockedMessage ??
                                        'Подписка отключена. Свяжитесь с Вазгеном.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

String _incomingMessagePreview(Map<String, dynamic>? message) {
  if (message == null) return 'Откройте чат, чтобы посмотреть сообщение';
  final text = (message['text'] ?? '').toString().trim();
  if (text.isNotEmpty) {
    final singleLine = text.replaceAll('\n', ' ');
    return singleLine.length > 90
        ? '${singleLine.substring(0, 90)}...'
        : singleLine;
  }
  final meta = message['meta'];
  if (meta is Map) {
    final title = (meta['title'] ?? '').toString().trim();
    if (title.isNotEmpty) return title;
  }
  return 'Новое сообщение';
}

Future<void> _maybePlayIncomingMessageSound(dynamic data) async {
  if (!notificationsEnabledNotifier.value) return;
  Map<String, dynamic>? message;
  if (data is Map) {
    final raw = data['message'] ?? data;
    if (raw is Map) {
      message = Map<String, dynamic>.from(raw);
    }
  }

  final currentUserId = authService.currentUser?.id;
  final senderId = message?['sender_id']?.toString();
  if (currentUserId != null && senderId != null && senderId == currentUserId) {
    return;
  }

  final messageId = message?['id']?.toString();
  if (messageId != null && messageId == _lastPlayedMessageId) {
    return;
  }
  if (messageId != null) {
    _lastPlayedMessageId = messageId;
  }

  await playAppSound(AppUiSound.incoming);

  final chatId =
      (data is Map
              ? (data['chatId'] ?? message?['chat_id'] ?? message?['chatId'])
              : null)
          ?.toString();
  if ((chatId?.isNotEmpty ?? false) && activeChatIdNotifier.value == chatId) {
    return;
  }

  final senderName = (message?['sender_name'] ?? '').toString().trim();
  final sender = senderName.isNotEmpty ? senderName : 'Новое сообщение';
  showGlobalAppNotice(
    _incomingMessagePreview(message),
    title: sender,
    tone: AppNoticeTone.info,
    duration: const Duration(seconds: 5),
  );
}

// ✅ Функция для безопасного отключения socket
Future<void> disconnectSocket() async {
  try {
    if (socket != null) {
      debugPrint('🔌 Disconnecting socket...');
      socket!.disconnect();
      try {
        socket!.dispose();
      } catch (_) {}
    }
    socket = null;
    _socketBoundUserId = null;
    _socketBoundViewRole = null;
    debugPrint('✅ Socket disconnected');
  } catch (e) {
    debugPrint('❌ Error disconnecting socket: $e');
  }
}

Future<bool> ensureDatabaseExists() async {
  final candidates = _buildApiBaseCandidates();
  Object? lastError;

  for (final base in candidates) {
    _setRuntimeApiBaseUrl(base);
    try {
      debugPrint('ensureDatabaseExists: checking /health at $base');
      final health = await dio.get(
        '/health',
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
      debugPrint(
        'ensureDatabaseExists: /health[$base] status=${health.statusCode}, data=${health.data}',
      );
      if (health.statusCode == 200) {
        final data = health.data;
        _lastConnectivityHint = '';
        if (data is Map && data['ok'] == true) return true;
        return true;
      }
    } catch (e) {
      lastError = e;
      debugPrint('ensureDatabaseExists: /health[$base] failed: $e');
    }

    try {
      debugPrint('ensureDatabaseExists: fallback /api/setup at $base');
      final resp = await dio.post(
        '/api/setup',
        options: Options(
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
        ),
      );
      debugPrint(
        'ensureDatabaseExists: /api/setup[$base] status=${resp.statusCode}, data=${resp.data}',
      );
      if (resp.statusCode == 200) {
        final data = resp.data;
        _lastConnectivityHint = '';
        if (data is Map && data['ok'] == true) return true;
      }
    } catch (e) {
      lastError = e;
      debugPrint('ensureDatabaseExists fallback[$base] error: $e');
    }
  }

  _lastConnectivityHint = _buildConnectivityHint();
  if (lastError != null) {
    debugPrint(
      'ensureDatabaseExists: all candidates failed, lastError=$lastError',
    );
  }
  return false;
}

bool _isAuthEndpoint(RequestOptions options) {
  final path = options.path.toLowerCase();
  return path.contains('/auth/login') ||
      path.contains('/auth/register') ||
      path.contains('/auth/refresh') ||
      path.contains('/auth/forgot') ||
      path.contains('/auth/reset') ||
      path.contains('/login') ||
      path.contains('/register');
}

void _removeHeaderIgnoreCase(Map<String, dynamic> headers, String name) {
  final target = name.toLowerCase();
  final toDelete = <String>[];
  for (final key in headers.keys) {
    if (key.toLowerCase() == target) {
      toDelete.add(key);
    }
  }
  for (final key in toDelete) {
    headers.remove(key);
  }
}

void _removeTenantHeaders(Map<String, dynamic> headers) {
  final toDelete = <String>[];
  for (final key in headers.keys) {
    if (key.toLowerCase().contains('tenant')) {
      toDelete.add(key);
    }
  }
  for (final key in toDelete) {
    headers.remove(key);
  }
}

bool _isAsciiHeaderValue(String value) {
  return RegExp(r'^[\x20-\x7E]*$').hasMatch(value);
}

void _dropInvalidHeaderValues(Map<String, dynamic> headers) {
  final toDelete = <String>[];
  headers.forEach((key, value) {
    if (value == null) return;
    final text = value.toString();
    if (!_isAsciiHeaderValue(text)) {
      toDelete.add(key);
    }
  });
  for (final key in toDelete) {
    headers.remove(key);
  }
}

void _attachAuthInterceptor() {
  debugPrint('_attachAuthInterceptor: attaching');
  // Очистка старых/битых tenant-заголовков между перезапусками.
  _removeTenantHeaders(dio.options.headers);
  _dropInvalidHeaderValues(dio.options.headers);
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          // Use AuthService as single source of truth for token
          final token = await authService.getToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          } else {
            options.headers.remove('Authorization');
          }
          await authService.getTenantCode();
          _removeTenantHeaders(options.headers);
          final viewRole = authService.viewRole?.trim();
          _removeHeaderIgnoreCase(options.headers, 'X-View-Role');
          if ((authService.currentUser?.role.toLowerCase().trim() ?? '') ==
                  'creator' &&
              viewRole != null &&
              viewRole.isNotEmpty) {
            options.headers['X-View-Role'] = viewRole;
          }
          // На macOS/http не-ASCII заголовки вызывают FormatException.
          _dropInvalidHeaderValues(options.headers);
          return handler.next(options);
        } catch (e, st) {
          debugPrint('onRequest interceptor error: $e\n$st');
          return handler.next(options);
        }
      },
      onResponse: (response, handler) {
        try {
          final path = response.requestOptions.path.toLowerCase().trim();
          final isProfileResponse =
              path == '/api/profile' || path.endsWith('/api/profile');
          if (isProfileResponse &&
              response.statusCode == 200 &&
              response.data is Map &&
              response.data['user'] is Map) {
            final userMap = Map<String, dynamic>.from(response.data['user']);
            authService.updateCurrentUserFromMap(userMap);
            _updateSubscriptionUiState();
          }
        } catch (e, st) {
          debugPrint('onResponse interceptor error: $e\n$st');
        }
        handler.next(response);
      },
      onError: (err, handler) async {
        final status = err.response?.statusCode;
        final req = err.requestOptions;
        final authHeader = req.headers['Authorization']?.toString() ?? '';
        final hasBearerToken =
            authHeader.toLowerCase().startsWith('bearer ') &&
            authHeader.length > 7;

        // Обрабатываем только реальные auth-failure запросы:
        // - 401 (403 = ошибка прав, не разлогиниваем)
        // - не auth endpoint
        // - запрос содержал токен
        if ((status == 402 || status == 403) && !_isAuthEndpoint(req)) {
          final errorMessage = _extractApiErrorMessage(err);
          if (_isSubscriptionErrorText(errorMessage)) {
            _updateSubscriptionUiState(
              forcedBlockedMessage: _normalizeSubscriptionBlockedMessage(
                errorMessage,
              ),
            );
          }
        }

        if (status == 401 && !_isAuthEndpoint(req) && hasBearerToken) {
          if (_handlingAuthFailure) {
            debugPrint(
              '_attachAuthInterceptor: auth failure already handling, skipping',
            );
            return handler.next(err);
          }

          _handlingAuthFailure = true;
          debugPrint('_attachAuthInterceptor: got 401, forcing logout');
          try {
            await disconnectSocket();
            await authService.clearToken();
            navigatorKey.currentState?.pushNamedAndRemoveUntil(
              '/auth',
              (route) => false,
            );
          } catch (e, st) {
            debugPrint('Error during forced logout in interceptor: $e\n$st');
          }
        }
        handler.next(err);
      },
    ),
  );
  debugPrint('_attachAuthInterceptor: done');
}

// ✅ ИСПРАВЛЕННАЯ инициализация Socket
Future<void> _initSocket() async {
  if (_socketInitInProgress) {
    debugPrint('⏳ _initSocket skipped: initialization already in progress');
    return;
  }

  final userId = authService.currentUser?.id.trim();
  if (userId == null || userId.isEmpty) {
    debugPrint('⏭️ _initSocket skipped: no authenticated user');
    return;
  }

  final currentRole = authService.currentUser?.role.toLowerCase().trim() ?? '';
  final viewRole = currentRole == 'creator'
      ? authService.viewRole?.trim()
      : null;

  final sameBinding =
      _socketBoundUserId == userId &&
      (_socketBoundViewRole ?? '') == (viewRole ?? '');
  if (socket != null && sameBinding) {
    final alreadyActive = socket!.connected || socket!.active;
    if (alreadyActive) {
      debugPrint('✅ _initSocket skipped: socket already active/connecting');
      if (!socket!.connected) {
        try {
          socket!.connect();
        } catch (_) {}
      }
      return;
    }
  }

  _socketInitInProgress = true;
  try {
    debugPrint('🚀 Initializing socket...');

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    if (token == null || token.trim().isEmpty) {
      debugPrint('⏭️ _initSocket skipped: empty auth token');
      return;
    }

    await disconnectSocket();
    final socketAuth = <String, dynamic>{'token': token};
    if (currentRole == 'creator' && viewRole != null && viewRole.isNotEmpty) {
      socketAuth['view_role'] = viewRole;
    }

    // Build options
    socket = io.io(
      _runtimeApiBaseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setAuth(socketAuth)
          .build(),
    );
    _socketBoundUserId = userId;
    _socketBoundViewRole = viewRole ?? '';

    socket?.on('connect', (_) {
      debugPrint('✅ Socket connected: ${socket?.id}');
    });

    socket?.on('disconnect', (reason) {
      debugPrint('📡 Socket disconnected: $reason');
    });

    socket?.on('connect_error', (err) {
      debugPrint('❌ Socket connect_error: $err');
    });

    // Chat created -> notify listeners to reload chats
    socket?.on('chat:created', (data) {
      debugPrint('📬 Socket event chat:created -> $data');
      chatEventsController.add({'type': 'chat:created', 'data': data});
    });

    socket?.on('chat:deleted', (data) {
      debugPrint('📬 Socket event chat:deleted -> $data');
      chatEventsController.add({'type': 'chat:deleted', 'data': data});
    });

    socket?.on('chat:updated', (data) {
      debugPrint('📬 Socket event chat:updated -> $data');
      chatEventsController.add({'type': 'chat:updated', 'data': data});
    });

    socket?.on('chat:pinned', (data) {
      debugPrint('📬 Socket event chat:pinned -> $data');
      chatEventsController.add({'type': 'chat:pinned', 'data': data});
    });

    // New message -> notify listeners
    socket?.on('chat:message', (data) {
      debugPrint('📬 Socket event chat:message -> $data');
      chatEventsController.add({'type': 'chat:message', 'data': data});
      _maybePlayIncomingMessageSound(data);
    });

    socket?.on('chat:message:deleted', (data) {
      debugPrint('📬 Socket event chat:message:deleted -> $data');
      chatEventsController.add({'type': 'chat:message:deleted', 'data': data});
    });

    socket?.on('chat:cleared', (data) {
      debugPrint('📬 Socket event chat:cleared -> $data');
      chatEventsController.add({'type': 'chat:cleared', 'data': data});
    });

    socket?.on('chat:message:read', (data) {
      debugPrint('📬 Socket event chat:message:read -> $data');
      chatEventsController.add({'type': 'chat:message:read', 'data': data});
    });

    socket?.on('tenant:subscription:update', (data) {
      debugPrint('📬 Socket event tenant:subscription:update -> $data');
      _applySubscriptionSocketUpdate(data);
    });

    socket?.on('cart:updated', (data) {
      debugPrint('📬 Socket event cart:updated -> $data');
      chatEventsController.add({'type': 'cart:updated', 'data': data});
    });

    socket?.on('delivery:updated', (data) {
      debugPrint('📬 Socket event delivery:updated -> $data');
      chatEventsController.add({'type': 'delivery:updated', 'data': data});
    });

    socket?.on('claims:updated', (data) {
      debugPrint('📬 Socket event claims:updated -> $data');
      chatEventsController.add({'type': 'claims:updated', 'data': data});
    });

    // Global message event (optional)
    socket?.on('chat:message:global', (data) {
      debugPrint('📬 Socket event chat:message:global -> $data');
      chatEventsController.add({'type': 'chat:message:global', 'data': data});
      _maybePlayIncomingMessageSound(data);
    });

    socket?.connect();
    debugPrint('🔗 Socket connecting...');
  } catch (e, st) {
    debugPrint('_initSocket error: $e\n$st');
    await disconnectSocket();
  } finally {
    _socketInitInProgress = false;
  }
}

Future<Widget> determineInitialScreen(bool dbReady) async {
  debugPrint('determineInitialScreen: dbReady=$dbReady');
  if (!dbReady) return const SetupFailedScreen();

  // ✅ ИСПРАВЛЕНИЕ: Используй tryRefreshOnStartup вместо setAuthHeaderFromStorage
  final logged = await authService.tryRefreshOnStartup().timeout(
    const Duration(seconds: 14),
    onTimeout: () => false,
  );
  debugPrint('determineInitialScreen: tryRefreshOnStartup -> $logged');

  if (logged) {
    _handlingAuthFailure = false;
  }

  if (!logged) {
    return const AuthScreen();
  }

  try {
    final resp = await dio.get(
      '/api/profile',
      options: Options(
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    debugPrint(
      'determineInitialScreen: /api/profile status=${resp.statusCode}',
    );
    if (resp.statusCode == 200 &&
        resp.data is Map &&
        resp.data['user'] is Map) {
      final user = Map<String, dynamic>.from(resp.data['user']);
      final name = user['name'];
      final phone = user['phone'];
      debugPrint('determineInitialScreen: user name=$name phone=$phone');
      if (name == null ||
          (phone == null || (phone is String && phone.trim().isEmpty))) {
        return const PhoneNameScreen(isRegisterFlow: false);
      }
      return const MainShell();
    } else {
      return const AuthScreen();
    }
  } catch (e, st) {
    debugPrint('determineInitialScreen error: $e\n$st');
    return const AuthScreen();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    try {
      await BrowserContextMenu.disableContextMenu();
    } catch (_) {}
  }

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint(
      'FlutterError caught: ${details.exceptionAsString()}\n${details.stack}',
    );
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    final exception = details.exception;
    final stack = details.stack;
    final errorTheme = themeModeNotifier.value == ThemeMode.dark
        ? _buildDarkTheme()
        : _buildLightTheme();
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  color: errorTheme.colorScheme.error,
                  size: 64,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Произошла ошибка',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  exception.toString(),
                  style: TextStyle(color: errorTheme.colorScheme.onSurface),
                ),
                const SizedBox(height: 12),
                Text(
                  stack?.toString() ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    color: errorTheme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: themeModeNotifier.value,
      builder: (context, child) {
        return ScaffoldMessenger(
          child: _GlobalNoticeHost(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  };

  runApp(const DiagnosticBootstrap());
}

class DiagnosticBootstrap extends StatefulWidget {
  const DiagnosticBootstrap({super.key});
  @override
  State<DiagnosticBootstrap> createState() => _DiagnosticBootstrapState();
}

class _DiagnosticBootstrapState extends State<DiagnosticBootstrap> {
  Widget? _home;
  String? _status;
  StreamSubscription<User?>? _authSub;
  Timer? _subscriptionProbeTimer;
  bool _subscriptionProbeBusy = false;

  void _showAuthScreen() {
    if (!mounted) return;
    setState(() {
      _home = const AuthScreen();
      _status = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = navigatorKey.currentState;
      if (navigator == null || !navigator.mounted) return;
      navigator.pushNamedAndRemoveUntil('/auth', (route) => false);
    });
  }

  @override
  void initState() {
    super.initState();
    _startInit();
  }

  @override
  void dispose() {
    try {
      _authSub?.cancel();
    } catch (_) {}
    _subscriptionProbeTimer?.cancel();
    super.dispose();
  }

  void _restartSubscriptionProbe() {
    _subscriptionProbeTimer?.cancel();
    _subscriptionProbeTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_probeSubscriptionState()),
    );
    unawaited(_probeSubscriptionState());
  }

  Future<void> _probeSubscriptionState() async {
    if (!mounted || _subscriptionProbeBusy) return;
    final user = authService.currentUser;
    if (user == null) {
      _updateSubscriptionUiState();
      return;
    }
    if (!_isSubscriptionRestrictedRole(user.role)) {
      _updateSubscriptionUiState();
      return;
    }

    _subscriptionProbeBusy = true;
    try {
      final resp = await dio.get('/api/profile');
      if (resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['user'] is Map) {
        final userMap = Map<String, dynamic>.from(resp.data['user']);
        authService.updateCurrentUserFromMap(userMap);
        _updateSubscriptionUiState();
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final message = _extractApiErrorMessage(e);
      if ((status == 402 || status == 403) &&
          _isSubscriptionErrorText(message)) {
        _updateSubscriptionUiState(
          forcedBlockedMessage: _normalizeSubscriptionBlockedMessage(message),
        );
      }
    } catch (_) {
      // ignore
    } finally {
      _subscriptionProbeBusy = false;
    }
  }

  Future<void> _startInit() async {
    setState(() => _status = 'Инициализация: attaching interceptor');
    try {
      authService = AuthService(dio: dio);
      _attachAuthInterceptor();
      unawaited(inputLanguageService.initialize());

      // ✅ ИСПРАВЛЕНИЕ: Подписка на изменения аутентификации
      // При logout (user == null) отключаем socket
      // При login (user != null) инициализируем socket
      _authSub = authService.authStream.listen((user) async {
        debugPrint('Auth stream event: user=${user?.email}');
        if (user == null) {
          // Пользователь вышел — отключаем socket
          await disconnectSocket();
          _lastPlayedMessageId = null;
          activeChatIdNotifier.value = null;
          await refreshUserPreferences();
          _updateSubscriptionUiState();
          _showAuthScreen();
        } else {
          _handlingAuthFailure = false;
          // Пользователь вошёл — инициализируем socket
          try {
            await _initSocket();
          } catch (e) {
            debugPrint('Failed to init socket after login: $e');
          }
          await refreshUserPreferences();
          _updateSubscriptionUiState();
        }
      });
      _restartSubscriptionProbe();

      await refreshUserPreferences();
      unawaited(_prepareAppSoundPlayer());
    } catch (e, st) {
      debugPrint('Error attaching interceptor: $e\n$st');
    }

    setState(() => _status = 'Инициализация: проверка БД');
    final dbReady = await ensureDatabaseExists();

    setState(() => _status = 'Инициализация: определение стартового экрана');
    final initial = await determineInitialScreen(
      dbReady,
    ).timeout(const Duration(seconds: 25), onTimeout: () => const AuthScreen());
    _updateSubscriptionUiState();
    await refreshUserPreferences();

    debugPrint(
      'DiagnosticBootstrap: initial widget determined: ${initial.runtimeType}',
    );
    if (!mounted) return;
    setState(() {
      _home = initial;
      _status = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_home == null) {
      return AnimatedBuilder(
        animation: Listenable.merge([
          themeModeNotifier,
          performanceModeNotifier,
          themeStyleVersionNotifier,
        ]),
        builder: (context, _) {
          final mode = themeModeNotifier.value;
          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Проект Феникс (diag)',
            themeMode: mode,
            themeAnimationDuration: performanceModeNotifier.value
                ? Duration.zero
                : const Duration(milliseconds: 220),
            theme: _buildLightTheme(),
            darkTheme: _buildDarkTheme(),
            home: Scaffold(
              appBar: AppBar(title: const Text('Загрузка...')),
              body: PhoenixLoadingView(
                title: 'Проект Феникс запускается',
                subtitle: _status ?? 'Подготавливаем приложение',
              ),
            ),
            builder: (context, child) {
              return _wrapAppRoot(context, child ?? const SizedBox.shrink());
            },
          );
        },
      );
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        themeModeNotifier,
        performanceModeNotifier,
        themeStyleVersionNotifier,
      ]),
      builder: (context, _) {
        final mode = themeModeNotifier.value;
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Проект Феникс',
          themeMode: mode,
          themeAnimationDuration: performanceModeNotifier.value
              ? Duration.zero
              : const Duration(milliseconds: 220),
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          home: _home,
          routes: {
            '/auth': (_) => const AuthScreen(),
            '/phone_name': (_) => const PhoneNameScreen(isRegisterFlow: false),
            '/main': (_) => const MainShell(),
          },
          builder: (context, child) {
            return _wrapAppRoot(context, child ?? const SizedBox.shrink());
          },
        );
      },
    );
  }
}

class SetupFailedScreen extends StatelessWidget {
  const SetupFailedScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = _lastConnectivityHint.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('Ошибка инициализации')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Не удалось инициализировать базу данных на сервере.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Текущий API: $_runtimeApiBaseUrl',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(hint, style: theme.textTheme.bodySmall),
                ),
              ],
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  final ok = await ensureDatabaseExists();
                  if (!context.mounted) return;
                  if (ok) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const AuthScreen()),
                    );
                  } else {
                    showAppNotice(
                      context,
                      'Попытка подключения провалилась',
                      tone: AppNoticeTone.error,
                    );
                  }
                },
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
