// lib/screens/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../services/auth_service.dart';
import '../main.dart'; // глобальный authService и dio
import '../widgets/input_language_badge.dart';

import 'phone_name_screen.dart';
import 'main_shell.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const String _creatorEmail = 'zerotwo02166@gmail.com';
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _accessKeyController = TextEditingController();
  final _otpController = TextEditingController();
  bool _loading = false;
  String _message = '';
  bool _isRegister = false;
  bool _requiresTwoFactor = false;
  bool _trustDeviceFor30Days = true;

  late final AuthService _authService;

  // listeners so we can remove them properly
  late final VoidCallback _emailListener;
  late final VoidCallback _passwordListener;
  late final VoidCallback _accessKeyListener;
  late final VoidCallback _otpListener;

  @override
  void initState() {
    super.initState();
    _authService = authService;

    // Подписываемся на контроллеры, чтобы гарантированно перерисовывать UI при вводе
    _emailListener = () => setState(() {});
    _passwordListener = () => setState(() {});
    _accessKeyListener = () => setState(() {});
    _otpListener = () => setState(() {});
    _emailController.addListener(_emailListener);
    _passwordController.addListener(_passwordListener);
    _accessKeyController.addListener(_accessKeyListener);
    _otpController.addListener(_otpListener);

    final tenantFromLink = _extractTenantFromUri();
    if (tenantFromLink.isNotEmpty) {
      _authService.setTenantCode(tenantFromLink);
    }

    final inviteFromLink = _extractInviteFromUri();
    if (inviteFromLink.isNotEmpty) {
      _accessKeyController.text = inviteFromLink;
      _isRegister = true;
    }

    _tryAutoLogin();
  }

  String _extractInviteFromUri() {
    try {
      final uri = Uri.base;
      final direct =
          uri.queryParameters['invite'] ?? uri.queryParameters['code'] ?? '';
      if (direct.trim().isNotEmpty) return direct.trim();
      if (uri.fragment.isNotEmpty) {
        final fragment = uri.fragment;
        final qIndex = fragment.indexOf('?');
        if (qIndex >= 0 && qIndex + 1 < fragment.length) {
          final inFragment = Uri.splitQueryString(
            fragment.substring(qIndex + 1),
          );
          final value = (inFragment['invite'] ?? inFragment['code'] ?? '')
              .trim();
          if (value.isNotEmpty) return value;
        }
      }
    } catch (_) {}
    return '';
  }

  String _extractTenantFromUri() {
    try {
      final uri = Uri.base;
      final direct =
          uri.queryParameters['tenant'] ??
          uri.queryParameters['tenant_code'] ??
          '';
      final normalizedDirect = _normalizeTenantCode(direct);
      if (normalizedDirect.isNotEmpty) return normalizedDirect;
      if (uri.fragment.isNotEmpty) {
        final fragment = uri.fragment;
        final qIndex = fragment.indexOf('?');
        if (qIndex >= 0 && qIndex + 1 < fragment.length) {
          final inFragment = Uri.splitQueryString(
            fragment.substring(qIndex + 1),
          );
          final normalizedFragment = _normalizeTenantCode(
            inFragment['tenant'] ?? inFragment['tenant_code'] ?? '',
          );
          if (normalizedFragment.isNotEmpty) return normalizedFragment;
        }
      }
    } catch (_) {}
    return '';
  }

  String _normalizeTenantCode(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return '';
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(value)) {
      return '';
    }
    return value;
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
    try {
      _accessKeyController.removeListener(_accessKeyListener);
    } catch (_) {}
    try {
      _otpController.removeListener(_otpListener);
    } catch (_) {}

    _emailController.dispose();
    _passwordController.dispose();
    _accessKeyController.dispose();
    _otpController.dispose();
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
    final accessKey = _accessKeyController.text.trim();

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
        _authService.setPendingCredentials(
          email: email,
          password: password,
          accessKey: accessKey,
        );
        if (!mounted) return;

        setState(() => _loading = false);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) =>
                PhoneNameScreen(isRegisterFlow: true, registrationEmail: email),
          ),
        );
        return;
      } else {
        // Обычный логин
        await _authService.login(
          email: email,
          password: password,
          otpCode: _requiresTwoFactor ? _otpController.text.trim() : null,
          trustDevice: _requiresTwoFactor ? _trustDeviceFor30Days : false,
        );
        _requiresTwoFactor = false;
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
      final body = e.response?.data;
      final bodyMap = body is Map ? Map<String, dynamic>.from(body) : null;
      final twoFactorRequired =
          bodyMap?['two_factor_required'] == true ||
          bodyMap?['twoFactorRequired'] == true;
      if (twoFactorRequired) {
        _otpController.clear();
        setState(() {
          _requiresTwoFactor = true;
          _trustDeviceFor30Days = true;
        });
        friendly =
            'Для этого аккаунта включена защита 2FA. Введите код из Google Authenticator или резервный код.';
      } else if (status == 401 || status == 403) {
        friendly = 'Неверный email, пароль или код подтверждения';
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        friendly = 'Время ожидания ответа сервера истекло. Попробуйте ещё раз.';
      } else if (bodyMap != null) {
        if (bodyMap['error'] != null || bodyMap['message'] != null) {
          friendly = (bodyMap['error'] ?? bodyMap['message']).toString();
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
                    decoration: withInputLanguageBadge(
                      const InputDecoration(labelText: 'Email'),
                      controller: _emailController,
                    ),
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
                    decoration: withInputLanguageBadge(
                      const InputDecoration(labelText: 'Пароль'),
                      controller: _passwordController,
                    ),
                    obscureText: true,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Введите пароль';
                      if (v.length < 8) {
                        return 'Пароль должен быть не менее 8 символов';
                      }
                      return null;
                    },
                  ),
                  if (!_isRegister && _requiresTwoFactor) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _otpController,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Код 2FA',
                          hintText: '6 цифр или резервный код (ABCD-EFGH)',
                        ),
                        controller: _otpController,
                      ),
                      keyboardType: TextInputType.text,
                      validator: (v) {
                        if (!_requiresTwoFactor) return null;
                        final value = (v ?? '').trim();
                        final digitsOnly = value.replaceAll(RegExp(r'\s+'), '');
                        final backupNormalized = value.toUpperCase().replaceAll(
                          RegExp(r'[^A-Z0-9]'),
                          '',
                        );
                        if (value.isEmpty) return 'Введите код 2FA';
                        final isTotp = RegExp(r'^\d{6}$').hasMatch(digitsOnly);
                        final isBackup = RegExp(
                          r'^[A-Z0-9]{8}$',
                        ).hasMatch(backupNormalized);
                        if (!isTotp && !isBackup) {
                          return 'Введите 6 цифр или резервный код ABCD-EFGH';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _trustDeviceFor30Days,
                      onChanged: (value) {
                        setState(() => _trustDeviceFor30Days = value == true);
                      },
                      title: const Text('Доверять устройству 30 дней'),
                      subtitle: const Text(
                        'На этом устройстве не будем спрашивать 2FA-код при следующем входе',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (_isRegister) ...[
                    TextFormField(
                      controller: _accessKeyController,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Ключ арендатора или код приглашения',
                          hintText:
                              'Арендатор: PHX-.... или сотрудник/клиент: INV-....',
                        ),
                        controller: _accessKeyController,
                      ),
                      validator: (v) {
                        final mail = _emailController.text.trim().toLowerCase();
                        final isCreator = mail == _creatorEmail.toLowerCase();
                        if (isCreator) return null;
                        if (v == null || v.trim().isEmpty) {
                          return 'Введите ключ арендатора или код приглашения';
                        }
                        if (v.trim().length < 6) {
                          return 'Код слишком короткий';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                  ] else
                    const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _onSubmitPressed,
                      child: _loading
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.onPrimary,
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
                    _requiresTwoFactor = false;
                    _trustDeviceFor30Days = true;
                    _otpController.clear();
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
