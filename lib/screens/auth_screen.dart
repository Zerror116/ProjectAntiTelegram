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
    final ok = await _authServiceTryRefresh();
    setState(() => _loading = false);
    if (ok) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    }
  }

  Future<bool> _authServiceTryRefresh() async {
    try {
      return await _authService.tryRefreshOnStartup();
    } catch (_) {
      return false;
    }
  }

  /// Проверяем занятость email на сервере
  Future<bool> _checkEmailExists(String email) async {
    try {
      final resp = await _authService.dio.post(
        '/api/auth/check_email',
        data: {'email': email},
      );
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
          MaterialPageRoute(
            builder: (_) => const PhoneNameScreen(isRegisterFlow: true),
          ),
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
        final name = (user['name'] ?? '').toString().trim();
        final phone = (user['phone'] ?? '').toString().trim();
        final hasName = name.isNotEmpty;
        final hasPhone = phone.isNotEmpty;

        // Экран добора данных нужен только если имя/номер действительно отсутствуют.
        if (!hasName || !hasPhone) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => const PhoneNameScreen(isRegisterFlow: false),
            ),
          );
          return;
        }

        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainShell()),
        );
        return;
      } catch (e) {
        debugPrint(
          'auth.login: profile check failed, continue to MainShell: $e',
        );
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainShell()),
        );
        return;
      }
    } on DioException catch (e) {
      String friendly = 'Ошибка';
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        friendly =
            'Пупупу, ошибочка — что-то не так с email или паролем. Пытаетесь кого-то взломать? 😉';
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
              child: Column(
                children: [
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
                      if (v.length < 8)
                        return 'Пароль должен быть не менее 8 символов';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _onSubmitPressed,
                      child: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(_isRegister ? 'Далее' : 'Войти'),
                    ),
                  ),
                ],
              ),
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
            if (_message.isNotEmpty)
              Text(_message, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    );
  }
}
