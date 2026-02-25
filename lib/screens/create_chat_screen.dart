// lib/screens/create_chat_screen.dart
import 'package:flutter/material.dart';
import '../main.dart';

class CreateChatScreen extends StatefulWidget {
  const CreateChatScreen({super.key});
  @override
  State<CreateChatScreen> createState() => _CreateChatScreenState();
}

class _CreateChatScreenState extends State<CreateChatScreen> {
  final _titleCtrl = TextEditingController();
  String _type = 'public';
  bool _loading = false;
  String _error = '';

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Введите название чата');
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final resp = await authService.dio.post('/api/chats', data: {'title': title, 'type': _type});
      if (resp.statusCode == 201 || (resp.data is Map && resp.data['ok'] == true)) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = 'Ошибка создания чата');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Создать чат')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _titleCtrl, decoration: const InputDecoration(labelText: 'Название чата')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: RadioListTile<String>(value: 'public', groupValue: _type, title: const Text('Публичный'), onChanged: (v) => setState(() => _type = v!))),
            Expanded(child: RadioListTile<String>(value: 'private', groupValue: _type, title: const Text('Приватный'), onChanged: (v) => setState(() => _type = v!))),
          ]),
          if (_error.isNotEmpty) Text(_error, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _loading ? null : _create, child: _loading ? const CircularProgressIndicator() : const Text('Создать')),
        ]),
      ),
    );
  }
}
