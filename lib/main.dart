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
const String _defaultApiBaseUrl = String.fromEnvironment(
  'FENIX_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:3000',
);
final Dio dio = Dio(BaseOptions(baseUrl: _defaultApiBaseUrl));
late final AuthService authService;

// Socket and event bus for chat events
io.Socket? socket;
final StreamController<Map<String, dynamic>> chatEventsController =
    StreamController.broadcast();
final ValueNotifier<bool> notificationsEnabledNotifier = ValueNotifier(true);
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);
final ValueNotifier<String?> activeChatIdNotifier = ValueNotifier<String?>(
  null,
);

const _notificationsPrefPrefix = 'notifications_enabled_';
const _themePrefPrefix = 'theme_mode_dark_';
String? _lastPlayedMessageId;
bool _handlingAuthFailure = false;
final AudioPlayer _appSoundPlayer = AudioPlayer();
bool _appSoundPlayerPrepared = false;
bool _socketInitInProgress = false;
String? _socketBoundUserId;
String? _socketBoundViewRole;

enum AppNoticeTone { info, success, warning, error }

enum AppUiSound { tap, sent, incoming, success, warning }

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

String _settingsScopeUserId() {
  final id = authService.currentUser?.id;
  if (id != null && id.trim().isNotEmpty) return id;
  return 'guest';
}

Future<void> refreshUserPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  final scope = _settingsScopeUserId();
  final notifications =
      prefs.getBool('$_notificationsPrefPrefix$scope') ?? true;
  final darkMode = prefs.getBool('$_themePrefPrefix$scope') ?? false;

  notificationsEnabledNotifier.value = notifications;
  themeModeNotifier.value = darkMode ? ThemeMode.dark : ThemeMode.light;
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
                    duration: const Duration(milliseconds: 220),
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
      ],
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
  try {
    debugPrint('ensureDatabaseExists: checking /health');
    final health = await dio.get('/health');
    debugPrint(
      'ensureDatabaseExists: /health status=${health.statusCode}, data=${health.data}',
    );
    if (health.statusCode == 200) {
      final data = health.data;
      if (data is Map && data['ok'] == true) return true;
      return true;
    }
  } catch (e) {
    debugPrint('ensureDatabaseExists: /health failed: $e');
  }

  try {
    debugPrint('ensureDatabaseExists: fallback /api/setup');
    final resp = await dio.post('/api/setup');
    debugPrint(
      'ensureDatabaseExists: /api/setup status=${resp.statusCode}, data=${resp.data}',
    );
    if (resp.statusCode == 200) {
      final data = resp.data;
      if (data is Map && data['ok'] == true) return true;
    }
    return false;
  } catch (e) {
    debugPrint('ensureDatabaseExists fallback error: $e');
    return false;
  }
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

String? _encodeTenantCodeHeaderValue(String? tenantCode) {
  final value = (tenantCode ?? '').trim().toLowerCase();
  if (value.isEmpty) return null;
  final encoded = Uri.encodeComponent(value);
  if (encoded.isEmpty) return null;
  return encoded;
}

void _attachAuthInterceptor() {
  debugPrint('_attachAuthInterceptor: attaching');
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
          final tenantCode = await authService.getTenantCode();
          final currentRole =
              authService.currentUser?.role.toLowerCase().trim() ?? '';
          if (currentRole == 'creator') {
            options.headers.remove('X-Tenant-Code');
          } else {
            final encodedTenantCode = _encodeTenantCodeHeaderValue(tenantCode);
            if (encodedTenantCode != null) {
              options.headers['X-Tenant-Code'] = encodedTenantCode;
            } else {
              options.headers.remove('X-Tenant-Code');
            }
          }
          final viewRole = authService.viewRole?.trim();
          if ((authService.currentUser?.role.toLowerCase().trim() ?? '') ==
                  'creator' &&
              viewRole != null &&
              viewRole.isNotEmpty) {
            options.headers['X-View-Role'] = viewRole;
          } else {
            options.headers.remove('X-View-Role');
          }
          return handler.next(options);
        } catch (e, st) {
          debugPrint('onRequest interceptor error: $e\n$st');
          return handler.next(options);
        }
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
      _defaultApiBaseUrl,
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

    socket?.on('cart:updated', (data) {
      debugPrint('📬 Socket event cart:updated -> $data');
      chatEventsController.add({'type': 'cart:updated', 'data': data});
    });

    socket?.on('delivery:updated', (data) {
      debugPrint('📬 Socket event delivery:updated -> $data');
      chatEventsController.add({'type': 'delivery:updated', 'data': data});
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
  final logged = await authService.tryRefreshOnStartup();
  debugPrint('determineInitialScreen: tryRefreshOnStartup -> $logged');

  if (logged) {
    _handlingAuthFailure = false;
  }

  if (!logged) {
    return const AuthScreen();
  }

  try {
    final resp = await dio.get('/api/profile');
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
        ? AppTheme.dark()
        : AppTheme.light();
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
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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
    super.dispose();
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
        }
      });

      await refreshUserPreferences();
      unawaited(_prepareAppSoundPlayer());
    } catch (e, st) {
      debugPrint('Error attaching interceptor: $e\n$st');
    }

    setState(() => _status = 'Инициализация: проверка БД');
    final dbReady = await ensureDatabaseExists();

    setState(() => _status = 'Инициализация: определение стартового экрана');
    final initial = await determineInitialScreen(dbReady);
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
      return ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (context, mode, _) {
          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Проект Феникс (diag)',
            themeMode: mode,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            home: Scaffold(
              appBar: AppBar(title: const Text('Загрузка...')),
              body: PhoenixLoadingView(
                title: 'Проект Феникс запускается',
                subtitle: _status ?? 'Подготавливаем приложение',
              ),
            ),
            builder: (context, child) {
              return ScaffoldMessenger(
                child: _GlobalNoticeHost(
                  child: child ?? const SizedBox.shrink(),
                ),
              );
            },
          );
        },
      );
    }

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Проект Феникс',
          themeMode: mode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: _home,
          routes: {
            '/auth': (_) => const AuthScreen(),
            '/phone_name': (_) => const PhoneNameScreen(isRegisterFlow: false),
            '/main': (_) => const MainShell(),
          },
          builder: (context, child) {
            return ScaffoldMessenger(
              child: _GlobalNoticeHost(child: child ?? const SizedBox.shrink()),
            );
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
