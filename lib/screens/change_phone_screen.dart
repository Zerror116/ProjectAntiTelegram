// lib/screens/change_phone_screen.dart
import 'package:flutter/material.dart';
import '../main.dart';

class ChangePhoneScreen extends StatefulWidget {
  const ChangePhoneScreen({super.key});

  @override
  State<ChangePhoneScreen> createState() => _ChangePhoneScreenState();
}

class _ChangePhoneScreenState extends State<ChangePhoneScreen> {
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _loading = false;
  String _message = '';

  Future<void> _changePhone() async {
    final pwd = _passwordController.text;
    final phoneRaw = _phoneController.text.trim();
    if (pwd.isEmpty || phoneRaw.isEmpty) {
      setState(() => _message = 'Введите пароль и новый номер');
      return;
    }

    String normalized = phoneRaw.replaceAll(RegExp(r'\D'), '');
    if (normalized.length == 10) normalized = '7$normalized';
    final phone = normalized.startsWith('+') ? normalized : '+$normalized';

    setState(() { _loading = true; _message = ''; });
    try {
      final resp = await authService.dio.post('/api/phones/change', data: {'password': pwd, 'phone': phone});
      if (resp.statusCode == 200) {
        setState(() => _message = 'Номер изменён, ожидает проверки');
      } else {
        setState(() => _message = 'Ошибка: ${resp.data}');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка: $e');
    } finally {
      setState(() { _loading = false; });
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сменить номер телефона')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _passwordController, obscureText: true, decoration: const InputDecoration(labelText: 'Пароль')),
          const SizedBox(height: 12),
          TextField(controller: _phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Новый номер')),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _loading ? null : _changePhone, child: _loading ? const CircularProgressIndicator() : const Text('Сменить номер')),
          const SizedBox(height: 12),
          if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.red)),
        ]),
      ),
    );
  }
}
