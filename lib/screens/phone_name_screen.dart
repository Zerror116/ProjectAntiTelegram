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

  String _extractDioMessage(dynamic e) {
    try {
      // Dio v5: DioException, v4: DioError
      final resp = (e is DioException) ? e.response : (e is DioError ? e.response : null);
      if (resp != null && resp.data != null) return resp.data.toString();
    } catch (_) {}
    return e?.toString() ?? 'Неизвестная ошибка';
  }

  Future<void> _saveTokenFlexible(String token) async {
    // Поддерживаем разные реализации authService: setToken или saveToken
    try {
      if ((authService).setToken is Function) {
        await authService.setToken(token);
        return;
      }
    } catch (_) {}
    try {
      if ((authService).saveToken is Function) {
        await authService.saveToken(token);
        return;
      }
    } catch (_) {}
    // fallback: просто сохраняем в SharedPreferences через authService API, если нет — игнорируем
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

        final respData = resp.data as Map<String, dynamic>?;
        final token = respData != null ? (respData['token'] ?? respData['access']) : null;
        if (token == null) {
          setState(() => _message = 'Регистрация прошла, но токен не получен от сервера.');
          return;
        }

        // Сохраняем токен гибко (поддержка разных authService)
        await _saveTokenFlexible(token as String);

        // Очистим pending
        try { authService.pendingEmail = null; authService.pendingPassword = null; } catch (_) {}

        // Попробуем обновить currentUser через профиль (если сервер не вернул user)
        try {
          if ((authService).setAuthHeaderFromStorage is Function) {
            await authService.setAuthHeaderFromStorage();
          } else {
            // Попытка получить профиль напрямую
            try {
              final profileResp = await authService.dio.get('/api/profile');
              if (profileResp.statusCode == 200 && profileResp.data is Map && profileResp.data['user'] is Map) {
                final userMap = Map<String, dynamic>.from(profileResp.data['user']);
                try {
                  if ((authService).applyLoginResponse is Function) {
                    await authService.applyLoginResponse(token as String, userMap);
                  }
                } catch (_) {}
              }
            } catch (_) {}
          }
        } catch (_) {}

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
            if ((authService).setAuthHeaderFromStorage is Function) {
              await authService.setAuthHeaderFromStorage();
            } else {
              // Попробуем получить профиль вручную
              final profileResp = await authService.dio.get('/api/profile');
              if (profileResp.statusCode == 200 && profileResp.data is Map && profileResp.data['user'] is Map) {
                final userMap = Map<String, dynamic>.from(profileResp.data['user']);
                try {
                  if ((authService).applyLoginResponse is Function) {
                    await authService.applyLoginResponse(await authService.getToken() ?? '', userMap);
                  }
                } catch (_) {}
              }
            }
          } catch (_) {}
          if (!mounted) return;
          Navigator.of(context).pop();
          return;
        } else {
          setState(() => _message = 'Ошибка обновления профиля');
        }
      }
    } catch (e) {
      final errMsg = _extractDioMessage(e);
      setState(() => _message = errMsg);
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
          onPressed: () {
            Navigator.of(context).pop();
          },
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
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Секретное слово (для создателя)',
                    hintText: 'Введите секретное слово',
                  ),
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Сохранить'),
                ),
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
