// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
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
final StreamController<Map<String, dynamic>> chatEventsController = StreamController.broadcast();

Future<bool> ensureDatabaseExists() async {
  try {
    debugPrint('ensureDatabaseExists: calling /api/setup');
    final resp = await dio.post('/api/setup');
    debugPrint('ensureDatabaseExists: status=${resp.statusCode}, data=${resp.data}');
    if (resp.statusCode == 200) {
      final data = resp.data;
      if (data is Map && data['ok'] == true) return true;
      return false;
    }
    return false;
  } catch (e, st) {
    debugPrint('ensureDatabaseExists error: $e\n$st');
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

Future<void> _attachAuthInterceptor() async {
  debugPrint('_attachAuthInterceptor: attaching');
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('auth_token');
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        } else {
          options.headers.remove('Authorization');
        }
      } catch (e, st) {
        debugPrint('_attachAuthInterceptor onRequest error: $e\n$st');
      }
      handler.next(options);
    },
    onError: (err, handler) async {
      final status = err.response?.statusCode;
      debugPrint('Interceptor onError: status=$status path=${err.requestOptions.path}');
      if (status == 401 && !_isAuthEndpoint(err.requestOptions)) {
        debugPrint('Interceptor: 401 on non-auth endpoint -> performing logout and redirect');
        try {
          await authService.logout();
        } catch (e, st) {
          debugPrint('Error during logout in interceptor: $e\n$st');
        }
        if (navigatorKey.currentState != null) {
          navigatorKey.currentState!.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AuthScreen()),
            (route) => false,
          );
        }
      }
      handler.next(err);
    },
  ));
  debugPrint('_attachAuthInterceptor: done');
}

Future<void> _initSocket() async {
  try {
    // Close existing socket if any
    try {
      socket?.disconnect();
      socket?.destroy();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');

    // Build options
    final opts = <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': true,
    };
    if (token != null && token.isNotEmpty) {
      opts['auth'] = {'token': token};
      opts['query'] = {'token': token};
    }

    socket = IO.io('http://127.0.0.1:3000', IO.OptionBuilder()
        .setTransports(['websocket'])
        .enableAutoConnect()
        .setQuery({'token': token ?? ''})
        .build());

    socket?.on('connect', (_) {
      debugPrint('Socket connected: ${socket?.id}');
    });

    socket?.on('disconnect', (reason) {
      debugPrint('Socket disconnected: $reason');
    });

    socket?.on('connect_error', (err) {
      debugPrint('Socket connect_error: $err');
    });

    // Chat created -> notify listeners to reload chats
    socket?.on('chat:created', (data) {
      debugPrint('Socket event chat:created -> $data');
      chatEventsController.add({'type': 'chat:created', 'data': data});
    });

    // New message -> notify listeners
    socket?.on('chat:message', (data) {
      debugPrint('Socket event chat:message -> $data');
      chatEventsController.add({'type': 'chat:message', 'data': data});
    });

    // Global message event (optional)
    socket?.on('chat:message:global', (data) {
      debugPrint('Socket event chat:message:global -> $data');
      chatEventsController.add({'type': 'chat:message:global', 'data': data});
    });

    socket?.connect();
  } catch (e, st) {
    debugPrint('_initSocket error: $e\n$st');
  }
}

Future<Widget> determineInitialScreen(bool dbReady) async {
  debugPrint('determineInitialScreen: dbReady=$dbReady');
  if (!dbReady) return const SetupFailedScreen();

  await authService.setAuthHeaderFromStorage();

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
    debugPrint('determineInitialScreen: /api/profile status=${resp.statusCode}');
    if (resp.statusCode == 200 && resp.data is Map && resp.data['user'] is Map) {
      final user = Map<String, dynamic>.from(resp.data['user']);
      final name = user['name'];
      final phone = user['phone'];
      debugPrint('determineInitialScreen: user name=$name phone=$phone');
      if (name == null || (phone == null || (phone is String && phone.trim().isEmpty))) {
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
    debugPrint('FlutterError caught: ${details.exceptionAsString()}\n${details.stack}');
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    final exception = details.exception;
    final stack = details.stack;
    return Material(
      color: Colors.white,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error, color: Colors.red, size: 64),
              const SizedBox(height: 12),
              const Text('Произошла ошибка', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(exception.toString(), style: const TextStyle(color: Colors.black87)),
              const SizedBox(height: 12),
              Text(stack?.toString() ?? '', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
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

  @override
  void initState() {
    super.initState();
    _startInit();
  }

  Future<void> _startInit() async {
    setState(() => _status = 'Инициализация: attaching interceptor');
    try {
      authService = AuthService(dio: dio);
      await _attachAuthInterceptor();
    } catch (e, st) {
      debugPrint('Error attaching interceptor: $e\n$st');
    }

    setState(() => _status = 'Инициализация: проверка БД');
    final dbReady = await ensureDatabaseExists();

    setState(() => _status = 'Инициализация: определение стартового экрана');
    final initial = await determineInitialScreen(dbReady);

    debugPrint('DiagnosticBootstrap: initial widget determined: ${initial.runtimeType}');
    if (!mounted) return;
    setState(() {
      _home = initial;
      _status = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_home == null) {
      return MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Тапка (diag)',
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
    }

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Тапка',
      home: _home,
      routes: {
        '/auth': (_) => const AuthScreen(),
        '/phone_name': (_) => const PhoneNameScreen(isRegisterFlow: false),
        '/main': (_) => const MainShell(),
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    const SnackBar(content: Text('Повторная попытка не удалась')),
                  );
                }
              },
              child: const Text('Повторить'),
            ),
          ]),
        ),
      ),
    );
  }
}
