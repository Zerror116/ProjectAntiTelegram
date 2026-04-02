// lib/screens/auth_screen.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../main.dart'; // глобальный authService и dio
import '../widgets/input_language_badge.dart';
import '../widgets/submit_on_enter.dart';

import 'pwa_guide_screen.dart';
import 'phone_name_screen.dart';
import 'phone_access_pending_screen.dart';
import 'main_shell.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const String _creatorEmail = 'zerotwo02166@gmail.com';
  static const String _iosHomeHintShownKey = 'web_ios_add_to_home_hint_seen_v2';
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
  bool _apkInfoLoading = false;
  String? _apkDownloadUrl;
  String _apkInfoMessage = '';
  String _tenantCodeFromLink = '';
  bool _handledIncomingAuthAction = false;
  bool _emailRecoveryEnabled = false;
  bool _emailRecoveryStatusLoaded = false;
  bool _registrationEmailCodeEnabled = false;

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
      _tenantCodeFromLink = tenantFromLink;
      _authService.setTenantCode(tenantFromLink);
    }

    final inviteFromLink = _extractInviteFromUri();
    if (inviteFromLink.isNotEmpty) {
      _accessKeyController.text = inviteFromLink;
      _isRegister = true;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _prepareWebExperience();
      unawaited(_loadEmailRecoveryAvailability());
      unawaited(_handleIncomingAuthActionIfNeeded());
    });
  }

  void _prepareWebExperience() {
    if (!kIsWeb) return;
    if (_isAndroidWeb()) {
      _loadApkDownloadUrl();
      return;
    }
    _maybeShowIosAddToHomeHint();
  }

  bool _isIosWeb() {
    return kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool _isAndroidWeb() {
    return kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  bool _isAndroidWebRestricted() {
    return _isAndroidWeb();
  }

  String _extractServerMessage(
    Object error, {
    String fallback = 'Ошибка сети',
  }) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && (data['error'] != null || data['message'] != null)) {
        return (data['error'] ?? data['message']).toString();
      }
      final message = (error.message ?? '').trim();
      if (message.isNotEmpty) return message;
    }
    return fallback;
  }

  Future<void> _loadApkDownloadUrl() async {
    if (!kIsWeb) return;
    setState(() {
      _apkInfoLoading = true;
      _apkInfoMessage = '';
    });
    try {
      final resp = await dio.get(
        '/api/app/update',
        options: Options(
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
        ),
      );
      String? nextUrl;
      final root = resp.data;
      if (root is Map) {
        final data = root['data'];
        if (data is Map) {
          final android = data['android'];
          if (android is Map) {
            final raw = (android['download_url'] ?? '').toString().trim();
            if (raw.isNotEmpty) {
              nextUrl = raw;
            }
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _apkDownloadUrl = nextUrl;
        _apkInfoMessage = nextUrl == null || nextUrl.isEmpty
            ? 'APK пока не настроен на сервере'
            : 'Скачать Android APK';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _apkDownloadUrl = null;
        _apkInfoMessage = _extractServerMessage(
          e,
          fallback: 'Не удалось получить ссылку APK',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _apkInfoLoading = false;
        });
      }
    }
  }

  Future<void> _openApkDownload() async {
    if (!_isAndroidWeb()) {
      showAppNotice(
        context,
        'Скачивание APK доступно только с Android-устройств',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Скачать APK'),
          content: const Text(
            'Подтвердите загрузку APK. Установка доступна только на Android.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Скачать'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (confirmed != true) return;

    final raw = (_apkDownloadUrl ?? '').trim();
    if (raw.isEmpty) {
      showAppNotice(
        context,
        'Ссылка на APK пока не настроена на сервере',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      showAppNotice(
        context,
        'Некорректная ссылка APK',
        tone: AppNoticeTone.error,
      );
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!mounted) return;
    if (!opened) {
      showAppNotice(
        context,
        'Не удалось открыть ссылку APK',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _copyApkLink() async {
    final raw = (_apkDownloadUrl ?? '').trim();
    if (raw.isEmpty) {
      showAppNotice(
        context,
        'Ссылка APK пока не настроена на сервере',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: raw));
    if (!mounted) return;
    showAppNotice(
      context,
      'Ссылка APK скопирована',
      tone: AppNoticeTone.success,
    );
  }

  Future<void> _copyInviteCodeFromLink() async {
    final inviteCode = _accessKeyController.text.trim();
    if (inviteCode.isEmpty) {
      showAppNotice(
        context,
        'Код приглашения не найден в ссылке',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: inviteCode));
    if (!mounted) return;
    showAppNotice(
      context,
      'Код приглашения скопирован',
      tone: AppNoticeTone.success,
    );
  }

  Future<void> _maybeShowIosAddToHomeHint() async {
    if (!_isIosWeb()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyShown = prefs.getBool(_iosHomeHintShownKey) == true;
      if (alreadyShown || !mounted) return;
      await prefs.setBool(_iosHomeHintShownKey, true);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      final action = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Как добавить сайт в быстрый доступ'),
            content: const Text(
              'Чтобы открывать сайт как приложение, добавьте его на экран «Домой»:\n\n'
              'Safari → Поделиться → На экран «Домой».',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop('later'),
                child: const Text('Позже'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop('guide'),
                child: const Text('Показать шаги'),
              ),
            ],
          );
        },
      );
      if (!mounted || action != 'guide') return;
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const PwaGuideScreen()));
    } catch (_) {
      // ignore
    }
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

  String _extractUriParam(Iterable<String> keys) {
    try {
      final uri = Uri.base;
      for (final key in keys) {
        final direct = (uri.queryParameters[key] ?? '').trim();
        if (direct.isNotEmpty) return direct;
      }
      if (uri.fragment.isNotEmpty) {
        final fragment = uri.fragment;
        final qIndex = fragment.indexOf('?');
        if (qIndex >= 0 && qIndex + 1 < fragment.length) {
          final inFragment = Uri.splitQueryString(fragment.substring(qIndex + 1));
          for (final key in keys) {
            final value = (inFragment[key] ?? '').trim();
            if (value.isNotEmpty) return value;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  String _extractAuthActionFromUri() {
    return _extractUriParam(const ['auth_action']).trim().toLowerCase();
  }

  String _extractAuthTokenFromUri() {
    return _extractUriParam(const ['token']).trim();
  }

  String _extractSuccessMessage(
    Object? payload, {
    required String fallback,
  }) {
    if (payload is Map && (payload['message'] != null || payload['success'] != null)) {
      return (payload['message'] ?? payload['success']).toString();
    }
    return fallback;
  }

  void _replaceAppRoot(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => screen),
      (route) => false,
    );
  }

  Future<void> _navigateAfterSuccessfulAuth() async {
    Widget nextScreen = const MainShell();
    try {
      final refreshed = await _authService.tryRefreshOnStartup().timeout(
        const Duration(seconds: 8),
        onTimeout: () => _authService.currentUser != null,
      );
      final user = _authService.currentUser;
      if (user == null) {
        _replaceAppRoot(nextScreen);
        return;
      }
      final name = (user.name ?? '').trim();
      final phone = (user.phone ?? '').trim();
      final phoneAccessState = (user.phoneAccessState ?? '')
          .trim()
          .toLowerCase();
      final hasName = name.isNotEmpty;
      final hasPhone = phone.isNotEmpty;

      if (phoneAccessState == 'pending' || phoneAccessState == 'rejected') {
        nextScreen = const PhoneAccessPendingScreen();
      } else if (!hasName || !hasPhone) {
        if (refreshed && !_authService.lastStartupRefreshUsedFallback) {
          nextScreen = const PhoneNameScreen(isRegisterFlow: false);
        } else {
          debugPrint(
            'auth.login: profile is incomplete or not freshly confirmed, keep MainShell for now',
          );
        }
      }
    } catch (e) {
      debugPrint('auth.login: profile check failed, continue to MainShell: $e');
    }
    _replaceAppRoot(nextScreen);
  }

  Future<void> _requestEmailAction({
    required bool magicLink,
  }) async {
    final controller = TextEditingController(text: _emailController.text.trim());
    final enteredEmail = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            magicLink ? 'Войти по ссылке' : 'Сбросить пароль',
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: magicLink ? 'Почта для входа' : 'Почта для сброса',
              hintText: 'name@example.com',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: Text(magicLink ? 'Отправить ссылку' : 'Отправить письмо'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final email = enteredEmail?.trim() ?? '';
    if (email.isEmpty) return;
    if (!email.contains('@')) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Введите корректный email',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _loading = true;
      _message = '';
      _requiresTwoFactor = false;
    });

    try {
      final resp = await _authService.dio.post(
        magicLink
            ? '/api/auth/magic-link/request'
            : '/api/auth/password-reset/request',
        data: {'email': email},
      );
      _emailController.text = email;
      if (!mounted) return;
      showAppNotice(
        context,
        _extractSuccessMessage(
          resp.data,
          fallback: magicLink
              ? 'Если аккаунт существует, мы отправили ссылку для входа на почту'
              : 'Если аккаунт существует, мы отправили письмо для сброса пароля',
        ),
        tone: AppNoticeTone.success,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      setState(
        () => _message = _extractServerMessage(
          e,
          fallback: magicLink
              ? 'Не удалось отправить ссылку для входа'
              : 'Не удалось отправить письмо для сброса пароля',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _showPasswordResetDialog(String token) async {
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    try {
      final passwords = await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Новый пароль'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: newPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Новый пароль',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Повторите пароль',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Позже'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop([
                  newPasswordController.text,
                  confirmPasswordController.text,
                ]),
                child: const Text('Сохранить пароль'),
              ),
            ],
          );
        },
      );
      if (passwords == null || passwords.length < 2) return;
      final newPassword = passwords[0].trim();
      final confirmPassword = passwords[1].trim();
      if (newPassword.length < 8) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Пароль должен быть не менее 8 символов',
          tone: AppNoticeTone.warning,
        );
        return;
      }
      if (newPassword != confirmPassword) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Пароли не совпадают',
          tone: AppNoticeTone.warning,
        );
        return;
      }

      setState(() {
        _loading = true;
        _message = '';
        _isRegister = false;
      });
      try {
        final resp = await _authService.dio.post(
          '/api/auth/password-reset/confirm',
          data: {
            'token': token,
            'new_password': newPassword,
          },
        );
        if (!mounted) return;
        showAppNotice(
          context,
          _extractSuccessMessage(
            resp.data,
            fallback: 'Пароль обновлён. Теперь можно войти с новым паролем.',
          ),
          tone: AppNoticeTone.success,
        );
      } on DioException catch (e) {
        if (!mounted) return;
        setState(
          () => _message = _extractServerMessage(
            e,
            fallback: 'Не удалось обновить пароль',
          ),
        );
      } finally {
        if (mounted) {
          setState(() => _loading = false);
        }
      }
    } finally {
      newPasswordController.dispose();
      confirmPasswordController.dispose();
    }
  }

  Future<void> _consumeMagicLogin(String token) async {
    if (_isAndroidWebRestricted()) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Вход по ссылке в Android-браузере не поддерживается. Откройте письмо на компьютере или войдите в установленном приложении.',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _loading = true;
      _message = '';
      _isRegister = false;
      _requiresTwoFactor = false;
    });
    try {
      final fingerprint = await _authService.getDeviceFingerprintForRequest();
      final resp = await _authService.dio.post(
        '/api/auth/magic-link/consume',
        data: {
          'token': token,
          if (fingerprint != null && fingerprint.trim().isNotEmpty)
            'device_fingerprint': fingerprint.trim(),
        },
      );
      final payload =
          resp.data is Map<String, dynamic>
              ? resp.data as Map<String, dynamic>
              : Map<String, dynamic>.from(resp.data as Map);
      final nextToken = (payload['token'] ?? '').toString().trim();
      final userMap =
          payload['user'] is Map
              ? Map<String, dynamic>.from(payload['user'] as Map)
              : null;
      if (nextToken.isEmpty || userMap == null) {
        throw Exception('Сервер не вернул данные входа');
      }
      await _authService.applyLoginResponse(nextToken, userMap);
      if (!mounted) return;
      showAppNotice(
        context,
        'Вход по ссылке выполнен',
        tone: AppNoticeTone.success,
      );
      await _navigateAfterSuccessfulAuth();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(
        () => _message = _extractServerMessage(
          e,
          fallback: 'Не удалось выполнить вход по ссылке',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка входа по ссылке: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _handleIncomingAuthActionIfNeeded() async {
    if (_handledIncomingAuthAction || !mounted) return;
    final action = _extractAuthActionFromUri();
    final token = _extractAuthTokenFromUri();
    if (action.isEmpty || token.isEmpty) return;
    _handledIncomingAuthAction = true;
    if (action == 'magic_login') {
      await _consumeMagicLogin(token);
      return;
    }
    if (action == 'password_reset') {
      await _showPasswordResetDialog(token);
    }
  }

  Future<void> _loadEmailRecoveryAvailability() async {
    try {
      final resp = await _authService.dio.get(
        '/api/auth/email-auth/status',
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      final data = resp.data is Map ? Map<String, dynamic>.from(resp.data as Map) : const <String, dynamic>{};
      final payload =
          data['data'] is Map
              ? Map<String, dynamic>.from(data['data'] as Map)
              : const <String, dynamic>{};
      final passwordResetEnabled =
          payload['password_reset_enabled'] == true ||
          payload['mail_configured'] == true;
      final magicLinkEnabled =
          payload['magic_link_enabled'] == true ||
          payload['mail_configured'] == true;
      final registrationEmailCodeEnabled =
          payload['registration_email_code_enabled'] == true ||
          payload['mail_configured'] == true;
      if (!mounted) return;
      setState(() {
        _emailRecoveryEnabled = passwordResetEnabled || magicLinkEnabled;
        _registrationEmailCodeEnabled = registrationEmailCodeEnabled;
        _emailRecoveryStatusLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _emailRecoveryEnabled = false;
        _registrationEmailCodeEnabled = false;
        _emailRecoveryStatusLoaded = true;
      });
    }
  }

  Future<String?> _requestRegistrationEmailVerification(String email) async {
    Future<void> sendCode({bool resent = false}) async {
      final resp = await _authService.dio.post(
        '/api/auth/register/email-code/request',
        data: {'email': email},
      );
      if (!mounted) return;
      showAppNotice(
        context,
        _extractSuccessMessage(
          resp.data,
          fallback: resent
              ? 'Мы отправили новый код подтверждения на почту'
              : 'Мы отправили 6-значный код подтверждения на почту',
        ),
        tone: AppNoticeTone.success,
      );
    }

    await sendCode();
    while (mounted) {
      if (!mounted) return null;
      final codeController = TextEditingController();
      try {
        final action = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Подтвердите почту'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Мы отправили код на $email'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: codeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Код из 6 цифр',
                      hintText: '123456',
                    ),
                    autofocus: true,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('__resend__'),
                  child: const Text('Отправить заново'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(codeController.text.trim()),
                  child: const Text('Подтвердить'),
                ),
              ],
            );
          },
        );
        if (action == null) return null;
        if (action == '__resend__') {
          await sendCode(resent: true);
          continue;
        }
        final code = action.trim();
        if (!RegExp(r'^\d{6}$').hasMatch(code)) {
          if (!mounted) return null;
          showAppNotice(
            context,
            'Введите 6-значный код из письма',
            tone: AppNoticeTone.warning,
          );
          continue;
        }

        final resp = await _authService.dio.post(
          '/api/auth/register/email-code/verify',
          data: {
            'email': email,
            'code': code,
          },
        );
        final data =
            resp.data is Map
                ? Map<String, dynamic>.from(resp.data as Map)
                : const <String, dynamic>{};
        final verificationToken =
            (data['registration_email_token'] ?? '').toString().trim();
        if (verificationToken.isEmpty) {
          throw Exception('Сервер не вернул токен подтверждения');
        }
        if (!mounted) return null;
        showAppNotice(
          context,
          _extractSuccessMessage(
            data,
            fallback: 'Почта подтверждена. Продолжаем регистрацию.',
          ),
          tone: AppNoticeTone.success,
        );
        return verificationToken;
      } on DioException catch (e) {
        if (!mounted) return null;
        showAppNotice(
          context,
          _extractServerMessage(
            e,
            fallback: 'Не удалось подтвердить код',
          ),
          tone: AppNoticeTone.error,
        );
      } catch (e) {
        if (!mounted) return null;
        showAppNotice(
          context,
          'Ошибка подтверждения: $e',
          tone: AppNoticeTone.error,
        );
      } finally {
        codeController.dispose();
      }
    }
    return null;
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
        if (!_emailRecoveryStatusLoaded) {
          await _loadEmailRecoveryAvailability();
        }
        // Сначала проверяем, занят ли email
        final exists = await _checkEmailExists(email);
        if (exists) {
          setState(() {
            _message = 'Email уже занят';
            _loading = false;
          });
          return;
        }

        String? registrationEmailToken;
        if (_registrationEmailCodeEnabled) {
          registrationEmailToken = await _requestRegistrationEmailVerification(
            email,
          );
          if (registrationEmailToken == null ||
              registrationEmailToken.trim().isEmpty) {
            setState(() {
              _message = 'Подтверждение почты отменено';
              _loading = false;
            });
            return;
          }
        }

        // Email свободен — сохраняем pending данные и переходим на экран ввода имени+телефона
        _authService.setPendingCredentials(
          email: email,
          password: password,
          accessKey: accessKey,
          registrationEmailToken: registrationEmailToken,
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

      await _navigateAfterSuccessfulAuth();
      return;
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
    if (_isAndroidWebRestricted()) {
      final theme = Theme.of(context);
      final inviteCode = _accessKeyController.text.trim().toUpperCase();
      final tenantCode = _tenantCodeFromLink.trim().toLowerCase();
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF123A8A), Color(0xFF1A56C4)],
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x331A56C4),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Android APK',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Веб-версия на Android отключена',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Для Android доступна только установка приложения (APK). После установки войдите с кодом вашей группы.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Как войти в приложении',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text('1. Нажмите кнопку «Скачать APK».'),
                          const SizedBox(height: 4),
                          const Text('2. Установите приложение на Android.'),
                          const SizedBox(height: 4),
                          const Text(
                            '3. На экране регистрации вставьте код приглашения.',
                          ),
                          if (inviteCode.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            SelectableText(
                              'Код приглашения: $inviteCode',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                          if (tenantCode.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SelectableText(
                              'Группа: $tenantCode',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _apkInfoLoading ? null : _openApkDownload,
                      icon: const Icon(Icons.android_rounded),
                      label: Text(
                        _apkInfoLoading
                            ? 'Загрузка...'
                            : 'Скачать APK (только Android)',
                      ),
                    ),
                  ),
                  if (inviteCode.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _copyInviteCodeFromLink,
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('Скопировать код приглашения'),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _copyApkLink,
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('Скопировать ссылку APK'),
                      ),
                    ),
                  ],
                  if (_apkInfoMessage.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _apkInfoMessage.trim(),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(_isRegister ? 'Регистрация' : 'Вход')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SubmitOnEnter(
              enabled: !_loading,
              onSubmit: () => unawaited(_onSubmitPressed()),
              child: Form(
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
                    if (!_isRegister &&
                        _emailRecoveryStatusLoaded &&
                        _emailRecoveryEnabled) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: _loading
                                  ? null
                                  : () => _requestEmailAction(magicLink: false),
                              child: const Text('Забыли пароль?'),
                            ),
                          ),
                          Expanded(
                            child: TextButton(
                              onPressed: _loading
                                  ? null
                                  : () => _requestEmailAction(magicLink: true),
                              child: const Text('Войти без пароля'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
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
