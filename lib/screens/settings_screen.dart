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
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              if ((_auth).clearToken is Function) {
                                await _auth.clearToken();
                              } else if ((_auth).logout is Function) {
                                await _auth.logout();
                              }
                            } catch (_) {}
                            if (!mounted) return;
                            Navigator.pushReplacementNamed(context, '/');
                          },
                          child: const Text('Выйти'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        ),
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
