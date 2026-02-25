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

  // listeners references so we can remove them in dispose
  late final VoidCallback _nameListener;
  late final VoidCallback _phoneListener;
  late final VoidCallback _secretListener;

  bool _loading = false;
  String _message = '';

  // Жёстко захардкоженный email создателя
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
    // Попробуем предзаполнить поля из currentUser, если есть
    final u = authService.currentUser;
    if (u != null) {
      _nameCtrl.text = u.name ?? '';
      _phoneCtrl.text = u.phone ?? '';
    }

    // Инициализируем слушатели, чтобы гарантировать немедленную перерисовку при вводе
    _nameListener = () => setState(() {});
    _phoneListener = () => setState(() {});
    _secretListener = () => setState(() {});

    _nameCtrl.addListener(_nameListener);
    _phoneCtrl.addListener(_phoneListener);
    _secretCtrl.addListener(_secretListener);
  }

  @override
  void dispose() {
    // Удаляем слушатели и освобождаем контроллеры
    try {
      _nameCtrl.removeListener(_nameListener);
    } catch (_) {}
    try {
      _phoneCtrl.removeListener(_phoneListener);
    } catch (_) {}
    try {
      _secretCtrl.removeListener(_secretListener);
    } catch (_) {}

    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
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

        await authService.saveToken(token as String);
        authService.pendingEmail = null;
        authService.pendingPassword = null;

        // Обновим currentUser из профиля, если сервер не вернул user
        try {
          await authService.setAuthHeaderFromStorage();
        } catch (_) {}

        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/main');
        return;
      } else {
        // Обновление профиля: отправляем name, возможно secret, и запрос на верификацию телефона
        final profileData = {'name': name};
        if (_isCreatorCurrentUser) profileData['secret'] = secret;

        final p1 = authService.dio.post('/api/profile/update', data: profileData);
        final p2 = authService.dio.post('/api/phones/request', data: {'phone': apiPhone});
        final results = await Future.wait([p1, p2]);

        final ok1 = (results[0].statusCode == 200) ||
            (results[0].data is Map && (results[0].data['ok'] == true || results[0].data['user'] != null));
        final ok2 = (results[1].statusCode == 200) || (results[1].data is Map && results[1].data['ok'] == true);

        if (ok1 && ok2) {
          // Обновим локальный currentUser, если сервер вернул user
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
      final status = e.response?.statusCode;
      // Если email уже зарегистрирован — возвращаемся назад и передаём ошибку в AuthScreen
      if (status == 409) {
        if (mounted) {
          Navigator.of(context).pop({'error': 'Email already registered'});
        }
        return;
      }

      final serverData = e.response?.data;
      final serverMsg = serverData != null ? serverData.toString() : null;
      final errMsg = serverMsg ?? (e.message?.toString() ?? e.toString());
      setState(() => _message = errMsg);
    } catch (e) {
      setState(() => _message = e.toString());
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
              // Поле секретного слова показываем только в нужном случае
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
