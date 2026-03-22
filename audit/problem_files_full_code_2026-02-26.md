# Проблемные файлы и их полный код

Дата: 2026-02-26

## test/widget_test.dart

```dart
// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:projectphoenix/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our counter starts at 0.
    expect(find.text('0'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    // Tap the '+' icon and trigger a frame.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Verify that our counter has incremented.
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });
}

\`\`\`

## lib/screens/settings_screen.dart

```dart
// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/auth_service.dart';
import 'change_password_screen.dart';
import 'package:dio/dio.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AuthService _auth = authService;
  bool _notifications = true;
  bool _darkMode = false;
  bool _loading = false;
  String _message = '';

  String _extractDioMessage(dynamic e) {
    try {
      final resp = (e is DioException) ? e.response : (e is DioError ? e.response : null);
      if (resp != null && resp.data != null) return resp.data.toString();
    } catch (_) {}
    return e?.toString() ?? 'Неизвестная ошибка';
  }

  Future<void> _toggleNotifications(bool v) async {
    setState(() => _notifications = v);
    // TODO: persist preference
  }

  Future<void> _toggleDarkMode(bool v) async {
    setState(() => _darkMode = v);
    // TODO: apply theme and persist
  }

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить аккаунт'),
        content: const Text('Вы уверены? Это действие необратимо.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      final resp = await _auth.dio.post('/api/auth/delete_account');
      if (resp.statusCode == 200) {
        // Поддерживаем разные реализации logout/clearToken
        try {
          if ((_auth).clearToken is Function) {
            await _auth.clearToken();
          } else if ((_auth).logout is Function) {
            await _auth.logout();
          }
        } catch (_) {}
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/');
      } else {
        if (!mounted) return;
        setState(() => _message = 'Ошибка удаления аккаунта');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка: ${_extractDioMessage(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSupport() async {
    setState(() => _message = 'Функция поддержки пока не реализована');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SwitchListTile(
                        value: _notifications,
                        onChanged: _toggleNotifications,
                        title: const Text('Уведомления'),
                        subtitle: const Text('Включить или отключить push-уведомления'),
                      ),
                      SwitchListTile(
                        value: _darkMode,
                        onChanged: _toggleDarkMode,
                        title: const Text('Тёмная тема'),
                        subtitle: const Text('Переключить тему приложения'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.lock),
                        title: const Text('Сменить пароль'),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
                      ),
                      ListTile(
                        leading: const Icon(Icons.support_agent),
                        title: const Text('Поддержка'),
                        onTap: _openSupport,
                      ),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.delete_forever, color: Colors.red),
                        title: const Text('Удалить аккаунт', style: TextStyle(color: Colors.red)),
                        onTap: _deleteAccount,
                      ),
                      const SizedBox(height: 16),
                      if (_message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(_message, style: const TextStyle(color: Colors.red)),
                        ),
                      if (_loading) const Padding(padding: EdgeInsets.only(top: 12), child: Center(child: CircularProgressIndicator())),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

\`\`\`

## lib/screens/auth_screen.dart

```dart
// lib/screens/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../services/auth_service.dart';
import '../main.dart'; // глобальный authService и dio

import 'phone_name_screen.dart';
import 'main_shell.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String _message = '';
  bool _isRegister = false;

  late final AuthService _authService;

  // listeners so we can remove them properly
  late final VoidCallback _emailListener;
  late final VoidCallback _passwordListener;

  @override
  void initState() {
    super.initState();
    _authService = authService;

    // Подписываемся на контроллеры, чтобы гарантированно перерисовывать UI при вводе
    _emailListener = () => setState(() {});
    _passwordListener = () => setState(() {});
    _emailController.addListener(_emailListener);
    _passwordController.addListener(_passwordListener);

    _tryAutoLogin();
  }

  @override
  void dispose() {
    // Удаляем слушатели корректно
    try {
      _emailController.removeListener(_emailListener);
    } catch (_) {}
    try {
      _passwordController.removeListener(_passwordListener);
    } catch (_) {}

    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _tryAutoLogin() async {
    setState(() => _loading = true);
    final ok = await _auth_service_tryRefresh();
    setState(() => _loading = false);
    if (ok) {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainShell()));
    }
  }

  Future<bool> _auth_service_tryRefresh() async {
    try {
      return await _authService.tryRefreshOnStartup();
    } catch (_) {
      return false;
    }
  }

  /// Проверяем занятость email на сервере
  Future<bool> _checkEmailExists(String email) async {
    try {
      final resp = await _authService.dio.post('/api/auth/check_email', data: {'email': email});
      // ожидаем { exists: true/false } или {exists:1/0}
      final data = resp.data;
      if (data is Map && data['exists'] != null) {
        return data['exists'] == true || data['exists'] == 1;
      }
      return false;
    } catch (_) {
      // при ошибке сети считаем, что email не занят (чтобы не блокировать), но можно изменить логику
      return false;
    }
  }

  Future<void> _onSubmitPressed() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _message = '';
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (_isRegister) {
        // Сначала проверяем, занят ли email
        final exists = await _checkEmailExists(email);
        if (exists) {
          setState(() {
            _message = 'Email уже занят';
            _loading = false;
          });
          return;
        }

        // Email свободен — сохраняем pending данные и переходим на экран ввода имени+телефона
        _authService.setPendingCredentials(email: email, password: password);
        if (!mounted) return;

        // Вариант B: сброс всего стека и переход на PhoneNameScreen
        // Это удалит экран регистрации из стека, поэтому кнопки "назад" не будет.
        setState(() => _loading = false);
        await Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const PhoneNameScreen(isRegisterFlow: true)),
          (Route<dynamic> route) => false,
        );

        // После pushAndRemoveUntil управление обычно не вернётся сюда,
        // но на всякий случай завершаем метод.
        return;
      } else {
        // Обычный логин
        await _authService.login(email: email, password: password);
      }

      // После логина — проверяем профиль и переходим
      try {
        final resp = await _authService.dio.get('/api/profile');
        final data = resp.data as Map<String, dynamic>? ?? {};
        final user = data['user'] as Map<String, dynamic>? ?? {};
        final phone = user['phone'] as String?;
        final phoneStatus = data['phone_status'] as String? ?? data['phoneStatus'] as String?;
        final hasPhone = phone != null && phone.trim().isNotEmpty;

        if (!hasPhone || phoneStatus == 'pending_verification') {
          if (!mounted) return;
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PhoneNameScreen(isRegisterFlow: false)));
          return;
        }

        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainShell()));
        return;
      } catch (_) {
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PhoneNameScreen(isRegisterFlow: false)));
        return;
      }
    } on DioException catch (e) {
      String friendly = 'Ошибка';
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        friendly = 'Пупупу, ошибочка — что-то не так с email или паролем. Пытаетесь кого-то взломать? 😉';
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        friendly = 'Время ожидания ответа сервера истекло. Попробуйте ещё раз.';
      } else if (e.response != null && e.response?.data != null) {
        final body = e.response?.data;
        if (body is Map && (body['error'] != null || body['message'] != null)) {
          friendly = (body['error'] ?? body['message']).toString();
        } else {
          friendly = e.response.toString();
        }
      } else {
        friendly = e.message ?? e.toString();
      }
      setState(() => _message = friendly);
    } catch (e) {
      setState(() => _message = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isRegister ? 'Регистрация' : 'Вход')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Form(
              key: _formKey,
              child: Column(children: [
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Введите email';
                    if (!v.contains('@')) return 'Неверный формат email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'Пароль'),
                  obscureText: true,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Введите пароль';
                    if (v.length < 8) return 'Пароль должен быть не менее 8 символов';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _onSubmitPressed,
                    child: _loading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(_isRegister ? 'Далее' : 'Войти'),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_isRegister ? 'Уже есть аккаунт?' : 'Нет аккаунта?'),
                TextButton(
                  onPressed: () => setState(() {
                    _isRegister = !_isRegister;
                    _message = '';
                  }),
                  child: Text(_isRegister ? 'Войти' : 'Зарегистрироваться'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    );
  }
}

\`\`\`

## lib/screens/phone_name_screen.dart

```dart
// lib/screens/phone_name_screen.dart
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../main.dart';
import '../services/auth_service.dart';
import '../utils/phone_utils.dart';

class PhoneNameScreen extends StatefulWidget {
  final bool isRegisterFlow;
  const PhoneNameScreen({super.key, this.isRegisterFlow = false});

  @override
  State<PhoneNameScreen> createState() => _PhoneNameScreenState();
}

class _PhoneNameScreenState extends State<PhoneNameScreen> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();

  late final VoidCallback _nameListener;
  late final VoidCallback _phoneListener;
  late final VoidCallback _secretListener;

  bool _loading = false;
  String _message = '';

  static const String _creatorEmail = 'zerotwo02166@gmail.com';

  bool get _isCreatorPending {
    final pending = authService.pendingEmail;
    return pending != null && pending.toLowerCase() == _creatorEmail.toLowerCase();
  }

  bool get _isCreatorCurrentUser {
    final email = authService.currentUser?.email;
    return email != null && email.toLowerCase() == _creatorEmail.toLowerCase();
  }

  bool get _shouldShowSecretField => widget.isRegisterFlow ? _isCreatorPending : _isCreatorCurrentUser;

  @override
  void initState() {
    super.initState();
    final u = authService.currentUser;
    if (u != null) {
      _nameCtrl.text = u.name ?? '';
      _phoneCtrl.text = u.phone ?? '';
    }

    _nameListener = () => setState(() {});
    _phoneListener = () => setState(() {});
    _secretListener = () => setState(() {});

    _nameCtrl.addListener(_nameListener);
    _phoneCtrl.addListener(_phoneListener);
    _secretCtrl.addListener(_secretListener);
  }

  @override
  void dispose() {
    try { _nameCtrl.removeListener(_nameListener); } catch (_) {}
    try { _phoneCtrl.removeListener(_phoneListener); } catch (_) {}
    try { _secretCtrl.removeListener(_secretListener); } catch (_) {}

    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  String? _extractDioMessage(dynamic e) {
    try {
      if (e is DioException && e.response != null && e.response?.data is Map) {
        final data = e.response!.data as Map<String, dynamic>?;
        return data?['error']?.toString() ?? data?['message']?.toString();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final phoneRaw = _phoneCtrl.text.trim();
    final secret = _secretCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _message = 'Введите имя');
      return;
    }
    if (phoneRaw.isEmpty) {
      setState(() => _message = 'Введите номер телефона');
      return;
    }

    if (!PhoneUtils.validatePhone(phoneRaw)) {
      setState(() => _message = 'Неверный формат номера. Примеры: 89991234567, +7 (999) 123-45-67');
      return;
    }

    if (_shouldShowSecretField && secret.isEmpty) {
      setState(() => _message = 'Введите секретное слово');
      return;
    }

    final apiPhone = PhoneUtils.normalizeToE164(phoneRaw);
    if (apiPhone == null) {
      setState(() => _message = 'Невозможно нормализовать номер');
      return;
    }

    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      if (widget.isRegisterFlow) {
        if (authService.pendingEmail == null || authService.pendingPassword == null) {
          setState(() => _message = 'Нет сохранённых данных регистрации. Повторите шаг регистрации.');
          return;
        }

        final data = {
          'email': authService.pendingEmail,
          'password': authService.pendingPassword,
          'name': name,
          'phone': apiPhone,
        };
        if (_isCreatorPending) data['secret'] = secret;

        final resp = await authService.dio.post('/api/auth/register', data: data);

        // ✅ ИСПРАВЛЕНИЕ: Cast правильно
        final respData = (resp.data as Map<dynamic, dynamic>).cast<String, dynamic>();
        final token = respData['token'] ?? respData['access'];
        if (token == null) {
          setState(() => _message = 'Регистрация прошла, но токен не получен от сервера.');
          return;
        }

        // Сохраняем токен гибко (поддержка разных authService)
        await authService.applyLoginResponse(token as String, respData['user'] as Map<String, dynamic>?);

        // Очистим pending
        try { authService.pendingEmail = null; authService.pendingPassword = null; } catch (_) {}

        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/main');
        return;
      } else {
        final profileData = {'name': name};
        if (_isCreatorCurrentUser) profileData['secret'] = secret;

        final p1 = authService.dio.post('/api/profile/update', data: profileData);
        final p2 = authService.dio.post('/api/phones/request', data: {'phone': apiPhone});
        final results = await Future.wait([p1, p2]);

        final ok1 = (results[0].statusCode == 200) ||
            (results[0].data is Map && (results[0].data['ok'] == true || results[0].data['user'] != null));
        final ok2 = (results[1].statusCode == 200) || (results[1].data is Map && results[1].data['ok'] == true);

        if (ok1 && ok2) {
          try {
            await authService.setAuthHeaderFromStorage();
          } catch (_) {}

          if (!mounted) return;
          Navigator.of(context).pop();
          return;
        } else {
          setState(() => _message = 'Ошибка обновления профиля');
        }
      }
    } on DioException catch (e) {
      final errMsg = _extractDioMessage(e) ?? 'Ошибка: ${e.message}';
      setState(() => _message = errMsg);
    } catch (e) {
      setState(() => _message = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Введите имя и номер'),
        leading: widget.isRegisterFlow
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Имя'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Номер телефона',
                  hintText: 'Например: +7 (999) 171-45-51 или 89991714551',
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 12),
              if (_shouldShowSecretField) ...[
                TextField(
                  controller: _secretCtrl,
                  decoration: const InputDecoration(labelText: 'Секретное слово'),
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 12),
              ],
              ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.isRegisterFlow ? 'Завершить регистрацию' : 'Сохранить'),
              ),
              const SizedBox(height: 12),
              if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
    );
  }
}
\`\`\`

## server/src/index.js

```javascript
// server/src/index.js
// Главный файл Express приложения с Socket.io

require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const bodyParser = require('body-parser');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const rateLimit = require('express-rate-limit');
const validator = require('validator');

const db = require('./db');

// ✅ Сначала создаём app, потом использу��м его
const app = express();

// Импортируем роуты и middleware ПОСЛЕ создания app
const profileUpdateRoutes = require('./routes/profileUpdate');
const setupRouter = require('./routes/setup');
const phonesRouter = require('./routes/phones');
const chatsRouter = require('./routes/chats');
const profileRouter = require('./routes/profile');
const authRouter = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const { authMiddleware } = require('./utils/auth');

// ===================================
// MIDDLEWARE И КОНФИГУРАЦИЯ
// ===================================

// Общие middleware
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Логирование входящих запросов и времени обработки
app.use((req, res, next) => {
  const start = Date.now();
  console.log('SERVER REQ START →', req.method, req.url);
  res.on('finish', () => {
    const duration = Date.now() - start;
    console.log(`SERVER REQ END ← ${req.method} ${req.url} ${res.statusCode} ${duration}ms`);
  });
  next();
});

// Лимитер для маршрутов аутентифика��ии (защита от brute-force)
const authLimiter = rateLimit({
  windowMs: 2 * 1000,      // 2 секунды
  max: 6,                   // максимум 6 запросов в окне
  message: { error: 'Слишком быстро, чуть чуть подождите' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/api/auth/register', authLimiter);
app.use('/api/auth/login', authLimiter);

// ===================================
// РОУТЫ
// ===================================

// Setup роут (инициализация БД)
app.use('/api/setup', setupRouter);

// Auth роуты
app.use('/api/auth', authRouter);

// Остальные роуты
app.use('/api/phones', phonesRouter);
app.use('/api/profile', [profileUpdateRoutes, profileRouter]);
app.use('/api/chats', chatsRouter);
app.use('/api/admin', adminRoutes);

// ===================================
// КОНФИГУРАЦИЯ И УТИЛИТЫ
// ===================================

const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

/**
 * Подписывает JWT токен
 */
function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}

/**
 * Ищет пользователя по email
 */
async function findUserByEmail(email) {
  try {
    const res = await db.query(
      'SELECT id, email, password_hash FROM users WHERE email = $1',
      [email]
    );
    return res.rows[0] || null;
  } catch (err) {
    console.error('findUserByEmail error:', err);
    return null;
  }
}

// ===================================
// HEALTH CHECK ENDPOINTS
// ===================================

// Базовый health check
app.get('/', (req, res) => {
  res.json({ ok: true, service: 'ProjectPhoenix API' });
});

// Ping для проверки доступности
app.get('/ping', (req, res) => {
  res.json({ ok: true, timestamp: Date.now() });
});

// Детальный здоровье сервера
app.get('/health', async (req, res) => {
  try {
    // Проверяем подключение к БД
    await db.query('SELECT 1');
    res.json({
      ok: true,
      status: 'healthy',
      database: 'connected',
      timestamp: Date.now()
    });
  } catch (err) {
    console.error('Health check error:', err);
    res.status(503).json({
      ok: false,
      status: 'unhealthy',
      database: 'disconnected',
      error: err.message
    });
  }
});

// ===================================
// ЗАЩИЩЁННЫЕ РОУТЫ
// ===================================

// Пример защищённого роута — получение профиля
app.get('/api/user/profile', authMiddleware, async (req, res) => {
  try {
    const { id } = req.user;
    const result = await db.query(
      'SELECT id, email, name, phone, role, created_at FROM users WHERE id = $1',
      [id]
    );
    const user = result.rows[0];
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    return res.json({ ok: true, user });
  } catch (err) {
    console.error('Profile error:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// ===================================
// ERROR HANDLERS
// ===================================

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found', path: req.path });
});

// Глобальный обработчик ошибок (ДОЛЖЕН быть последним!)
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  const status = err.status || err.statusCode || 500;
  res.status(status).json({
    error: 'Server error',
    message: err.message,
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
  });
});

// ===================================
// ФУНКЦИИ ИНИЦИАЛИЗАЦИИ
// ===================================

/**
 * Помечает пользователя с email CREATOR_EMAIL как 'creator' при старте
 */
async function ensureCreator() {
  try {
    const creatorEmail = process.env.CREATOR_EMAIL || 'zerotwo02166@gmail.com';
    console.log(`Checking for creator: ${creatorEmail}`);

    const res = await db.query(
      'SELECT id, role FROM users WHERE email = $1',
      [creatorEmail]
    );

    if (res.rowCount === 1 && res.rows[0].role !== 'creator') {
      await db.query(
        'UPDATE users SET role = $1 WHERE id = $2',
        ['creator', res.rows[0].id]
      );
      console.log(`✅ Marked user ${creatorEmail} as creator`);
    } else if (res.rowCount === 0) {
      console.log(`⚠️ Creator user not found: ${creatorEmail}`);
    }
  } catch (err) {
    console.error('ensureCreator error:', err);
  }
}

// ===================================
// SERVER STARTUP
// ===================================

/**
 * Запуск сервера в async IIFE
 */
(async () => {
  try {
    console.log('🚀 Starting server initialization...');

    // Помечаем creator (если пользователь с таким email существует)
    await ensureCreator();

    // Создаём HTTP сервер
    const server = http.createServer(app);

    // Инициализируем Socket.io
    const io = new Server(server, {
      cors: {
        origin: '*',
        methods: ['GET', 'POST'],
        credentials: false,
      },
      transports: ['websocket', 'polling'],
    });

    // Делаем io доступным в express
    app.set('io', io);
    console.log('✅ Socket.io initialized');

    // ===================================
    // SOCKET.IO MIDDLEWARE И HANDLERS
    // ===================================

    /**
     * Аутентификация сокета по JWT токену
     */
    io.use((socket, next) => {
      try {
        const token = socket.handshake.auth?.token || socket.handshake.query?.token;
        if (!token) {
          console.log(`Socket ${socket.id} connected without token (anonymous)`);
          return next(); // разрешаем подключение без токена
        }

        try {
          const payload = jwt.verify(token, JWT_SECRET);
          socket.user = payload; // { id, email, role, ... }
          console.log(`Socket ${socket.id} authenticated as user ${payload.id}`);
        } catch (err) {
          console.warn(`Socket ${socket.id} token verification failed:`, err.message);
          // Разрешаем подключение, но без user info
        }
        return next();
      } catch (err) {
        console.error('io.use middleware error:', err);
        return next();
      }
    });

    /**
     * Обработчики подключений сокета
     */
    io.on('connection', (socket) => {
      const sid = socket.id;
      const uid = socket.user?.id;
      console.log(`📡 Socket connected: ${sid} (user=${uid || 'anonymous'})`);

      // ✅ ИСПРАВЛЕНИЕ: Если юзер залогинился, очисти его старые сокеты
      if (uid) {
        // Получи все сокеты этого юзера
        const userSockets = io.sockets.sockets;
        let socketCount = 0;

        for (const [existingSid, existingSocket] of userSockets) {
          if (existingSocket.user?.id === uid && existingSid !== sid) {
            console.log(`🔌 Disconnecting old socket ${existingSid} for user ${uid}`);
            existingSocket.disconnect(true); // true = отправи клиенту disconnect событие
            socketCount++;
          }
        }

        if (socketCount > 0) {
          console.log(`✅ Cleaned up ${socketCount} old socket(s) for user ${uid}`);
        }
      }

      // Присоединение к комнате чата
      socket.on('join_chat', (chatId) => {
        try {
          if (!chatId) {
            console.warn(`Socket ${sid}: join_chat called with empty chatId`);
            return;
          }

          // ✅ ИСПРАВЛЕНИЕ: Сначала выйди из всех чатов, потом присоединись к новому
          // Получи текущие ком��аты сокета
          const currentRooms = socket.rooms;

          // Выйди из всех chat:* комнат
          for (const room of currentRooms) {
            if (room.startsWith('chat:')) {
              socket.leave(room);
              console.log(`Socket ${sid} left room ${room}`);
            }
          }

          // Присоединись к новой комнате
          socket.join(`chat:${chatId}`);
          console.log(`Socket ${sid} joined chat:${chatId}`);
        } catch (err) {
          console.error(`Socket ${sid} join_chat error:`, err);
        }
      });

      // Выход из комнаты чата
      socket.on('leave_chat', (chatId) => {
        try {
          if (!chatId) {
            console.warn(`Socket ${sid}: leave_chat called with empty chatId`);
            return;
          }
          socket.leave(`chat:${chatId}`);
          console.log(`Socket ${sid} left chat:${chatId}`);
        } catch (err) {
          console.error(`Socket ${sid} leave_chat error:`, err);
        }
      });

      // ✅ ИСПРАВЛЕНИЕ: Обработка отключения с логированием
      socket.on('disconnect', (reason) => {
        console.log(`📡 Socket disconnected: ${sid} (user=${uid || 'anonymous'}, reason: ${reason})`);

        // Все комнаты автоматически очищаются при disconnect
        const roomsBeforeDisconnect = Array.from(socket.rooms);
        console.log(`   Rooms cleared: ${roomsBeforeDisconnect.join(', ')}`);
      });

      // Обработчик ошибок сокета
      socket.on('error', (error) => {
        console.error(`Socket ${sid} error:`, error);
      });

      // ✅ Логирование всех событий для отладки (опционально)
      socket.onAny((eventName, ...args) => {
        if (!['ping', 'pong'].includes(eventName)) {
          console.log(`Socket ${sid} event: ${eventName}`, args.length > 0 ? args[0] : '');
        }
      });
    });

    // Запуск сервера
    server.listen(PORT, '0.0.0.0', () => {
      console.log(`\n✅ Server listening on http://0.0.0.0:${PORT}`);
      console.log(`📝 Environment: ${process.env.NODE_ENV || 'development'}`);
      console.log(`🔐 JWT Secret: ${JWT_SECRET === 'change_me_long_secret' ? '⚠️ DEFAULT (CHANGE ME!)' : '✅ Custom'}`);
      console.log('\n');
    });

  } catch (err) {
    console.error('❌ Failed to start server:', err);
    process.exit(1);
  }
})();

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully...');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received, shutting down gracefully...');
  process.exit(0);
});
\`\`\`

## server/src/routes/chats.js

```javascript
// server/src/routes/chats.js
const express = require('express');
const router = express.Router();
const db = require('../db');
const { authMiddleware: requireAuth } = require('../utils/auth');
const { requireRole } = require('../utils/roles');
const { requireChatPermission } = require('../utils/permissions');
const { v4: uuidv4 } = require('uuid');

router.get('/', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const publicQ = await db.query(
      `SELECT c.id, c.title, c.type,
              (SELECT text FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message,
              (SELECT created_at FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as updated_at
       FROM chats c
       WHERE NOT EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = c.id)
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`
    );
    const privateQ = await db.query(
      `SELECT c.id, c.title, c.type,
              (SELECT text FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message,
              (SELECT created_at FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as updated_at
       FROM chats c
       JOIN chat_members cm ON cm.chat_id = c.id
       WHERE cm.user_id = $1
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`,
      [userId]
    );
    const chats = [...publicQ.rows, ...privateQ.rows];
    return res.json({ ok: true, data: chats });
  } catch (err) {
    console.error('chats.list error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

/**
 * POST /api/chats
 * Создать чат — только creator или admin
 * body: { title, type?: 'public'|'private', members?: [userId,...] }
 */
router.post('/', requireAuth, requireRole('creator', 'admin'), async (req, res) => {
  try {
    const { title, type = 'public', members = [] } = req.body || {};
    if (!title || typeof title !== 'string') {
      return res.status(400).json({ ok: false, error: 'title required' });
    }
    const insert = await db.query(
      `INSERT INTO chats (id, title, type, created_by, settings, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, now(), now())
       RETURNING id, title, type, created_by`,
      [uuidv4(), title, type, req.user.id, JSON.stringify({})]
    );
    const chat = insert.rows[0];
    if (type === 'private') {
      const creatorId = req.user.id;
      const membersArr = Array.isArray(members) ? members : [];
      const toAdd = Array.from(new Set([creatorId, ...membersArr]));
      const insertPromises = toAdd.map((uid) =>
        db.query(
          `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
           VALUES ($1, $2, $3, now(), $4)
           ON CONFLICT (chat_id, user_id) DO NOTHING`,
          [uuidv4(), chat.id, uid, uid === creatorId ? 'owner' : 'member']
        )
      );
      await Promise.all(insertPromises);
    }
    const resultChat = { id: chat.id, title: chat.title, type: chat.type, created_by: chat.created_by };
    const io = req.app.get('io');
    if (type === 'public' && io) {
      io.emit('chat:created', { chat: resultChat });
    }
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'create_chat', null, JSON.stringify({ chatId: chat.id, type })]
      );
    } catch (e) {
      // ignore audit errors
    }
    return res.status(201).json({ ok: true, data: resultChat });
  } catch (err) {
    console.error('chats.create error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

/**
 * GET /api/chats/:chatId/messages
 */
router.get('/:chatId/messages', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { chatId } = req.params;
    const chatQ = await db.query('SELECT id, title FROM chats WHERE id = $1', [chatId]);
    if (chatQ.rowCount === 0) return res.status(404).json({ ok: false, error: 'Chat not found' });
    const memberQ = await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
    const isMember = memberQ.rowCount > 0;
    const hasMembers = (await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 LIMIT 1', [chatId])).rowCount > 0;
    if (hasMembers && !isMember) {
      return res.status(403).json({ ok: false, error: 'Not a member' });
    }
    const { rows } = await db.query(
      `SELECT id, sender_id, text, created_at,
              (sender_id = $2) as from_me
       FROM messages
       WHERE chat_id = $1
       ORDER BY created_at ASC
       LIMIT 1000`,
      [chatId, userId]
    );
    return res.json({ ok: true, data: rows });
  } catch (err) {
    console.error('chats.messages error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

/**
 * POST /api/chats/:chatId/messages
 * Поддержка client_msg_id для дедупликации (client-generated UUID)
 */
router.post('/:chatId/messages', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { chatId } = req.params;
    const { text, client_msg_id } = req.body || {}; // client_msg_id — optional UUID from client

    if (!text || !text.trim()) return res.status(400).json({ ok: false, error: 'Text required' });

    // Проверим существование чата и его тип
    const chatQ = await db.query('SELECT id, type FROM chats WHERE id = $1', [chatId]);
    if (chatQ.rowCount === 0) return res.status(404).json({ ok: false, error: 'Chat not found' });

    // Проверка участия: если в chat_members есть записи для этого чата, то это приватный чат и нужно быть участником.
    const hasMembers = (await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 LIMIT 1', [chatId])).rowCount > 0;
    if (hasMembers) {
      const memberQ = await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
      if (memberQ.rowCount === 0) return res.status(403).json({ ok: false, error: 'Not a member' });
    }

    // Вставляем сообщение с поддержкой client_msg_id для дедупа
    let insert;
    if (client_msg_id) {
      insert = await db.query(
        `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
         VALUES ($1, $2, $3, $4, $5, now())
         ON CONFLICT (client_msg_id) DO NOTHING
         RETURNING id, client_msg_id, chat_id, sender_id, text, created_at`,
        [uuidv4(), client_msg_id, chatId, userId, text]
      );

      // Если вставка не произошла (конфликт), получим существующую запись
      if (insert.rowCount === 0) {
        const q = await db.query(
          'SELECT id, client_msg_id, chat_id, sender_id, text, created_at FROM messages WHERE client_msg_id = $1',
          [client_msg_id]
        );
        insert = q;
      }
    } else {
      // Без client_msg_id — обычная вставка
      insert = await db.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, created_at)
         VALUES ($1, $2, $3, $4, now())
         RETURNING id, client_msg_id, chat_id, sender_id, text, created_at`,
        [uuidv4(), chatId, userId, text]
      );
    }

    const message = insert.rows[0];

    // Обновим updated_at у чата (если есть колонка)
    try {
      await db.query('UPDATE chats SET updated_at = now() WHERE id = $1', [chatId]);
    } catch (e) { /* ignore */ }

    // Broadcast message — включаем client_msg_id, чтобы клиент мог дедупить
    const io = req.app.get('io');
    if (io) {
      io.to(`chat:${chatId}`).emit('chat:message', { chatId, message });
      io.emit('chat:message:global', { chatId, message });
    }

    return res.status(201).json({ ok: true, data: message });
  } catch (err) {
    console.error('chats.postMessage error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

/**
 * Members management endpoints
 * - GET /api/chats/:chatId/members
 * - POST /api/chats/:chatId/members  (invite)  — owner/moderator
 * - DELETE /api/chats/:chatId/members/:userId  — owner/moderator
 * - PATCH /api/chats/:chatId/members/:userId/role  — only owner
 */

// GET members
router.get('/:chatId/members', requireAuth, async (req, res) => {
  try {
    const { chatId } = req.params;
    const q = await db.query(
      `SELECT u.id as user_id, u.email, cm.role, cm.joined_at
       FROM users u
       JOIN chat_members cm ON cm.user_id = u.id
       WHERE cm.chat_id = $1
       ORDER BY cm.joined_at ASC`,
      [chatId]
    );
    return res.json({ ok: true, data: q.rows });
  } catch (err) {
    console.error('chats.members.list error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// POST invite (owner/moderator)
router.post('/:chatId/members', requireAuth, requireChatPermission(['owner','moderator']), async (req, res) => {
  const { chatId } = req.params;
  const { userId, role = 'member' } = req.body || {};
  if (!userId) return res.status(400).json({ ok: false, error: 'userId required' });

  try {
    await db.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1,$2,$3,now(),$4)
       ON CONFLICT (chat_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
      [uuidv4(), chatId, userId, role]
    );

    // audit
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'invite_user', userId, JSON.stringify({ chatId, role })]
      );
    } catch (e) { /* ignore audit errors */ }

    return res.status(201).json({ ok: true });
  } catch (err) {
    console.error('chats.members.add error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// DELETE member (owner/moderator)
router.delete('/:chatId/members/:userId', requireAuth, requireChatPermission(['owner','moderator']), async (req, res) => {
  const { chatId, userId } = req.params;
  try {
    await db.query('DELETE FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);

    // audit
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'remove_user', userId, JSON.stringify({ chatId })]
      );
    } catch (e) { /* ignore audit errors */ }

    return res.json({ ok: true });
  } catch (err) {
    console.error('chats.members.delete error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// PATCH change role (only owner)
router.patch('/:chatId/members/:userId/role', requireAuth, requireChatPermission(['owner']), async (req, res) => {
  const { chatId, userId } = req.params;
  const { role } = req.body || {};
  if (!role) return res.status(400).json({ ok: false, error: 'role required' });
  try {
    await db.query('UPDATE chat_members SET role=$1 WHERE chat_id=$2 AND user_id=$3', [role, chatId, userId]);

    // audit
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'change_role', userId, JSON.stringify({ chatId, role })]
      );
    } catch (e) { /* ignore audit errors */ }

    return res.json({ ok: true });
  } catch (err) {
    console.error('chats.members.role error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

module.exports = router;

\`\`\`

## server/src/routes/auth.js

```javascript
// server/src/routes/auth.js
const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const validator = require('validator');
const jwt = require('jsonwebtoken');
const db = require('../db'); // предполагается, что db экспортирует функцию query
const { authMiddleware } = require('../utils/auth');
require('dotenv').config();

const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

// Настройки для Creator
const CREATOR_EMAIL = 'zerotwo02166@gmail.com';
const CREATOR_SECRET = process.env.CREATOR_SECRET || 'Макарова Лиза';

function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}

/**
 * POST /api/auth/check_email
 * body: { email }
 */
router.post('/check_email', async (req, res) => {
  try {
    const { email } = req.body || {};
    if (!email) return res.status(400).json({ error: 'email required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email' });
    }

    const existing = await db.query('SELECT 1 FROM users WHERE email = $1', [normalizedEmail]);
    return res.json({ exists: existing.rowCount > 0 });
  } catch (err) {
    console.error('check_email error', err);
    return res.status(500).json({ error: 'Server error' });
  }
});

/**
 * POST /api/auth/register
 * body: { email, password, name?, phone?, secret? }
 *
 * Notes:
 * - If email equals CREATOR_EMAIL and correct secret provided, role becomes 'creator'
 * - Returns { token, user: { id, email, name, role } }
 */
router.post('/register', async (req, res) => {
  try {
    const { email, password, name, phone, secret } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }
    if (typeof password !== 'string' || password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    await db.query('BEGIN');

    const existing = await db.query('SELECT id FROM users WHERE email = $1', [normalizedEmail]);
    if (existing.rowCount > 0) {
      await db.query('ROLLBACK');
      return res.status(409).json({ error: 'Email already registered' });
    }

    let role = 'client';
    if (normalizedEmail.toLowerCase() === CREATOR_EMAIL.toLowerCase()) {
      if (typeof secret === 'string' && secret === CREATOR_SECRET) {
        role = 'creator';
      } else {
        await db.query('ROLLBACK');
        return res.status(403).json({ error: 'Invalid secret for this email' });
      }
    }

    const password_hash = await bcrypt.hash(password, SALT_ROUNDS);
    const insertUser = await db.query(
      'INSERT INTO users (email, password_hash, name, role, created_at) VALUES ($1, $2, $3, $4, now()) RETURNING id, email, name, role',
      [normalizedEmail, password_hash, name || null, role]
    );
    const user = insertUser.rows[0];

    if (phone) {
      const normalizedPhone = String(phone).replace(/\D/g, '');
      if (normalizedPhone.length < 10) {
        await db.query('ROLLBACK');
        return res.status(400).json({ error: 'Invalid phone format' });
      }
      await db.query(
        `INSERT INTO phones (user_id, phone, status, created_at)
         VALUES ($1, $2, 'pending_verification', now())
         ON CONFLICT (user_id) DO UPDATE SET phone = $2, status = 'pending_verification', created_at = now()`,
        [user.id, normalizedPhone]
      );
    }

    await db.query('COMMIT');

    const token = signToken({ id: user.id, email: user.email, role: user.role });

    return res.status(201).json({
      token,
      user: { id: user.id, email: user.email, name: user.name, role: user.role }
    });
  } catch (err) {
    try { await db.query('ROLLBACK'); } catch (_) {}
    console.error('auth.register error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/auth/login
 * body: { email, password }
 *
 * Returns { token, user: { id, email, role } }
 */
router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const normalizedEmail = validator.normalizeEmail(email);
    if (!normalizedEmail || !validator.isEmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Неверный логин или пароль' });
    }

    const userRes = await db.query('SELECT id, email, password_hash, role FROM users WHERE email = $1', [normalizedEmail]);
    const user = userRes.rows[0];
    if (!user) return res.status(401).json({ error: 'Неверные данные' });

    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) return res.status(401).json({ error: 'Неверные данные' });

    const token = signToken({ id: user.id, email: user.email, role: user.role });
    return res.json({
      token,
      user: { id: user.id, email: user.email, role: user.role }
    });
  } catch (err) {
    console.error('auth.login error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/logout', (req, res) => {
  // Здесь можно делать audit, удалять refresh-токены и т.д.
  res.json({ ok: true, message: 'Logged out (stateless JWT)' });
});

/**
 * POST /api/auth/change_password (защищённый)
 */
router.post('/change_password', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const { oldPassword, newPassword } = req.body || {};
    if (!oldPassword || !newPassword || newPassword.length < 8) {
      return res.status(400).json({ error: 'Old and new password (min 8 chars) required' });
    }

    const { rows } = await db.query('SELECT password_hash FROM users WHERE id=$1', [userId]);
    if (!rows.length) return res.status(404).json({ error: 'Пользователь не найден' });

    const currentHash = rows[0].password_hash;
    const match = await bcrypt.compare(oldPassword, currentHash);
    if (!match) return res.status(403).json({ error: 'Старый пароль неверный' });

    const newHash = await bcrypt.hash(newPassword, SALT_ROUNDS);
    await db.query('UPDATE users SET password_hash=$1 WHERE id=$2', [newHash, userId]);

    return res.json({ ok: true, message: 'Пароль изменён' });
  } catch (err) {
    console.error('auth.change_password error', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

module.exports = router;

\`\`\`

## server/src/middleware/requireAuth.js

```javascript
const jwt = require('jsonwebtoken');

module.exports = function requireAuth(req, res, next) {
  try {
    const authHeader = req.headers.authorization;

    console.log('AUTH HEADER:', authHeader);

    if (!authHeader) {
      return res.status(401).json({
        ok: false,
        error: 'No token provided'
      });
    }

    if (!authHeader.startsWith('Bearer ')) {
      return res.status(401).json({
        ok: false,
        error: 'Invalid token format'
      });
    }

    const token = authHeader.substring(7);

    const decoded = jwt.verify(
      token,
      process.env.JWT_SECRET || 'dev_secret'
    );

    console.log('JWT DECODED:', decoded);

    // КРИТИЧЕСКИЙ FIX
    req.user = {
      id: decoded.id,
      email: decoded.email,
      role: decoded.role
    };

    next();

  } catch (err) {
    console.error('AUTH ERROR:', err.message);

    return res.status(401).json({
      ok: false,
      error: 'Invalid token'
    });
  }
};
\`\`\`

## app/main.py

```python
# app/main.py
# Точка входа FastAPI. Создание таблиц выполняется в событии startup с обработкой ошибок.

import logging
import time
from contextlib import asynccontextmanager
from typing import List

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.db.session import engine
from app.db.base import Base
from app.core.config import settings

# Импорт моделей, чтобы SQLAlchemy видел их определения
import app.models.user
import app.models.product
import app.models.cart
import app.models.order

# Настройка логирования
logging.basicConfig(level=settings.LOG_LEVEL)
logger = logging.getLogger(__name__)


def try_create_tables(retries: int = 5, delay: int = 2) -> bool:
    """
    Пытаемся создать таблицы с повторными попытками.
    Если БД недоступна, логируем ошибку и пробуем снова.

    Args:
        retries: Количество попыток подключения
        delay: Задержка между попытками в секундах

    Returns:
        True если таблицы созданы/существуют, False если все попытки исчерпаны
    """
    for attempt in range(1, retries + 1):
        try:
            logger.info(f"Попытка создания таблиц ({attempt}/{retries})...")
            Base.metadata.create_all(bind=engine)
            logger.info("✅ Database tables created (or already exist).")
            return True
        except Exception as e:
            logger.warning(f"❌ Attempt {attempt}/{retries} failed to create tables: {e}")
            if attempt < retries:
                logger.info(f"⏳ Waiting {delay}s before retry...")
                time.sleep(delay)
            else:
                logger.error(
                    f"❌ Could not create tables after {retries} retries. "
                    "Database initialization failed. Startup cannot continue."
                )
                return False


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Управление жизненным циклом приложения.
    Запускается при старте и завершении приложения.
    """
    # Startup
    logger.info("🚀 FastAPI starting up...")
    if not try_create_tables(retries=5, delay=2):
        logger.error("⚠️ Failed to create database tables. Application may not work correctly.")
        # В production должны было бы выкинуть исключение, но для разработки продолжаем
        if settings.ENVIRONMENT in ("production", "prod"):
            raise RuntimeError("Cannot start application: database tables creation failed")

    yield

    # Shutdown
    logger.info("🛑 FastAPI shutting down...")
    try:
        engine.dispose()
        logger.info("✅ Database connection closed")
    except Exception as e:
        logger.error(f"Error closing database: {e}")


# Создаём FastAPI приложение с управлением жизненным циклом
app = FastAPI(
    title="ProjectPhoenix API",
    description="API для приложения ProjectPhoenix",
    version="1.0.0",
    lifespan=lifespan
)

# CORS middleware для разработки (ограничить в продакшене!)
if settings.ENVIRONMENT == "development":
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    # В продакшене указать конкретные домены
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["https://yourdomain.com"],
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "DELETE"],
        allow_headers=["*"],
    )

# Подключаем роутеры
try:
    from app.api import auth as auth_router

    app.include_router(auth_router.router, prefix="/api/auth", tags=["auth"])
    logger.info("✅ Auth router included")
except ImportError as e:
    logger.error(f"❌ Failed to import auth router: {e}")


# Базовые health check endpoints
@app.get("/", tags=["health"])
async def root():
    """Базовый health check."""
    return {
        "status": "ok",
        "service": "ProjectPhoenix API",
        "environment": settings.ENVIRONMENT
    }


@app.get("/health", tags=["health"])
async def health():
    """Детальный health check."""
    return {
        "status": "healthy",
        "database": "connected",
        "version": "1.0.0"
    }


# Глобальный обработчик исключений
@app.exception_handler(Exception)
async def global_exception_handler(request, exc):
    """Глобальный обработчик ошибок."""
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return {
        "status": "error",
        "message": "Internal server error",
        "detail": str(exc) if settings.ENVIRONMENT == "development" else "An error occurred"
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=settings.ENVIRONMENT == "development",
        log_level=settings.LOG_LEVEL.lower()
    )
\`\`\`

## server/src/utils/auth.js

```javascript
// server/src/utils/auth.js
const jwt = require('jsonwebtoken');
require('dotenv').config();

const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const NODE_ENV = process.env.NODE_ENV || 'development';

let verifyTokenFn = null;
// Try to use local jwt util if present (server/src/utils/jwt.js)
try {
  // eslint-disable-next-line global-require
  const { verifyJwt } = require('./jwt');
  if (typeof verifyJwt === 'function') verifyTokenFn = (token) => verifyJwt(token);
} catch (e) {
  // ignore, fallback to jwt.verify below
  verifyTokenFn = null;
}

function getTokenFromHeader(authHeader) {
  if (!authHeader) return null;
  if (authHeader.startsWith('Bearer ')) return authHeader.slice(7);
  if (authHeader.startsWith('bearer ')) return authHeader.slice(7);
  return null;
}

function verifyToken(token) {
  if (!token) return null;
  if (verifyTokenFn) {
    try {
      return verifyTokenFn(token);
    } catch (e) {
      if (NODE_ENV !== 'production') console.error('verifyJwt util error:', e && e.message ? e.message : e);
      return null;
    }
  }
  try {
    return jwt.verify(token, JWT_SECRET);
  } catch (err) {
    if (NODE_ENV !== 'production') {
      console.error('jwt.verify error:', err && err.message ? err.message : err);
    }
    return null;
  }
}

function authMiddleware(req, res, next) {
  const auth = req.headers.authorization || req.headers.Authorization;
  if (NODE_ENV !== 'production') {
    console.log('AUTH HEADER:', auth);
  }

  const token = getTokenFromHeader(auth);
  if (!token) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const payload = verifyToken(token);
  if (!payload) {
    if (NODE_ENV !== 'production') {
      console.error('Token verify failed or expired');
    }
    return res.status(401).json({ error: 'Invalid token' });
  }

  // Normalize req.user to include common fields and default role
  req.user = {
    id: payload.id || payload.userId || null,
    email: payload.email || payload.sub || null,
    role: payload.role || 'client',
    ...payload
  };

  return next();
}

function requireAdmin(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Unauthorized' });
  const isAdminFlag = !!req.user.isAdmin;
  const role = (req.user.role || '').toString().toLowerCase();
  if (!isAdminFlag && role !== 'admin' && role !== 'creator' && role !== 'superadmin') {
    return res.status(403).json({ error: 'Forbidden' });
  }
  return next();
}

module.exports = { authMiddleware, requireAdmin };

```

