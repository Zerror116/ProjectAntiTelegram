import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';

class BugReportScreen extends StatefulWidget {
  const BugReportScreen({super.key});

  @override
  State<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends State<BugReportScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _sending = false;
  String _message = '';

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _extractDioMessage(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        return (data['error'] ?? data['message'] ?? 'Ошибка отправки')
            .toString();
      }
      return e.message ?? 'Ошибка отправки';
    }
    return e.toString();
  }

  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
    if (isShiftPressed) return KeyEventResult.ignored;

    _send();
    return KeyEventResult.handled;
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _message = 'Опишите баг перед отправкой');
      return;
    }

    setState(() {
      _sending = true;
      _message = '';
    });

    try {
      final resp = await authService.dio.post(
        '/api/support/bug-report',
        data: {'message': text},
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        _controller.clear();
        if (!mounted) return;
        setState(
          () => _message =
              'Баг-репорт отправлен. Он попал в отдельный приватный канал для admin/creator.',
        );
      } else {
        if (!mounted) return;
        setState(() => _message = 'Не удалось отправить баг-репорт');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _extractDioMessage(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сообщить о баге')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Опишите проблему, шаги для повторения и ожидаемый результат.\n'
              'Сообщение отправится в отдельный закрытый канал баг-репортов.',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 12),
            Focus(
              onKeyEvent: _onInputKey,
              child: TextField(
                focusNode: _focusNode,
                controller: _controller,
                minLines: 6,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText:
                      'Что случилось?\n1) Шаги\n2) Что ожидали\n3) Что получили',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.bug_report_outlined),
                label: Text(_sending ? 'Отправка...' : 'Отправить баг-репорт'),
              ),
            ),
            if (_message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _message,
                style: TextStyle(
                  color: _message.startsWith('Баг-репорт отправлен')
                      ? Colors.green[700]
                      : Colors.red,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
