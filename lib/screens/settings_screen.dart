// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/auth_service.dart';
import 'change_password_screen.dart';

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

  // Заглушки: в будущем сохранять в persistent storage / сервер
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
      // Заглушка: endpoint для удаления аккаунта
      final resp = await _auth.dio.post('/api/auth/delete_account');
      if (resp.statusCode == 200) {
        await _auth.logout();
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/');
      } else {
        setState(() => _message = 'Ошибка удаления аккаунта');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSupport() async {
    // Заглушка: открыть экран поддержки / отправить письмо
    setState(() => _message = 'Функция поддержки пока не реализована');
  }

  @override
  Widget build(BuildContext context) {
    // Используем SingleChildScrollView + ConstrainedBox чтобы избежать overflow
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

                      // Заполнитель, чтобы кнопка выхода была внизу при большом экране,
                      // но не вызывал overflow на маленьких — используем SizedBox вместо Spacer.
                      const SizedBox(height: 16),

                      if (_message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(_message, style: const TextStyle(color: Colors.red)),
                        ),

                      // Кнопка выхода внизу
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () async {
                            await _auth.logout();
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
