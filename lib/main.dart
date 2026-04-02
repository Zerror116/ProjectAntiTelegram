// lib/main.dart
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';

import 'screens/auth_screen.dart';
import 'screens/phone_access_pending_screen.dart';
import 'screens/phone_name_screen.dart';
import 'screens/main_shell.dart';
import 'services/auth_service.dart';
import 'services/input_language_service.dart';
import 'services/native_update_installer.dart';
import 'services/offline_purchase_queue_service.dart';
import 'services/web_notification_service.dart';
import 'services/web_push_client_service.dart';
import 'theme/app_theme.dart';
import 'widgets/phoenix_loader.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
const String _rawApiBaseUrl = String.fromEnvironment(
  'FENIX_API_BASE_URL',
  defaultValue: '',
);
final String _initialApiBaseUrl = _resolveApiBaseUrl(_rawApiBaseUrl);
String _runtimeApiBaseUrl = _initialApiBaseUrl;
final Dio dio = Dio(
  BaseOptions(
    baseUrl: _runtimeApiBaseUrl,
    connectTimeout: Duration(seconds: kIsWeb ? 15 : 10),
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
final ValueNotifier<PhoneAccessOwnerRequest?> phoneAccessOwnerRequestNotifier =
    ValueNotifier<PhoneAccessOwnerRequest?>(null);
final OfflinePurchaseQueueService offlinePurchaseQueueService =
    OfflinePurchaseQueueService();

const _notificationsPrefPrefix = 'notifications_enabled_';
const _themePrefPrefix = 'theme_mode_dark_';
const _uiDensityPrefPrefix = 'ui_density_';
const _uiCardSizePrefPrefix = 'ui_card_size_';
const _performanceModePrefPrefix = 'performance_mode_';
String? _lastPlayedMessageId;
bool _handlingAuthFailure = false;
String? _activePhoneAccessDialogRequestId;
final AudioPlayer _appSoundPlayer = AudioPlayer();
bool _appSoundPlayerPrepared = false;
bool _socketInitInProgress = false;
String? _socketBoundUserId;
String? _socketBoundViewRole;
String _lastConnectivityHint = '';
bool _keyboardAssertRecoveredRecently = false;
Timer? _webPushBadgeSyncTimer;
const bool _verboseSocketLogs = bool.fromEnvironment(
  'FENIX_VERBOSE_SOCKET_LOGS',
  defaultValue: false,
);

void _socketVerboseLog(String message) {
  if (kDebugMode && _verboseSocketLogs) {
    debugPrint(message);
  }
}

enum AppNoticeTone { info, success, warning, error }

enum AppUiSound { tap, sent, incoming, success, warning }

class _AppUpdateVersion {
  final String version;
  final int build;

  const _AppUpdateVersion({required this.version, required this.build});

  String get token => '$version+$build';
}

class _AppUpdateInfo {
  final bool required;
  final String title;
  final String? message;
  final String? downloadUrl;
  final String platform;
  final _AppUpdateVersion current;
  final _AppUpdateVersion latest;
  final _AppUpdateVersion? minSupported;

  const _AppUpdateInfo({
    required this.required,
    required this.title,
    required this.message,
    required this.downloadUrl,
    required this.platform,
    required this.current,
    required this.latest,
    required this.minSupported,
  });
}

class PhoneAccessOwnerRequest {
  final String id;
  final String requesterName;
  final String requesterEmail;
  final String requesterUserId;
  final String phone;
  final String? requestedAt;

  const PhoneAccessOwnerRequest({
    required this.id,
    required this.requesterName,
    required this.requesterEmail,
    required this.requesterUserId,
    required this.phone,
    required this.requestedAt,
  });

  String get requesterLabel {
    final name = requesterName.trim();
    if (name.isNotEmpty) return name;
    final email = requesterEmail.trim();
    if (email.isNotEmpty) return email;
    return 'пользователь';
  }
}

PhoneAccessOwnerRequest? _parsePhoneAccessOwnerRequest(dynamic data) {
  if (data is! Map) return null;
  final map = Map<String, dynamic>.from(data);
  final requestId = (map['request_id'] ?? map['id'] ?? '').toString().trim();
  if (requestId.isEmpty) return null;
  return PhoneAccessOwnerRequest(
    id: requestId,
    requesterName: (map['requester_name'] ?? '').toString().trim(),
    requesterEmail: (map['requester_email'] ?? '').toString().trim(),
    requesterUserId: (map['requester_user_id'] ?? '').toString().trim(),
    phone: (map['phone'] ?? '').toString().trim(),
    requestedAt: (map['requested_at'] ?? '').toString().trim().isEmpty
        ? null
        : (map['requested_at'] ?? '').toString().trim(),
  );
}

Map<String, dynamic> _phoneAccessRequestToEventMap(
  PhoneAccessOwnerRequest request,
) {
  return <String, dynamic>{
    'request_id': request.id,
    'requester_name': request.requesterName,
    'requester_email': request.requesterEmail,
    'requester_user_id': request.requesterUserId,
    'phone': request.phone,
    'requested_at': request.requestedAt,
  };
}

String _defaultApiBaseUrl() {
  const nativeDebugFallback = 'http://127.0.0.1:3000';
  const nativeReleaseFallback = String.fromEnvironment(
    'FENIX_NATIVE_RELEASE_API_BASE_URL',
    defaultValue: 'https://garphoenix.com',
  );
  if (!kIsWeb) {
    return kReleaseMode ? nativeReleaseFallback : nativeDebugFallback;
  }

  final base = Uri.base;
  final scheme = base.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return nativeDebugFallback;
  }

  final host = base.host.trim();
  if (host.isEmpty) return nativeDebugFallback;

  final portPart = base.hasPort ? ':${base.port}' : '';
  return '$scheme://$host$portPart';
}

bool _hasIncomingAuthActionFromUri() {
  if (!kIsWeb) return false;
  try {
    final uri = Uri.base;
    final action = (uri.queryParameters['auth_action'] ?? '').trim();
    final token = (uri.queryParameters['token'] ?? '').trim();
    if (action.isNotEmpty && token.isNotEmpty) return true;
    if (uri.fragment.isNotEmpty) {
      final fragment = uri.fragment;
      final qIndex = fragment.indexOf('?');
      if (qIndex >= 0 && qIndex + 1 < fragment.length) {
        final inFragment = Uri.splitQueryString(fragment.substring(qIndex + 1));
        return (inFragment['auth_action'] ?? '').trim().isNotEmpty &&
            (inFragment['token'] ?? '').trim().isNotEmpty;
      }
    }
  } catch (_) {}
  return false;
}

String _resolveApiBaseUrl(String raw) {
  final fallback = _defaultApiBaseUrl();
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

@visibleForTesting
void debugSetApiBaseUrlForTesting(String next) {
  _setRuntimeApiBaseUrl(next);
}

@visibleForTesting
String debugGetApiBaseUrlForTesting() {
  return _runtimeApiBaseUrl;
}

bool _isAuthServiceInitialized() {
  try {
    authService;
    return true;
  } catch (_) {
    return false;
  }
}

@visibleForTesting
void debugEnsureAuthServiceForTesting() {
  if (_isAuthServiceInitialized()) return;
  authService = AuthService(dio: dio);
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

Duration _bootstrapRetryDelay(int attemptIndex) {
  final clamped = attemptIndex.clamp(0, 4);
  return Duration(milliseconds: 900 + (clamped * 1200));
}

bool _isLoopbackApiBase(String base) {
  final uri = Uri.tryParse(base);
  final host = (uri?.host ?? '').toLowerCase().trim();
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '0.0.0.0';
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

class _SupportQueueNoticePayload {
  final String ticketId;
  final String? chatId;
  final String subject;
  final String category;
  final String customerName;
  final String? productTitle;
  final String status;
  final bool claimable;
  final bool closable;

  const _SupportQueueNoticePayload({
    required this.ticketId,
    required this.chatId,
    required this.subject,
    required this.category,
    required this.customerName,
    required this.productTitle,
    required this.status,
    required this.claimable,
    required this.closable,
  });
}

final ValueNotifier<List<_SupportQueueNoticePayload>> _supportQueueNoticeNotifier =
    ValueNotifier<List<_SupportQueueNoticePayload>>(const []);
final ValueNotifier<Set<String>> _supportQueueClaimBusyNotifier =
    ValueNotifier<Set<String>>(<String>{});
final ValueNotifier<String> activeShellSectionNotifier = ValueNotifier<String>(
  '',
);

bool _canCurrentUserObserveSupportQueueAlerts() {
  final user = authService.currentUser;
  if (user == null) return false;
  final baseRole = user.role.toLowerCase().trim();
  final role = authService.effectiveRole.toLowerCase().trim();
  if (role == 'client') return false;
  if (baseRole == 'creator' || role == 'creator') return true;
  if (role == 'admin' || role == 'tenant') return true;
  if (role == 'worker') {
    return authService.hasPermission('chat.write.support');
  }
  return false;
}

bool _canCurrentUserClaimSupportQueueAlerts() {
  final user = authService.currentUser;
  if (user == null) return false;
  final baseRole = user.role.toLowerCase().trim();
  if (baseRole == 'creator') return false;
  final role = authService.effectiveRole.toLowerCase().trim();
  if (role == 'creator' || role == 'client') return false;
  if (role == 'admin' || role == 'tenant') return true;
  if (role == 'worker') {
    return authService.hasPermission('chat.write.support');
  }
  return false;
}

bool _canCurrentUserForceCloseSupportQueueAlerts() {
  return _canCurrentUserClaimSupportQueueAlerts();
}

_SupportQueueNoticePayload? _parseSupportQueueNotice(dynamic raw) {
  if (raw is! Map) return null;
  final map = Map<String, dynamic>.from(raw);
  final ticketId = (map['id'] ?? map['ticket_id'] ?? '').toString().trim();
  final chatIdRaw = (map['chat_id'] ?? '').toString().trim();
  if (ticketId.isEmpty) return null;
  final subject = (map['subject'] ?? 'Новый вопрос в поддержку')
      .toString()
      .trim();
  final customerName = (map['customer_name'] ?? 'Клиент').toString().trim();
  final category = (map['category'] ?? 'general').toString().trim();
  final productTitle = (map['product_title'] ?? '').toString().trim();
  final status = (map['status'] ?? 'open').toString().trim().toLowerCase();
  final claimable = (map['claimable'] ?? map['assignee_id'] == null) == true;
  return _SupportQueueNoticePayload(
    ticketId: ticketId,
    chatId: chatIdRaw.isEmpty ? null : chatIdRaw,
    subject: subject.isEmpty ? 'Новый вопрос в поддержку' : subject,
    category: category.isEmpty ? 'general' : category,
    customerName: customerName.isEmpty ? 'Клиент' : customerName,
    productTitle: productTitle.isEmpty ? null : productTitle,
    status: status.isEmpty ? 'open' : status,
    claimable: claimable,
    closable: false,
  );
}

_SupportQueueNoticePayload? _parseAssignedSupportNotice(dynamic raw) {
  if (raw is! Map) return null;
  final map = Map<String, dynamic>.from(raw);
  final ticketId = (map['id'] ?? '').toString().trim();
  if (ticketId.isEmpty) return null;
  final status = (map['status'] ?? '').toString().trim().toLowerCase();
  if (status.isEmpty || status == 'archived') return null;
  final subject = (map['subject'] ?? 'Вопрос в поддержку').toString().trim();
  final category = (map['category'] ?? 'general').toString().trim();
  final customerName = (map['customer_name'] ?? 'Клиент').toString().trim();
  final productTitle = (map['product_title'] ?? '').toString().trim();
  final chatId = (map['chat_id'] ?? '').toString().trim();
  return _SupportQueueNoticePayload(
    ticketId: ticketId,
    chatId: chatId.isEmpty ? null : chatId,
    subject: subject.isEmpty ? 'Вопрос в поддержку' : subject,
    category: category.isEmpty ? 'general' : category,
    customerName: customerName.isEmpty ? 'Клиент' : customerName,
    productTitle: productTitle.isEmpty ? null : productTitle,
    status: status,
    claimable: false,
    closable: true,
  );
}

void _clearSupportQueueNotices() {
  _supportQueueNoticeNotifier.value = const [];
  _supportQueueClaimBusyNotifier.value = <String>{};
}

void _upsertSupportQueueNotice(_SupportQueueNoticePayload notice) {
  final current = List<_SupportQueueNoticePayload>.from(
    _supportQueueNoticeNotifier.value,
  );
  final index = current.indexWhere((item) => item.ticketId == notice.ticketId);
  if (index >= 0) {
    current[index] = notice;
  } else {
    current.insert(0, notice);
  }
  _supportQueueNoticeNotifier.value = current;
}

void _removeSupportQueueNotice(String ticketId) {
  final id = ticketId.trim();
  if (id.isEmpty) return;
  _supportQueueNoticeNotifier.value = _supportQueueNoticeNotifier.value
      .where((item) => item.ticketId != id)
      .toList(growable: false);
  final busy = Set<String>.from(_supportQueueClaimBusyNotifier.value);
  busy.remove(id);
  _supportQueueClaimBusyNotifier.value = busy;
}

Future<void> _refreshSupportQueueNotices() async {
  if (!_canCurrentUserObserveSupportQueueAlerts()) {
    _clearSupportQueueNotices();
    return;
  }
  try {
    final nextById = <String, _SupportQueueNoticePayload>{};
    final canClaim = _canCurrentUserClaimSupportQueueAlerts();

    {
      final queueResp = await dio.get('/api/support/tickets/queue');
      final queueData = queueResp.data;
      final queueRows =
          queueData is Map && queueData['ok'] == true && queueData['data'] is List
          ? List<dynamic>.from(queueData['data'])
          : const <dynamic>[];
      for (final row in queueRows) {
        final parsed = _parseSupportQueueNotice(row);
        if (parsed != null) {
          nextById[parsed.ticketId] = parsed;
        }
      }
    }

    if (canClaim) {
      final activeResp = await dio.get(
        '/api/support/tickets',
        queryParameters: {'status': 'open,waiting_customer,resolved'},
      );
      final activeData = activeResp.data;
      final activeRows =
          activeData is Map &&
              activeData['ok'] == true &&
              activeData['data'] is List
          ? List<dynamic>.from(activeData['data'])
          : const <dynamic>[];
      for (final row in activeRows) {
        final parsed = _parseAssignedSupportNotice(row);
        if (parsed != null) {
          nextById[parsed.ticketId] = parsed;
        }
      }
    }

    final next = nextById.values.toList(growable: false)
      ..sort((a, b) {
        final closableOrder = (b.closable ? 1 : 0).compareTo(
          a.closable ? 1 : 0,
        );
        if (closableOrder != 0) return closableOrder;
        final claimableOrder = (b.claimable ? 1 : 0).compareTo(
          a.claimable ? 1 : 0,
        );
        if (claimableOrder != 0) return claimableOrder;
        return a.ticketId.compareTo(b.ticketId);
      });
    _supportQueueNoticeNotifier.value = next;
  } on DioException catch (e) {
    if (e.response?.statusCode == 403 || e.response?.statusCode == 401) {
      _clearSupportQueueNotices();
      return;
    }
  } catch (_) {}
}

Future<void> refreshSupportQueueNotices() async {
  await _refreshSupportQueueNotices();
}

Future<void> _claimSupportQueueNotice(String ticketId) async {
  final id = ticketId.trim();
  if (id.isEmpty) return;
  if (!_canCurrentUserClaimSupportQueueAlerts()) {
    showGlobalAppNotice(
      'Эти заявки доступны для принятия только администраторам поддержки.',
      title: 'Поддержка',
      tone: AppNoticeTone.info,
    );
    return;
  }
  final busy = Set<String>.from(_supportQueueClaimBusyNotifier.value);
  if (busy.contains(id)) return;
  busy.add(id);
  _supportQueueClaimBusyNotifier.value = busy;
  try {
    await dio.post('/api/support/tickets/$id/claim');
    _removeSupportQueueNotice(id);
    showGlobalAppNotice(
      'Заявка поддержки принята. Теперь этот чат виден только вам.',
      title: 'Поддержка',
      tone: AppNoticeTone.success,
    );
    chatEventsController.add({
      'type': 'support:queue:changed',
      'data': {'ticket_id': id, 'action': 'claimed'},
    });
  } on DioException catch (e) {
    final message = _extractApiErrorMessage(e);
    showGlobalAppNotice(
      message.isNotEmpty ? message : 'Не удалось принять заявку',
      title: 'Поддержка',
      tone: AppNoticeTone.error,
    );
  } catch (_) {
    showGlobalAppNotice(
      'Не удалось принять заявку',
      title: 'Поддержка',
      tone: AppNoticeTone.error,
    );
  } finally {
    final nextBusy = Set<String>.from(_supportQueueClaimBusyNotifier.value);
    nextBusy.remove(id);
    _supportQueueClaimBusyNotifier.value = nextBusy;
    unawaited(_refreshSupportQueueNotices());
  }
}

Future<void> _closeSupportQueueNotice(String ticketId) async {
  final id = ticketId.trim();
  if (id.isEmpty) return;
  final busy = Set<String>.from(_supportQueueClaimBusyNotifier.value);
  if (busy.contains(id)) return;
  busy.add(id);
  _supportQueueClaimBusyNotifier.value = busy;
  try {
    await dio.post(
      '/api/support/tickets/$id/archive',
      data: {'force': true, 'reason': 'forced_admin_archive'},
    );
    _removeSupportQueueNotice(id);
    showGlobalAppNotice(
      'Диалог закончен',
      title: 'Поддержка',
      tone: AppNoticeTone.success,
    );
    chatEventsController.add({
      'type': 'support:queue:changed',
      'data': {'ticket_id': id, 'action': 'archived'},
    });
  } on DioException catch (e) {
    final message = _extractApiErrorMessage(e);
    showGlobalAppNotice(
      message.isNotEmpty ? message : 'Не удалось завершить заявку',
      title: 'Поддержка',
      tone: AppNoticeTone.error,
    );
  } catch (_) {
    showGlobalAppNotice(
      'Не удалось завершить заявку',
      title: 'Поддержка',
      tone: AppNoticeTone.error,
    );
  } finally {
    final nextBusy = Set<String>.from(_supportQueueClaimBusyNotifier.value);
    nextBusy.remove(id);
    _supportQueueClaimBusyNotifier.value = nextBusy;
    unawaited(_refreshSupportQueueNotices());
  }
}

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

bool _isPhoneAccessRestrictedState(String state) {
  final normalized = state.toLowerCase().trim();
  return normalized == 'pending' || normalized == 'rejected';
}

bool _isDuplicateKeyDownKeyboardAssert(Object error) {
  final text = error.toString();
  return text.contains(
        'A KeyDownEvent is dispatched, but the state shows that the physical key is already pressed',
      ) ||
      text.contains("hardware_keyboard.dart': Failed assertion: line 516");
}

Future<void> _handlePhoneAccessRequestEvent(dynamic data) async {
  final request = _parsePhoneAccessOwnerRequest(data);
  if (request == null) return;
  final requestId = request.id;
  phoneAccessOwnerRequestNotifier.value = request;
  if (_activePhoneAccessDialogRequestId == requestId) return;

  final requesterLabel = request.requesterLabel;
  showGlobalAppNotice(
    'Новый запрос на общий доступ к корзине ($requesterLabel)',
    title: 'Подтверждение номера',
    tone: AppNoticeTone.warning,
  );

  final context = navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  _activePhoneAccessDialogRequestId = requestId;
  try {
    final decision = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Запрос на общий номер'),
          content: Text(
            'Пользователь "$requesterLabel" хочет зарегистрироваться на ваш номер'
            '${request.phone.isNotEmpty ? ' (${request.phone})' : ''}.\n\n'
            'Разрешить доступ к вашей корзине?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('reject'),
              child: const Text('Отклонить'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('approve'),
              child: const Text('Разрешить'),
            ),
          ],
        );
      },
    );
    if (decision == null) return;
    await submitPhoneAccessOwnerDecision(
      requestId,
      approve: decision == 'approve',
    );
  } on DioException catch (e) {
    final body = e.response?.data;
    final map = body is Map ? Map<String, dynamic>.from(body) : null;
    final message = (map?['error'] ?? e.message ?? 'Ошибка решения запроса')
        .toString()
        .trim();
    showGlobalAppNotice(
      message.isEmpty ? 'Ошибка решения запроса' : message,
      title: 'Подтверждение номера',
      tone: AppNoticeTone.error,
    );
  } catch (_) {
    showGlobalAppNotice(
      'Ошибка решения запроса',
      title: 'Подтверждение номера',
      tone: AppNoticeTone.error,
    );
  } finally {
    _activePhoneAccessDialogRequestId = null;
  }
}

Future<bool> submitPhoneAccessOwnerDecision(
  String requestId, {
  required bool approve,
}) async {
  final id = requestId.trim();
  if (id.isEmpty) return false;
  try {
    await dio.post(
      '/api/auth/phone-access/requests/$id/decision',
      data: {'decision': approve ? 'approve' : 'reject'},
    );
    phoneAccessOwnerRequestNotifier.value = null;
    showGlobalAppNotice(
      approve ? 'Доступ к корзине разрешён' : 'Запрос отклонён',
      title: 'Подтверждение номера',
      tone: approve ? AppNoticeTone.success : AppNoticeTone.info,
    );
    await _probePendingPhoneAccessRequests();
    return true;
  } on DioException catch (e) {
    final body = e.response?.data;
    final map = body is Map ? Map<String, dynamic>.from(body) : null;
    final message = (map?['error'] ?? e.message ?? 'Ошибка решения запроса')
        .toString()
        .trim();
    showGlobalAppNotice(
      message.isEmpty ? 'Ошибка решения запроса' : message,
      title: 'Подтверждение номера',
      tone: AppNoticeTone.error,
    );
  } catch (_) {
    showGlobalAppNotice(
      'Ошибка решения запроса',
      title: 'Подтверждение номера',
      tone: AppNoticeTone.error,
    );
  }
  return false;
}

void _handleCreatorAlertEvent(dynamic data) {
  if (data is! Map) return;
  final map = Map<String, dynamic>.from(data);
  final type = (map['type'] ?? '').toString().trim().toLowerCase();
  final tenantId = (map['tenant_id'] ?? '').toString().trim();
  final userId = (map['user_id'] ?? '').toString().trim();
  final reason = (map['reason'] ?? '').toString().trim();
  final source = (map['source'] ?? '').toString().trim();

  String title = 'Системный алерт';
  String message;
  AppNoticeTone tone = AppNoticeTone.warning;

  if (type == 'client_auto_deleted') {
    title = 'Автоудаление клиента';
    message =
        'Клиент удален автоматически${tenantId.isNotEmpty ? ' (tenant: $tenantId)' : ''}'
        '${userId.isNotEmpty ? ', user: $userId' : ''}.'
        '${reason.isNotEmpty ? ' Причина: $reason.' : ''}'
        '${source.isNotEmpty ? ' Источник: $source.' : ''}';
    tone = AppNoticeTone.error;
  } else if (type == 'cart_auto_dismantled_inactive') {
    title = 'Авторасформировка корзины';
    message =
        'Корзина расформирована по неактивности 30 дней'
        '${tenantId.isNotEmpty ? ' (tenant: $tenantId)' : ''}'
        '${userId.isNotEmpty ? ', user: $userId' : ''}.';
    tone = AppNoticeTone.warning;
  } else {
    message = map['message']?.toString().trim().isNotEmpty == true
        ? map['message'].toString().trim()
        : 'Получен системный алерт';
  }

  showGlobalAppNotice(
    message,
    title: title,
    tone: tone,
    duration: const Duration(seconds: 8),
  );
}

Future<void> _probePendingPhoneAccessRequests() async {
  try {
    final user = authService.currentUser;
    if (user == null) {
      phoneAccessOwnerRequestNotifier.value = null;
      return;
    }
    final resp = await dio.get('/api/auth/phone-access/requests');
    final root = resp.data is Map
        ? Map<String, dynamic>.from(resp.data as Map)
        : const <String, dynamic>{};
    final data = root['data'];
    if (data is! List || data.isEmpty) {
      phoneAccessOwnerRequestNotifier.value = null;
      return;
    }
    final firstRaw = data.first;
    if (firstRaw is! Map) {
      phoneAccessOwnerRequestNotifier.value = null;
      return;
    }
    final first = Map<String, dynamic>.from(firstRaw);
    final request = _parsePhoneAccessOwnerRequest(first);
    if (request == null) {
      phoneAccessOwnerRequestNotifier.value = null;
      return;
    }

    final previousId = phoneAccessOwnerRequestNotifier.value?.id;
    phoneAccessOwnerRequestNotifier.value = request;

    final shouldOpenDialog = previousId == null || previousId != request.id;
    if (!shouldOpenDialog) return;
    await _handlePhoneAccessRequestEvent(
      _phoneAccessRequestToEventMap(request),
    );
  } catch (_) {
    // ignore
  }
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

int _safePositiveInt(dynamic raw, {int fallback = 0}) {
  final parsed = int.tryParse((raw ?? '').toString().trim());
  if (parsed == null || parsed < 0) return fallback;
  return parsed;
}

bool _toBool(dynamic raw, {bool fallback = false}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  final normalized = raw.toString().toLowerCase().trim();
  if (normalized.isEmpty) return fallback;
  return normalized == 'true' ||
      normalized == '1' ||
      normalized == 'yes' ||
      normalized == 'on';
}

String _normalizeVersion(String raw) {
  final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
  return cleaned.isEmpty ? '0.0.0' : cleaned;
}

List<String> _splitVersionParts(String version) {
  return _normalizeVersion(version).split('.');
}

int _versionPartToInt(String part) {
  final digits = part.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return 0;
  return int.tryParse(digits) ?? 0;
}

int _compareVersionOnly(String a, String b) {
  final left = _splitVersionParts(a);
  final right = _splitVersionParts(b);
  final maxLen = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < maxLen; i++) {
    final li = i < left.length ? _versionPartToInt(left[i]) : 0;
    final ri = i < right.length ? _versionPartToInt(right[i]) : 0;
    if (li != ri) return li.compareTo(ri);
  }
  return 0;
}

int _compareVersionWithBuild(_AppUpdateVersion a, _AppUpdateVersion b) {
  final versionCmp = _compareVersionOnly(a.version, b.version);
  if (versionCmp != 0) return versionCmp;
  return a.build.compareTo(b.build);
}

String? _resolveAppUpdatePlatform() {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.android) return 'android';
  if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
  if (defaultTargetPlatform == TargetPlatform.windows) return 'windows';
  if (defaultTargetPlatform == TargetPlatform.macOS) return 'macos';
  return null;
}

bool _nativeDesktopUpdateBusy = false;
bool _nativeAndroidUpdateBusy = false;

Uri? _resolveUpdateUri(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return null;

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;

  Uri uri = parsed;
  if (!parsed.hasScheme) {
    final base = Uri.tryParse(dio.options.baseUrl.trim());
    if (base != null && base.hasScheme && base.host.isNotEmpty) {
      uri = base.resolveUri(parsed);
    }
  }
  return uri;
}

String _fallbackInstallerNameForPlatform(
  String platform,
  _AppUpdateVersion latest,
) {
  final suffix = '${latest.version}+${latest.build}'.replaceAll('+', '-');
  if (platform == 'android') return 'projectphoenix-$suffix.apk';
  if (platform == 'windows') return 'projectphoenix-$suffix.exe';
  if (platform == 'macos') return 'projectphoenix-$suffix.dmg';
  return 'projectphoenix-update-$suffix.bin';
}

Future<bool> _downloadAndInstallAndroidUpdate({
  required Uri uri,
  required _AppUpdateVersion latest,
}) async {
  if (_nativeAndroidUpdateBusy) {
    showGlobalAppNotice(
      'Обновление уже скачивается. Дождитесь завершения текущей загрузки.',
      title: 'Обновление Феникс',
      tone: AppNoticeTone.info,
    );
    return true;
  }

  _nativeAndroidUpdateBusy = true;
  final progress = ValueNotifier<double?>(null);
  final stage = ValueNotifier<String>('Запускаем системную загрузку Android...');
  BuildContext? dialogContext;
  final context = navigatorKey.currentContext;

  if (context != null && context.mounted) {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogContext = ctx;
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Обновление Феникс'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: ValueListenableBuilder<String>(
                  valueListenable: stage,
                  builder: (context, stageText, _) {
                    return ValueListenableBuilder<double?>(
                      valueListenable: progress,
                      builder: (context, value, child) {
                        final percentText = value == null
                            ? 'Подождите, это может занять до пары минут.'
                            : '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%';
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(stageText),
                            const SizedBox(height: 12),
                            LinearProgressIndicator(value: value),
                            const SizedBox(height: 12),
                            Text(
                              percentText,
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  try {
    var notificationsAllowed = false;
    try {
      stage.value = 'Проверяем системные уведомления Android...';
      notificationsAllowed = await NativeUpdateInstaller.canPostNotifications();
      if (!notificationsAllowed) {
        stage.value = 'Просим Android разрешить уведомления для загрузки...';
        notificationsAllowed =
            await NativeUpdateInstaller.requestNotificationPermission();
      }
    } catch (_) {
      notificationsAllowed = false;
    }
    if (!notificationsAllowed) {
      showGlobalAppNotice(
        'Обновление всё равно начнётся, но прогресс может не появиться в шторке Android, пока для Феникс не разрешены системные уведомления.',
        title: 'Обновление Феникс',
        tone: AppNoticeTone.warning,
        duration: const Duration(seconds: 6),
      );
    }

    final savePath = await NativeUpdateInstaller.downloadPackage(
      url: uri,
      fallbackFileName: _fallbackInstallerNameForPlatform('android', latest),
      headers: const {'X-Fenix-Platform': 'android'},
      onProgress: (received, total) {
        stage.value = 'Скачиваем обновление через систему Android...';
        if (total > 0) {
          progress.value = (received / total).clamp(0, 1).toDouble();
        } else {
          progress.value = null;
        }
      },
    );
    if (savePath == null || savePath.trim().isEmpty) {
      return false;
    }

    stage.value = 'Открываем установщик...';
    final opened = await NativeUpdateInstaller.openDownloadedPackage(savePath);
    if (opened) return true;

    stage.value = 'Установщик не открылся автоматически. Открываем Загрузки Android...';
    final openedDownloads = await NativeUpdateInstaller.openDownloadsUi();
    if (openedDownloads) {
      showGlobalAppNotice(
        'Обновление уже скачивается или скачано. Прогресс виден в системных загрузках Android.',
        title: 'Обновление Феникс',
        tone: AppNoticeTone.info,
        duration: const Duration(seconds: 5),
      );
      return true;
    }
    return false;
  } finally {
    if (dialogContext != null && dialogContext!.mounted) {
      Navigator.of(dialogContext!).pop();
    }
    progress.dispose();
    stage.dispose();
    _nativeAndroidUpdateBusy = false;
  }
}

Future<void> _downloadAndInstallDesktopUpdateInBackground({
  required String platform,
  required Uri uri,
  required _AppUpdateVersion latest,
}) async {
  if (_nativeDesktopUpdateBusy) {
    showGlobalAppNotice(
      'Обновление уже скачивается в фоне.',
      title: 'Обновление Феникс',
      tone: AppNoticeTone.info,
    );
    return;
  }
  _nativeDesktopUpdateBusy = true;
  showGlobalAppNotice(
    'Скачивание обновления началось в фоне. Мы откроем установщик после загрузки.',
    title: 'Обновление Феникс',
    tone: AppNoticeTone.info,
  );

  try {
    final savePath = await NativeUpdateInstaller.downloadPackage(
      url: uri,
      fallbackFileName: _fallbackInstallerNameForPlatform(platform, latest),
    );
    if (savePath == null || savePath.trim().isEmpty) {
      showGlobalAppNotice(
        'Не удалось скачать обновление. Проверьте сеть и повторите.',
        title: 'Обновление Феникс',
        tone: AppNoticeTone.error,
      );
      return;
    }
    final opened = await NativeUpdateInstaller.openDownloadedPackage(
      savePath,
      detached: true,
    );
    if (!opened) {
      showGlobalAppNotice(
        'Обновление скачано, но установщик не открылся автоматически.',
        title: 'Обновление Феникс',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    if (platform == 'windows' || platform == 'macos') {
      showGlobalAppNotice(
        'Установщик обновления запущен. Приложение закроется автоматически.',
        title: 'Обновление Феникс',
        tone: AppNoticeTone.success,
      );
      await NativeUpdateInstaller.exitCurrentAppForUpdate(
        delay: const Duration(milliseconds: 1600),
      );
      return;
    }
    showGlobalAppNotice(
      'Установщик обновления открыт.',
      title: 'Обновление Феникс',
      tone: AppNoticeTone.success,
    );
  } catch (e) {
    showGlobalAppNotice(
      'Ошибка фонового обновления: $e',
      title: 'Обновление Феникс',
      tone: AppNoticeTone.error,
    );
  } finally {
    _nativeDesktopUpdateBusy = false;
  }
}

Future<bool> _openUpdateUrl(
  String rawUrl, {
  required String platform,
  required _AppUpdateVersion latest,
}) async {
  final uri = _resolveUpdateUri(rawUrl);
  if (uri == null) return false;

  if (!kIsWeb && platform == 'android') {
    try {
      return await _downloadAndInstallAndroidUpdate(uri: uri, latest: latest);
    } catch (_) {
      return false;
    }
  }

  if (!kIsWeb && (platform == 'windows' || platform == 'macos')) {
    unawaited(
      _downloadAndInstallDesktopUpdateInBackground(
        platform: platform,
        uri: uri,
        latest: latest,
      ),
    );
    return true;
  }

  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<_AppUpdateInfo?> _fetchAppUpdateInfo() async {
  final platform = _resolveAppUpdatePlatform();
  if (platform == null) return null;

  final packageInfo = await PackageInfo.fromPlatform();
  final current = _AppUpdateVersion(
    version: _normalizeVersion(packageInfo.version),
    build: _safePositiveInt(packageInfo.buildNumber, fallback: 0),
  );

  final response = await dio.get(
    '/api/app/update',
    options: Options(
      sendTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
    ),
  );
  final root = response.data;
  if (root is! Map) return null;
  if (root['ok'] != true) return null;
  final data = root['data'];
  if (data is! Map) return null;
  final platformConfigRaw = data[platform];
  if (platformConfigRaw is! Map) return null;
  final platformConfig = Map<String, dynamic>.from(platformConfigRaw);
  if (!_toBool(platformConfig['enabled'], fallback: false)) return null;

  final latestVersionRaw = (platformConfig['latest_version'] ?? '')
      .toString()
      .trim();
  final latestBuildRaw = platformConfig['latest_build'];
  final latestVersion = _normalizeVersion(latestVersionRaw);
  final latestBuild = _safePositiveInt(latestBuildRaw, fallback: 0);
  final latest = _AppUpdateVersion(version: latestVersion, build: latestBuild);

  final minVersionRaw = (platformConfig['min_supported_version'] ?? '')
      .toString()
      .trim();
  final minBuildRaw = platformConfig['min_supported_build'];
  _AppUpdateVersion? minSupported;
  if (minVersionRaw.isNotEmpty || minBuildRaw != null) {
    minSupported = _AppUpdateVersion(
      version: _normalizeVersion(minVersionRaw),
      build: _safePositiveInt(minBuildRaw, fallback: 0),
    );
  }

  final hasLatestConfigured =
      latestVersionRaw.isNotEmpty || platformConfig['latest_build'] != null;
  if (!hasLatestConfigured && minSupported == null) return null;

  final isNewerThanCurrent = _compareVersionWithBuild(latest, current) > 0;
  final belowMinSupported =
      minSupported != null &&
      _compareVersionWithBuild(current, minSupported) < 0;
  final required =
      _toBool(platformConfig['required'], fallback: false) || belowMinSupported;

  if (!isNewerThanCurrent && !belowMinSupported) {
    return null;
  }

  final title = (platformConfig['title'] ?? '').toString().trim();
  final message = (platformConfig['message'] ?? '').toString().trim();
  final downloadUrl = (platformConfig['download_url'] ?? '').toString().trim();

  return _AppUpdateInfo(
    required: required,
    title: title.isNotEmpty ? title : 'Доступно обновление Феникс',
    message: message.isNotEmpty ? message : null,
    downloadUrl: downloadUrl.isNotEmpty ? downloadUrl : null,
    platform: platform,
    current: current,
    latest: latest,
    minSupported: minSupported,
  );
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

  String _supportCategoryLabel(String raw) {
    switch (raw.toLowerCase().trim()) {
      case 'product':
        return 'Товар';
      case 'delivery':
        return 'Доставка';
      case 'cart':
        return 'Корзина';
      default:
        return 'Общий';
    }
  }

  String _supportStatusLabel(String raw) {
    switch (raw.toLowerCase().trim()) {
      case 'waiting_customer':
        return 'Ждёт клиента';
      case 'resolved':
        return 'Ожидает закрытия';
      case 'open':
      default:
        return 'Открыт';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reducedMotion =
        performanceModeNotifier.value ||
        (MediaQuery.maybeOf(context)?.disableAnimations == true);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
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
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 760),
                              child: Material(
                                color: theme.colorScheme.surfaceContainerHigh,
                                elevation: 8,
                                borderRadius: BorderRadius.circular(16),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () => _appNoticeNotifier.value = null,
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
                                              padding: const EdgeInsets.only(
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
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
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
                                                                FontWeight.w700,
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
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: ValueListenableBuilder<String>(
              valueListenable: activeShellSectionNotifier,
              builder: (context, activeSection, _) {
                if (activeSection != 'chats') {
                  return const SizedBox.shrink();
                }
                final media = MediaQuery.of(context);
                final compact = media.size.width < 700;
                final maxCards = compact ? 1 : 3;
                final cardWidth = compact
                    ? (media.size.width - 24).clamp(260.0, 420.0)
                    : 380.0;
                return Padding(
                  padding: EdgeInsets.fromLTRB(12, compact ? 8 : 12, 12, 0),
                  child: ValueListenableBuilder<List<_SupportQueueNoticePayload>>(
                    valueListenable: _supportQueueNoticeNotifier,
                    builder: (context, notices, _) {
                      if (notices.isEmpty || !_canCurrentUserObserveSupportQueueAlerts()) {
                        return const SizedBox.shrink();
                      }
                      final canClaim = _canCurrentUserClaimSupportQueueAlerts();
                      final canForceClose = _canCurrentUserForceCloseSupportQueueAlerts();
                      return ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: cardWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ...notices.take(maxCards).map((notice) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: ValueListenableBuilder<Set<String>>(
                                  valueListenable: _supportQueueClaimBusyNotifier,
                                  builder: (context, busyIds, _) {
                                    final actionBusy = busyIds.contains(notice.ticketId);
                                    return Material(
                                      color: theme.colorScheme.surfaceContainerHigh,
                                      elevation: compact ? 6 : 10,
                                      borderRadius: BorderRadius.circular(compact ? 14 : 18),
                                      child: Container(
                                        width: cardWidth,
                                        padding: EdgeInsets.fromLTRB(
                                          compact ? 12 : 14,
                                          compact ? 12 : 14,
                                          compact ? 12 : 14,
                                          compact ? 12 : 14,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(compact ? 14 : 18),
                                          border: Border.all(
                                            color: theme.colorScheme.primary.withValues(alpha: 0.16),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  width: compact ? 32 : 38,
                                                  height: compact ? 32 : 38,
                                                  decoration: BoxDecoration(
                                                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                                    shape: BoxShape.circle,
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Icon(
                                                    Icons.support_agent_outlined,
                                                    color: theme.colorScheme.primary,
                                                    size: compact ? 18 : 20,
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        notice.claimable
                                                            ? 'Новый вопрос в поддержку'
                                                            : 'Активная заявка поддержки',
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: theme.textTheme.titleSmall?.copyWith(
                                                          fontWeight: FontWeight.w800,
                                                        ),
                                                      ),
                                                      Text(
                                                        'Клиент: ${notice.customerName}',
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: theme.textTheme.bodySmall?.copyWith(
                                                          color: theme.colorScheme.onSurfaceVariant,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 10),
                                            Text(
                                              notice.subject,
                                              maxLines: compact ? 2 : 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _SupportQueueChip(
                                                  label: _supportStatusLabel(notice.status),
                                                ),
                                                _SupportQueueChip(
                                                  label: _supportCategoryLabel(notice.category),
                                                ),
                                                if ((notice.productTitle ?? '').trim().isNotEmpty && !compact)
                                                  _SupportQueueChip(
                                                    label: notice.productTitle!.trim(),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 10),
                                            if ((canClaim && notice.claimable) ||
                                                notice.closable ||
                                                canForceClose)
                                              Align(
                                                alignment: Alignment.centerRight,
                                                child: Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  alignment: WrapAlignment.end,
                                                  children: [
                                                    if (canClaim && notice.claimable)
                                                      FilledButton.icon(
                                                        onPressed: actionBusy
                                                            ? null
                                                            : () => _claimSupportQueueNotice(notice.ticketId),
                                                        icon: actionBusy
                                                            ? const SizedBox(
                                                                width: 16,
                                                                height: 16,
                                                                child: CircularProgressIndicator(
                                                                  strokeWidth: 2,
                                                                ),
                                                              )
                                                            : const Icon(Icons.record_voice_over_outlined),
                                                        label: Text(
                                                          actionBusy ? 'Принимаем...' : 'Принять заявку',
                                                        ),
                                                      ),
                                                    if (notice.closable || canForceClose)
                                                      OutlinedButton.icon(
                                                        onPressed: actionBusy
                                                            ? null
                                                            : () => _closeSupportQueueNotice(notice.ticketId),
                                                        icon: actionBusy
                                                            ? const SizedBox(
                                                                width: 16,
                                                                height: 16,
                                                                child: CircularProgressIndicator(
                                                                  strokeWidth: 2,
                                                                ),
                                                              )
                                                            : const Icon(Icons.archive_outlined),
                                                        label: Text(
                                                          actionBusy ? 'Закрываем...' : 'Закрыть заявку',
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              )
                                            else
                                              Text(
                                                notice.claimable
                                                    ? 'Заявка исчезнет, когда её примет администратор.'
                                                    : 'Уведомление останется, пока заявка не будет закрыта.',
                                                style: theme.textTheme.bodySmall?.copyWith(
                                                  color: theme.colorScheme.onSurfaceVariant,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            }),
                            if (notices.length > maxCards)
                              Material(
                                color: theme.colorScheme.surfaceContainer,
                                elevation: 4,
                                borderRadius: BorderRadius.circular(14),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Text(
                                    'Ещё заявок: ${notices.length - maxCards}',
                                    style: theme.textTheme.labelLarge,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: _subscriptionWarningBottomOffset(context),
          child: ValueListenableBuilder<_SubscriptionUiPayload>(
            valueListenable: _subscriptionUiNotifier,
            builder: (context, state, _) {
              if (state.blocked || state.warningMessage == null) {
                return const SizedBox.shrink();
              }
              return IgnorePointer(
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
                          border: Border.all(color: theme.colorScheme.error),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: theme.colorScheme.onErrorContainer,
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
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onErrorContainer,
                                                  fontWeight: FontWeight.w700,
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
              );
            },
          ),
        ),
        Positioned.fill(
          child: ValueListenableBuilder<_SubscriptionUiPayload>(
            valueListenable: _subscriptionUiNotifier,
            builder: (context, state, _) {
              if (!state.blocked) return const SizedBox.shrink();
              return Material(
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
                          padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
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
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SupportQueueChip extends StatelessWidget {
  final String label;

  const _SupportQueueChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
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

  final chatId =
      (data is Map
              ? (data['chatId'] ?? message?['chat_id'] ?? message?['chatId'])
              : null)
          ?.toString();
  final activeChatId = activeChatIdNotifier.value;
  final documentHidden = kIsWeb && WebNotificationService.isDocumentHidden;
  if ((chatId?.isNotEmpty ?? false) &&
      activeChatId == chatId &&
      !documentHidden) {
    return;
  }

  unawaited(
    _maybeShowIncomingBrowserNotification(
      message: message,
      chatId: chatId,
      messageId: messageId,
    ),
  );

  await playAppSound(AppUiSound.incoming);

  final senderName = (message?['sender_name'] ?? '').toString().trim();
  final sender = senderName.isNotEmpty ? senderName : 'Новое сообщение';
  showGlobalAppNotice(
    _incomingMessagePreview(message),
    title: sender,
    tone: AppNoticeTone.info,
    duration: const Duration(seconds: 5),
  );
}

Future<void> _maybeShowIncomingBrowserNotification({
  required Map<String, dynamic>? message,
  required String? chatId,
  required String? messageId,
}) async {
  if (!kIsWeb) return;
  if (!notificationsEnabledNotifier.value) return;
  if (!WebNotificationService.isSupported) return;
  if (!WebNotificationService.isDocumentHidden) return;
  if ((chatId?.isNotEmpty ?? false) && activeChatIdNotifier.value == chatId) {
    return;
  }

  final permission = await WebNotificationService.getPermissionState();
  if (permission != WebNotificationPermissionState.granted) return;

  final senderName = (message?['sender_name'] ?? '').toString().trim();
  final sender = senderName.isNotEmpty ? senderName : 'Новое сообщение';
  await WebNotificationService.showSystemNotification(
    title: sender,
    body: _incomingMessagePreview(message),
    tag: (messageId?.isNotEmpty ?? false)
        ? 'message:$messageId'
        : ((chatId?.isNotEmpty ?? false) ? 'chat:$chatId' : 'incoming-message'),
  );
}

void _scheduleWebPushBadgeSync() {
  if (!kIsWeb) return;
  _webPushBadgeSyncTimer?.cancel();
  _webPushBadgeSyncTimer = Timer(const Duration(milliseconds: 900), () {
    unawaited(WebPushClientService.syncUnreadBadge(dio));
  });
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

Future<bool> ensureDatabaseExists({int attempts = 4}) async {
  final candidates = _buildApiBaseCandidates();
  Object? lastError;
  final totalAttempts = attempts < 1 ? 1 : attempts;

  for (var attemptIndex = 0; attemptIndex < totalAttempts; attemptIndex++) {
    for (final base in candidates) {
      _setRuntimeApiBaseUrl(base);
      try {
        debugPrint(
          'ensureDatabaseExists: attempt=${attemptIndex + 1}/$totalAttempts checking /health at $base',
        );
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

      if (_isLoopbackApiBase(base)) {
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
      } else {
        debugPrint(
          'ensureDatabaseExists: skip /api/setup for non-local base $base',
        );
      }

      _lastConnectivityHint = '';
    }

    if (attemptIndex < totalAttempts - 1) {
      final wait = _bootstrapRetryDelay(attemptIndex);
      debugPrint(
        'ensureDatabaseExists: all candidates failed on attempt ${attemptIndex + 1}, retry in ${wait.inMilliseconds}ms',
      );
      await Future.delayed(wait);
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

    final token = await authService.getToken();
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
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          .setAuth(socketAuth)
          .build(),
    );
    _socketBoundUserId = userId;
    _socketBoundViewRole = viewRole ?? '';

    socket?.on('connect', (_) {
      debugPrint('✅ Socket connected: ${socket?.id}');
      unawaited(_refreshSupportQueueNotices());
    });

    socket?.on('disconnect', (reason) {
      debugPrint('📡 Socket disconnected: $reason');
    });

    socket?.on('connect_error', (err) {
      debugPrint('❌ Socket connect_error: $err');
    });

    // Chat created -> notify listeners to reload chats
    socket?.on('chat:created', (data) {
      _socketVerboseLog('📬 Socket event chat:created -> $data');
      chatEventsController.add({'type': 'chat:created', 'data': data});
    });

    socket?.on('chat:deleted', (data) {
      _socketVerboseLog('📬 Socket event chat:deleted -> $data');
      chatEventsController.add({'type': 'chat:deleted', 'data': data});
    });

    socket?.on('chat:updated', (data) {
      _socketVerboseLog('📬 Socket event chat:updated -> $data');
      chatEventsController.add({'type': 'chat:updated', 'data': data});
    });

    socket?.on('chat:pinned', (data) {
      _socketVerboseLog('📬 Socket event chat:pinned -> $data');
      chatEventsController.add({'type': 'chat:pinned', 'data': data});
    });

    // New message -> notify listeners
    socket?.on('chat:message', (data) {
      _socketVerboseLog('📬 Socket event chat:message -> $data');
      chatEventsController.add({'type': 'chat:message', 'data': data});
      _scheduleWebPushBadgeSync();
      _maybePlayIncomingMessageSound(data);
    });

    socket?.on('chat:message:deleted', (data) {
      _socketVerboseLog('📬 Socket event chat:message:deleted -> $data');
      chatEventsController.add({'type': 'chat:message:deleted', 'data': data});
      _scheduleWebPushBadgeSync();
    });

    socket?.on('chat:cleared', (data) {
      _socketVerboseLog('📬 Socket event chat:cleared -> $data');
      chatEventsController.add({'type': 'chat:cleared', 'data': data});
      _scheduleWebPushBadgeSync();
    });

    socket?.on('chat:message:read', (data) {
      _socketVerboseLog('📬 Socket event chat:message:read -> $data');
      chatEventsController.add({'type': 'chat:message:read', 'data': data});
      _scheduleWebPushBadgeSync();
    });

    socket?.on('tenant:subscription:update', (data) {
      _socketVerboseLog('📬 Socket event tenant:subscription:update -> $data');
      _applySubscriptionSocketUpdate(data);
    });

    socket?.on('creator:alert', (data) {
      _socketVerboseLog('📬 Socket event creator:alert -> $data');
      _handleCreatorAlertEvent(data);
    });

    socket?.on('phone-access:request', (data) {
      _socketVerboseLog('📬 Socket event phone-access:request -> $data');
      unawaited(_handlePhoneAccessRequestEvent(data));
    });

    socket?.on('phone-access:updated', (data) {
      _socketVerboseLog('📬 Socket event phone-access:updated -> $data');
      unawaited(_probePendingPhoneAccessRequests());
    });

    socket?.on('phone-access:decision', (data) {
      _socketVerboseLog('📬 Socket event phone-access:decision -> $data');
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final status = (map?['status'] ?? '').toString().trim().toLowerCase();
      if (status == 'approved') {
        showGlobalAppNotice(
          'Владелец номера разрешил доступ к корзине',
          title: 'Подтверждение номера',
          tone: AppNoticeTone.success,
        );
      } else if (status == 'rejected') {
        showGlobalAppNotice(
          'Владелец номера отклонил запрос',
          title: 'Подтверждение номера',
          tone: AppNoticeTone.error,
        );
      }
      unawaited(_probePendingPhoneAccessRequests());
    });

    socket?.on('cart:updated', (data) {
      _socketVerboseLog('📬 Socket event cart:updated -> $data');
      chatEventsController.add({'type': 'cart:updated', 'data': data});
    });

    socket?.on('delivery:updated', (data) {
      _socketVerboseLog('📬 Socket event delivery:updated -> $data');
      chatEventsController.add({'type': 'delivery:updated', 'data': data});
    });

    socket?.on('claims:updated', (data) {
      _socketVerboseLog('📬 Socket event claims:updated -> $data');
      chatEventsController.add({'type': 'claims:updated', 'data': data});
    });

    socket?.on('support:ticket:queued', (data) {
      _socketVerboseLog('📬 Socket event support:ticket:queued -> $data');
      chatEventsController.add({'type': 'support:queue:changed', 'data': data});
      if (!_canCurrentUserObserveSupportQueueAlerts()) return;
      final payload = _parseSupportQueueNotice(data);
      if (payload == null) return;
      _upsertSupportQueueNotice(payload);
      showGlobalAppNotice(
        'Новый вопрос от ${payload.customerName}.',
        title: 'Поддержка ждёт ответа',
        tone: AppNoticeTone.warning,
        duration: const Duration(seconds: 4),
      );
      unawaited(playAppSound(AppUiSound.warning));
    });

    socket?.on('support:ticket:claimed', (data) {
      _socketVerboseLog('📬 Socket event support:ticket:claimed -> $data');
      chatEventsController.add({'type': 'support:queue:changed', 'data': data});
      unawaited(_refreshSupportQueueNotices());
    });

    // Global message event (optional)
    socket?.on('chat:message:global', (data) {
      _socketVerboseLog('📬 Socket event chat:message:global -> $data');
      chatEventsController.add({'type': 'chat:message:global', 'data': data});
      _scheduleWebPushBadgeSync();
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

Widget _buildInitialScreenFromRestoredUser(User? restoredUser) {
  if (restoredUser == null) {
    return const MainShell();
  }
  final name = restoredUser.name;
  final phone = restoredUser.phone;
  final phoneAccessState = (restoredUser.phoneAccessState ?? '')
      .trim()
      .toLowerCase();
  debugPrint(
    'determineInitialScreen: restored user name=$name phone=$phone',
  );
  if (_isPhoneAccessRestrictedState(phoneAccessState)) {
    return const PhoneAccessPendingScreen();
  }
  if (name == null || phone == null || phone.trim().isEmpty) {
    return const PhoneNameScreen(isRegisterFlow: false);
  }
  return const MainShell();
}

bool _restoredUserNeedsProfileCompletion(User? restoredUser) {
  if (restoredUser == null) return false;
  final phoneAccessState = (restoredUser.phoneAccessState ?? '')
      .trim()
      .toLowerCase();
  if (_isPhoneAccessRestrictedState(phoneAccessState)) {
    return false;
  }
  final name = (restoredUser.name ?? '').trim();
  final phone = (restoredUser.phone ?? '').trim();
  return name.isEmpty || phone.isEmpty;
}

Future<Widget> determineInitialScreen(bool dbReady) async {
  debugPrint('determineInitialScreen: dbReady=$dbReady');
  if (kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return const AuthScreen();
  }
  if (_hasIncomingAuthActionFromUri()) {
    debugPrint('determineInitialScreen: incoming auth action -> AuthScreen');
    return const AuthScreen();
  }
  if (!dbReady) return const SetupFailedScreen();

  final hasStoredToken = await authService.primeAuthHeaderFromStoredToken()
      .timeout(const Duration(seconds: 1), onTimeout: () => false);
  if (hasStoredToken && authService.currentUser != null) {
    final localUser = authService.currentUser;
    if (_restoredUserNeedsProfileCompletion(localUser)) {
      debugPrint(
        'determineInitialScreen: local session incomplete, waiting for fresh profile',
      );
      final refreshed = await authService.tryRefreshOnStartup().timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
      if (refreshed &&
          authService.currentUser != null &&
          !authService.lastStartupRefreshUsedFallback) {
        _handlingAuthFailure = false;
        return _buildInitialScreenFromRestoredUser(authService.currentUser);
      }
      debugPrint(
        'determineInitialScreen: incomplete local profile without fresh confirmation, fallback to MainShell',
      );
      _handlingAuthFailure = false;
      return const MainShell();
    }
    debugPrint(
      'determineInitialScreen: fast path via stored token -> local session',
    );
    unawaited(authService.tryRefreshOnStartup());
    _handlingAuthFailure = false;
    return _buildInitialScreenFromRestoredUser(localUser);
  }

  final logged = await authService.tryRefreshOnStartup().timeout(
    const Duration(seconds: 6),
    onTimeout: () {
      final restored = authService.currentUser != null;
      if (restored) {
        debugPrint(
          'determineInitialScreen: tryRefreshOnStartup timed out, using local session',
        );
      }
      return restored;
    },
  );
  debugPrint('determineInitialScreen: tryRefreshOnStartup -> $logged');

  if (logged) {
    _handlingAuthFailure = false;
  }

  if (!logged) {
    return const AuthScreen();
  }

  try {
    return _buildInitialScreenFromRestoredUser(authService.currentUser);
  } catch (e, st) {
    debugPrint('determineInitialScreen restored-user error: $e\n$st');
  }

  return const MainShell();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    try {
      await BrowserContextMenu.disableContextMenu();
    } catch (_) {}
  }

  FlutterError.onError = (FlutterErrorDetails details) {
    if (_isDuplicateKeyDownKeyboardAssert(details.exception)) {
      try {
        unawaited(HardwareKeyboard.instance.syncKeyboardState());
        if (!_keyboardAssertRecoveredRecently) {
          _keyboardAssertRecoveredRecently = true;
          debugPrint(
            'Recovered from duplicate KeyDownEvent assert by resetting HardwareKeyboard state.',
          );
          Future<void>.delayed(const Duration(seconds: 2), () {
            _keyboardAssertRecoveredRecently = false;
          });
        }
      } catch (_) {}
      return;
    }
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
  StreamSubscription<User?>? _authSub;
  Timer? _subscriptionProbeTimer;
  bool _subscriptionProbeBusy = false;
  Timer? _phoneAccessProbeTimer;
  bool _phoneAccessProbeBusy = false;
  Timer? _offlinePurchaseProbeTimer;
  bool _offlinePurchaseProbeBusy = false;
  Timer? _appUpdateProbeTimer;
  bool _appUpdateProbeBusy = false;
  bool _appUpdateDialogOpen = false;
  String? _dismissedUpdateToken;

  void _showAuthScreen() {
    if (!mounted) return;
    setState(() {
      _home = const AuthScreen();
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
    _phoneAccessProbeTimer?.cancel();
    _offlinePurchaseProbeTimer?.cancel();
    _appUpdateProbeTimer?.cancel();
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

  void _restartPhoneAccessProbe() {
    _phoneAccessProbeTimer?.cancel();
    _phoneAccessProbeTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(_probePhoneAccessOwnerRequests()),
    );
    unawaited(_probePhoneAccessOwnerRequests());
  }

  void _restartOfflinePurchaseProbe() {
    _offlinePurchaseProbeTimer?.cancel();
    _offlinePurchaseProbeTimer = Timer.periodic(
      const Duration(seconds: 7),
      (_) => unawaited(_probeOfflinePurchaseQueue()),
    );
    unawaited(_probeOfflinePurchaseQueue());
  }

  void _restartAppUpdateProbe() {
    _appUpdateProbeTimer?.cancel();
    _appUpdateProbeTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(_probeAppUpdate()),
    );
    unawaited(_probeAppUpdate());
  }

  Future<void> _showAppUpdateDialog(_AppUpdateInfo info) async {
    if (!mounted || _appUpdateDialogOpen) return;
    final context = navigatorKey.currentContext ?? this.context;
    if (!context.mounted) return;

    final updateToken = '${info.platform}:${info.latest.token}';
    _appUpdateDialogOpen = true;
    try {
      final decision = await showDialog<String>(
        context: context,
        barrierDismissible: !info.required,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          final currentLabel = '${info.current.version}+${info.current.build}';
          final latestLabel = '${info.latest.version}+${info.latest.build}';
          final platformLabel = info.platform == 'android'
              ? 'Android'
              : info.platform == 'ios'
              ? 'iOS'
              : info.platform == 'windows'
              ? 'Windows'
              : info.platform == 'macos'
              ? 'macOS'
              : info.platform;
          final minSupportedLabel = info.minSupported == null
              ? null
              : '${info.minSupported!.version}+${info.minSupported!.build}';
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
            backgroundColor: Colors.transparent,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF12D95B), Color(0xFF17C9C7)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF17C9C7).withValues(alpha: 0.24),
                      blurRadius: 28,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.20),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.system_update_alt_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              info.required
                                  ? 'Требуется обновление Феникс'
                                  : (info.title.isNotEmpty
                                        ? info.title
                                        : 'Доступно обновление Феникс'),
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Платформа: $platformLabel\n'
                        'Текущая версия: $currentLabel\n'
                        'Новая версия: $latestLabel',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.4,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (minSupportedLabel != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Минимально поддерживаемая: $minSupportedLabel',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.90),
                          ),
                        ),
                      ],
                      if ((info.message ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          info.message!.trim(),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                      if ((info.downloadUrl ?? '').trim().isEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Ссылка на обновление не настроена на сервере. Обратитесь к администратору.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (!info.required)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop('later'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Позже'),
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop('update'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF0F6667),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: const Icon(Icons.system_update_alt_rounded),
                          label: const Text('Обновить Феникс'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );

      if (decision == 'update') {
        final url = (info.downloadUrl ?? '').trim();
        if (url.isEmpty) {
          showGlobalAppNotice(
            'Ссылка на обновление не настроена на сервере.',
            title: 'Обновление Феникс',
            tone: AppNoticeTone.error,
          );
          return;
        }
        final opened = await _openUpdateUrl(
          url,
          platform: info.platform,
          latest: info.latest,
        );
        if (opened) {
          _dismissedUpdateToken = updateToken;
          final successMessage =
              info.platform == 'windows' || info.platform == 'macos'
              ? 'Обновление скачивается в фоне. После загрузки запустится установщик, и приложение закроется автоматически.'
              : info.platform == 'android'
              ? 'APK скачан. Если Android спросит разрешение, разрешите установку неизвестных приложений для Феникс.'
              : 'Открыта ссылка на обновление Феникс.';
          showGlobalAppNotice(
            successMessage,
            title: 'Обновление',
            tone: AppNoticeTone.success,
          );
        } else {
          final failedMessage = info.platform == 'android'
              ? 'Не удалось установить обновление. Проверьте разрешение '
                    '«Установка неизвестных приложений» для Феникс и повторите.'
              : 'Не удалось открыть ссылку обновления. Проверьте URL.';
          showGlobalAppNotice(
            failedMessage,
            title: 'Обновление Феникс',
            tone: AppNoticeTone.error,
          );
        }
      } else if (decision == 'later' && !info.required) {
        _dismissedUpdateToken = updateToken;
      }
    } finally {
      _appUpdateDialogOpen = false;
    }
  }

  Future<void> _probeAppUpdate() async {
    if (!mounted || _appUpdateProbeBusy || _appUpdateDialogOpen) return;
    _appUpdateProbeBusy = true;
    try {
      final info = await _fetchAppUpdateInfo();
      if (!mounted || info == null) return;
      final updateToken = '${info.platform}:${info.latest.token}';
      if (!info.required && _dismissedUpdateToken == updateToken) {
        return;
      }
      await _showAppUpdateDialog(info);
    } catch (_) {
      // ignore: отсутствие ответа не должно мешать работе приложения
    } finally {
      _appUpdateProbeBusy = false;
    }
  }

  Future<void> _probePhoneAccessOwnerRequests() async {
    if (!mounted || _phoneAccessProbeBusy) return;
    final user = authService.currentUser;
    if (user == null) return;
    _phoneAccessProbeBusy = true;
    try {
      await _probePendingPhoneAccessRequests();
    } catch (_) {
      // ignore
    } finally {
      _phoneAccessProbeBusy = false;
    }
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

  Future<void> _probeOfflinePurchaseQueue() async {
    if (!mounted || _offlinePurchaseProbeBusy) return;
    final user = authService.currentUser;
    if (user == null) return;

    _offlinePurchaseProbeBusy = true;
    try {
      final result = await offlinePurchaseQueueService.flushQueuedPurchases(
        dio: dio,
        userId: user.id,
        tenantCode: user.tenantCode,
      );
      if (result.confirmed > 0) {
        showGlobalAppNotice(
          'Оффлайн-покупки подтверждены: ${result.confirmed}',
          tone: AppNoticeTone.success,
          duration: const Duration(seconds: 2),
        );
      }
      if (result.rejected > 0) {
        final firstReason = result.events
            .where((e) => e.outcome == OfflinePurchaseSyncOutcome.rejected)
            .map((e) => e.message.trim())
            .firstWhere((msg) => msg.isNotEmpty, orElse: () => '');
        showGlobalAppNotice(
          firstReason.isNotEmpty
              ? 'Оффлайн-покупка отклонена: $firstReason'
              : 'Часть оффлайн-покупок отклонена: ${result.rejected}',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 3),
        );
      }
      if (result.confirmed > 0 || result.rejected > 0) {
        chatEventsController.add({
          'type': 'cart:offline-sync',
          'data': {
            'confirmed': result.confirmed,
            'rejected': result.rejected,
            'remaining': result.remaining,
          },
        });
      }
    } catch (_) {
      // ignore: service handles connection/runtime fallbacks
    } finally {
      _offlinePurchaseProbeBusy = false;
    }
  }

  Future<void> _startInit() async {
    try {
      authService = AuthService(dio: dio);
      _attachAuthInterceptor();
      unawaited(inputLanguageService.initialize());
      if (kIsWeb) {
        final hasStoredToken = await authService
            .primeAuthHeaderFromStoredToken()
            .timeout(const Duration(seconds: 1), onTimeout: () => false);
        if (hasStoredToken && mounted && _home == null) {
          setState(() {
            _home = const MainShell();
          });
        }
      }

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
          phoneAccessOwnerRequestNotifier.value = null;
          _offlinePurchaseProbeTimer?.cancel();
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
          unawaited(_probePendingPhoneAccessRequests());
          _restartOfflinePurchaseProbe();
          await refreshUserPreferences();
          _updateSubscriptionUiState();
        }
      });
      _restartSubscriptionProbe();
      _restartPhoneAccessProbe();
      _restartOfflinePurchaseProbe();
      _restartAppUpdateProbe();

      await refreshUserPreferences();
      unawaited(_prepareAppSoundPlayer());
    } catch (e, st) {
      debugPrint('Error attaching interceptor: $e\n$st');
    }

    final dbReady = await ensureDatabaseExists();

    final initial = await determineInitialScreen(
      dbReady,
    ).timeout(const Duration(seconds: 25), onTimeout: () => const AuthScreen());
    _updateSubscriptionUiState();
    unawaited(_probePendingPhoneAccessRequests());
    await refreshUserPreferences();

    debugPrint(
      'DiagnosticBootstrap: initial widget determined: ${initial.runtimeType}',
    );
    if (!mounted) return;
    setState(() {
      _home = initial;
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
              body: PhoenixLoadingView(
                title: 'Проект Феникс запускается',
                subtitle: 'Подключаемся к серверу и загружаем данные',
                size: 72,
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
            '/phone_access_pending': (_) => const PhoneAccessPendingScreen(),
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

class SetupFailedScreen extends StatefulWidget {
  const SetupFailedScreen({super.key});

  @override
  State<SetupFailedScreen> createState() => _SetupFailedScreenState();
}

class _SetupFailedScreenState extends State<SetupFailedScreen> {
  bool _retrying = false;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _scheduleAutoRetry();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _scheduleAutoRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _retrying) return;
      unawaited(_retryConnection(silent: true));
    });
  }

  Future<void> _retryConnection({bool silent = false}) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      final ok = await ensureDatabaseExists(attempts: 3);
      if (!mounted) return;
      if (ok) {
        final next = await determineInitialScreen(true);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => next),
        );
        return;
      }
      if (!silent) {
        showAppNotice(
          context,
          'Сервер пока недоступен. Мы попробуем снова.',
          tone: AppNoticeTone.warning,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _retrying = false);
        _scheduleAutoRetry();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = _lastConnectivityHint.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('Сервер временно недоступен')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Похоже, сервер Феникса был временно недоступен или перезапускался.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Мы уже пытаемся переподключиться автоматически. Обычно это занимает несколько секунд.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_retrying) ...[
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(width: 10),
                  ],
                  ElevatedButton(
                    onPressed: _retrying
                        ? null
                        : () => _retryConnection(silent: false),
                    child: Text(_retrying ? 'Подключаемся...' : 'Повторить сейчас'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
