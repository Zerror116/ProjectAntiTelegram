// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'screens/auth_screen.dart';
import 'screens/phone_name_screen.dart';
import 'screens/main_shell.dart';
import 'services/auth_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final Dio dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:3000'));
late final AuthService authService;

// Socket and event bus for chat events
IO.Socket? socket;
final StreamController<Map<String, dynamic>> chatEventsController =
    StreamController.broadcast();
final ValueNotifier<bool> notificationsEnabledNotifier = ValueNotifier(true);
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);

const _notificationsPrefPrefix = 'notifications_enabled_';
const _themePrefPrefix = 'theme_mode_dark_';
String? _lastPlayedMessageId;
bool _handlingAuthFailure = false;

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

  await SystemSound.play(SystemSoundType.click);
}

// ✅ Функция для безопасного отключения socket
Future<void> disconnectSocket() async {
  try {
    if (socket != null && socket!.connected) {
      debugPrint('🔌 Disconnecting socket...');
      socket!.disconnect();
      socket = null;
      debugPrint('✅ Socket disconnected');
    }
  } catch (e) {
    debugPrint('❌ Error disconnecting socket: $e');
  }
}

Future<bool> ensureDatabaseExists() async {
  try {
    debugPrint('ensureDatabaseExists: calling /api/setup');
    final resp = await dio.post('/api/setup');
    debugPrint(
      'ensureDatabaseExists: status=${resp.statusCode}, data=${resp.data}',
    );
    if (resp.statusCode == 200) {
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        return true;
      }
    }
    return false;
  } catch (e) {
    debugPrint('ensureDatabaseExists error: $e');
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
  try {
    debugPrint('🚀 Initializing socket...');

    // ✅ Закрой старое соединение, если оно есть
    try {
      if (socket != null && socket!.connected) {
        debugPrint('🔌 Closing old socket connection...');
        socket!.disconnect();
      }
      socket = null;
    } catch (_) {
      socket = null;
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');

    // Build options
    socket = IO.io(
      'http://127.0.0.1:3000',
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .setQuery({'token': token ?? ''})
          .setAuth({'token': token ?? ''})
          .build(),
    );

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
  }
}

Future<Widget> determineInitialScreen(bool dbReady) async {
  debugPrint('determineInitialScreen: dbReady=$dbReady');
  if (!dbReady) return const SetupFailedScreen();

  // ✅ ИСПРАВЛЕНИЕ: Используй tryRefreshOnStartup вместо setAuthHeaderFromStorage
  final logged = await authService.tryRefreshOnStartup();
  debugPrint('determineInitialScreen: tryRefreshOnStartup -> $logged');

  if (logged) {
    // init socket after successful refresh/login
    await _initSocket();
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

void main() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint(
      'FlutterError caught: ${details.exceptionAsString()}\n${details.stack}',
    );
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    final exception = details.exception;
    final stack = details.stack;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 64),
                const SizedBox(height: 12),
                const Text(
                  'Произошла ошибка',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  exception.toString(),
                  style: const TextStyle(color: Colors.black87),
                ),
                const SizedBox(height: 12),
                Text(
                  stack?.toString() ?? '',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      themeMode: ThemeMode.light,
      builder: (context, child) {
        return ScaffoldMessenger(child: child ?? const SizedBox.shrink());
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

      // ✅ ИСПРАВЛЕНИЕ: Подписка на изменения аутентификации
      // При logout (user == null) отключаем socket
      // При login (user != null) инициализируем socket
      _authSub = authService.authStream.listen((user) async {
        debugPrint('Auth stream event: user=${user?.email}');
        if (user == null) {
          // Пользователь вышел — отключаем socket
          await disconnectSocket();
          _lastPlayedMessageId = null;
          await refreshUserPreferences();
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
            title: 'Тапка (diag)',
            themeMode: mode,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
            darkTheme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('Загрузка...')),
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_status ?? 'Запуск...'),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Тапка',
          themeMode: mode,
          theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
          darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: _home,
          routes: {
            '/auth': (_) => const AuthScreen(),
            '/phone_name': (_) => const PhoneNameScreen(isRegisterFlow: false),
            '/main': (_) => const MainShell(),
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
                  if (ok) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const AuthScreen()),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Попытка подключения провалилась'),
                      ),
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
