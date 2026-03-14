// lib/screens/phone_name_screen.dart
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../main.dart';
import 'phone_access_pending_screen.dart';
import '../utils/phone_utils.dart';
import '../widgets/input_language_badge.dart';

class PhoneNameScreen extends StatefulWidget {
  final bool isRegisterFlow;
  final String? registrationEmail;
  const PhoneNameScreen({
    super.key,
    this.isRegisterFlow = false,
    this.registrationEmail,
  });

  @override
  State<PhoneNameScreen> createState() => _PhoneNameScreenState();
}

class _PhoneNameScreenState extends State<PhoneNameScreen> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _groupNameCtrl = TextEditingController();
  final _mainChannelCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();

  late final VoidCallback _nameListener;
  late final VoidCallback _phoneListener;
  late final VoidCallback _groupNameListener;
  late final VoidCallback _mainChannelListener;
  late final VoidCallback _secretListener;

  bool _loading = false;
  String _message = '';

  static const String _creatorEmail = 'zerotwo02166@gmail.com';

  bool get _isCreatorPending {
    final pending = (widget.registrationEmail ?? authService.pendingEmail)
        ?.trim();
    return pending != null &&
        pending.toLowerCase() == _creatorEmail.toLowerCase();
  }

  bool get _isCreatorCurrentUser {
    final email = authService.currentUser?.email;
    return email != null && email.toLowerCase() == _creatorEmail.toLowerCase();
  }

  Future<void> _goNextAfterProfileCheck() async {
    try {
      final profileResp = await authService.dio.get('/api/profile');
      final root = (profileResp.data is Map)
          ? Map<String, dynamic>.from(profileResp.data as Map)
          : const <String, dynamic>{};
      final user = (root['user'] is Map)
          ? Map<String, dynamic>.from(root['user'] as Map)
          : const <String, dynamic>{};
      final phoneAccessState =
          (user['phone_access_state'] ?? user['phoneAccessState'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
      if (!mounted) return;
      if (phoneAccessState == 'pending' || phoneAccessState == 'rejected') {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const PhoneAccessPendingScreen()),
          (route) => false,
        );
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
  }

  bool get _shouldShowSecretField =>
      widget.isRegisterFlow ? _isCreatorPending : _isCreatorCurrentUser;

  String get _normalizedPendingAccessKey {
    return (authService.pendingAccessKey ?? '')
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
  }

  bool get _isTenantKeyRegistration {
    if (!widget.isRegisterFlow) return false;
    if (_isCreatorPending) return false;
    return _normalizedPendingAccessKey.startsWith('PHX');
  }

  Future<void> _handleBack() async {
    if (_loading) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    if (widget.isRegisterFlow) {
      authService.pendingEmail = null;
      authService.pendingPassword = null;
      authService.pendingAccessKey = null;
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/auth', (route) => false);
    }
  }

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
    _groupNameListener = () => setState(() {});
    _mainChannelListener = () => setState(() {});
    _secretListener = () => setState(() {});

    _nameCtrl.addListener(_nameListener);
    _phoneCtrl.addListener(_phoneListener);
    _groupNameCtrl.addListener(_groupNameListener);
    _mainChannelCtrl.addListener(_mainChannelListener);
    _secretCtrl.addListener(_secretListener);
  }

  @override
  void dispose() {
    try {
      _nameCtrl.removeListener(_nameListener);
    } catch (_) {}
    try {
      _phoneCtrl.removeListener(_phoneListener);
    } catch (_) {}
    try {
      _groupNameCtrl.removeListener(_groupNameListener);
    } catch (_) {}
    try {
      _mainChannelCtrl.removeListener(_mainChannelListener);
    } catch (_) {}
    try {
      _secretCtrl.removeListener(_secretListener);
    } catch (_) {}

    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _groupNameCtrl.dispose();
    _mainChannelCtrl.dispose();
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
    final groupName = _groupNameCtrl.text.trim();
    final mainChannelTitle = _mainChannelCtrl.text.trim();
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
      setState(
        () => _message =
            'Неверный формат номера. Примеры: 89991234567, +7 (999) 123-45-67',
      );
      return;
    }

    if (_shouldShowSecretField && secret.isEmpty) {
      setState(() => _message = 'Введите секретное слово');
      return;
    }
    if (_isTenantKeyRegistration && groupName.isEmpty) {
      setState(() => _message = 'Введите название вашей группы');
      return;
    }
    if (_isTenantKeyRegistration && mainChannelTitle.isEmpty) {
      setState(() => _message = 'Введите название основного канала');
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
        final pendingEmail =
            (authService.pendingEmail ?? widget.registrationEmail)?.trim();
        final pendingPassword = authService.pendingPassword;
        if (pendingEmail == null ||
            pendingEmail.isEmpty ||
            pendingPassword == null ||
            pendingPassword.isEmpty) {
          setState(
            () => _message =
                'Нет сохранённых данных регистрации. Повторите шаг регистрации.',
          );
          return;
        }

        final deviceFingerprint = await authService
            .getDeviceFingerprintForRequest();
        final data = {
          'email': pendingEmail,
          'password': pendingPassword,
          'name': name,
          'phone': apiPhone,
          if (deviceFingerprint != null && deviceFingerprint.trim().isNotEmpty)
            'device_fingerprint': deviceFingerprint.trim(),
          if ((authService.pendingAccessKey ?? '').trim().isNotEmpty)
            'access_key': authService.pendingAccessKey!.trim(),
        };
        if (_isCreatorPending) data['secret'] = secret;
        if (_isTenantKeyRegistration) {
          data['group_name'] = groupName;
          data['main_channel_title'] = mainChannelTitle;
        }

        final resp = await authService.dio.post(
          '/api/auth/register',
          data: data,
        );

        // ✅ ИСПРАВЛЕНИЕ: Cast правильно
        final respData = (resp.data as Map<dynamic, dynamic>)
            .cast<String, dynamic>();
        final token = respData['token'] ?? respData['access'];
        if (token == null) {
          setState(
            () => _message =
                'Регистрация прошла, но токен не получен от сервера.',
          );
          return;
        }

        // Сохраняем токен гибко (поддержка разных authService)
        await authService.applyLoginResponse(
          token as String,
          respData['user'] as Map<String, dynamic>?,
        );

        // Очистим pending
        try {
          authService.pendingEmail = null;
          authService.pendingPassword = null;
          authService.pendingAccessKey = null;
        } catch (_) {}

        if (!mounted) return;
        await _goNextAfterProfileCheck();
        return;
      } else {
        final profileData = {'name': name};
        if (_isCreatorCurrentUser) profileData['secret'] = secret;

        final p1 = authService.dio.post(
          '/api/profile/update',
          data: profileData,
        );
        final p2 = authService.dio.post(
          '/api/phones/request',
          data: {'phone': apiPhone},
        );
        final results = await Future.wait([p1, p2]);

        final ok1 =
            (results[0].statusCode == 200) ||
            (results[0].data is Map &&
                (results[0].data['ok'] == true ||
                    results[0].data['user'] != null));
        final ok2 =
            (results[1].statusCode == 200) ||
            (results[1].data is Map && results[1].data['ok'] == true);

        if (ok1 && ok2) {
          try {
            await authService.setAuthHeaderFromStorage();
          } catch (_) {}

          if (!mounted) return;
          await _goNextAfterProfileCheck();
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBack,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: withInputLanguageBadge(
                  const InputDecoration(labelText: 'Имя'),
                  controller: _nameCtrl,
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Номер телефона',
                    hintText: 'Например: +7 (999) 171-45-51 или 89991714551',
                  ),
                  controller: _phoneCtrl,
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 8),
              Text(
                'Важно: если номер будет недоступен при первом звонке, аккаунт будет удален автоматически.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 12),
              if (_shouldShowSecretField) ...[
                TextField(
                  controller: _secretCtrl,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(labelText: 'Секретное слово'),
                    controller: _secretCtrl,
                  ),
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 12),
              ],
              if (_isTenantKeyRegistration) ...[
                TextField(
                  controller: _groupNameCtrl,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Название вашей группы',
                      hintText: 'Например: Феникс Самара',
                    ),
                    controller: _groupNameCtrl,
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _mainChannelCtrl,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Название основного канала',
                      hintText: 'Например: Витрина Феникс',
                    ),
                    controller: _mainChannelCtrl,
                  ),
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 12),
              ],
              ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        widget.isRegisterFlow
                            ? 'Завершить регистрацию'
                            : 'Сохранить',
                      ),
              ),
              const SizedBox(height: 12),
              if (_message.isNotEmpty)
                Text(_message, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
    );
  }
}
