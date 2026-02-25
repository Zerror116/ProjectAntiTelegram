// lib/screens/change_password_screen.dart
import 'package:flutter/material.dart';
import '../main.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  bool _loading = false;
  String _message = '';

  Future<void> _change() async {
    final oldP = _oldController.text;
    final newP = _newController.text;
    if (oldP.isEmpty || newP.length < 8) {
      setState(() => _message = 'Введите старый пароль и новый (не менее 8 символов)');
      return;
    }
    setState(() { _loading = true; _message = ''; });
    try {
      final resp = await authService.dio.post('/api/auth/change_password', data: {'oldPassword': oldP, 'newPassword': newP});
      if (resp.statusCode == 200) {
        setState(() => _message = 'Пароль успешно изменён');
        _oldController.clear();
        _newController.clear();
      } else {
        setState(() => _message = 'Ошибка: ${resp.data}');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сменить пароль')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _oldController, obscureText: true, decoration: const InputDecoration(labelText: 'Старый пароль')),
          const SizedBox(height: 12),
          TextField(controller: _newController, obscureText: true, decoration: const InputDecoration(labelText: 'Новый пароль')),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _loading ? null : _change, child: _loading ? const CircularProgressIndicator() : const Text('Сменить пароль')),
          const SizedBox(height: 12),
          if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.red)),
        ]),
      ),
    );
  }
}
