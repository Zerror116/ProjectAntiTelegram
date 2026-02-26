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

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

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
      final resp = await authService.dio.post(
        '/api/chats',
        data: {'title': title, 'type': _type},
      );

      final status = resp.statusCode;
      final data = resp.data;

      final ok = (status == 201) || (data is Map && (data['ok'] == true || data['data'] != null));
      if (ok) {
        // Показываем краткое подтверждение и возвращаем true
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Чат успешно создан')),
        );
        Navigator.of(context).pop(true);
        return;
      }

      // Попытка извлечь сообщение ошибки из ответа
      String msg = 'Ошибка создания чата';
      if (data is Map) {
        if (data['error'] != null) msg = data['error'].toString();
        else if (data['message'] != null) msg = data['message'].toString();
      }
      setState(() => _error = msg);
    } catch (e) {
      // Более дружелюбный вывод ошибки
      final errText = e is Exception ? e.toString() : 'Ошибка: $e';
      setState(() => _error = errText);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Создать чат')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Название чата',
              hintText: 'Введите название',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: RadioListTile<String>(
                value: 'public',
                groupValue: _type,
                title: const Text('Публичный'),
                onChanged: (v) => setState(() => _type = v ?? 'public'),
              ),
            ),
            Expanded(
              child: RadioListTile<String>(
                value: 'private',
                groupValue: _type,
                title: const Text('Приватный'),
                onChanged: (v) => setState(() => _type = v ?? 'private'),
              ),
            ),
          ]),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_error, style: const TextStyle(color: Colors.red)),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _create,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Создать'),
            ),
          ),
        ]),
      ),
    );
  }
}
