// lib/screens/support_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/submit_on_enter.dart';

class SupportScreen extends StatefulWidget {
  final String? initialMessage;

  const SupportScreen({super.key, this.initialMessage});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _loading = false;
  final List<Map<String, String>> _messages = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialMessage?.trim();
    if (initial != null && initial.isNotEmpty) {
      _controller.text = initial;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _copyText(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: normalized));
    if (!mounted) return;
    showAppNotice(
      context,
      'Текст скопирован',
      tone: AppNoticeTone.success,
      duration: const Duration(milliseconds: 1000),
    );
  }

  Future<void> _ask() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _loading = true;
      _messages.add({'from': 'user', 'text': text});
    });
    _controller.clear();

    try {
      final resp = await authService.dio.post(
        '/api/support/ask',
        data: {'message': text},
      );
      final data = resp.data;
      String reply = 'Не удалось получить ответ';
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        reply = (data['data']['reply'] ?? reply).toString();
      }
      setState(() => _messages.add({'from': 'bot', 'text': reply}));
      await playAppSound(AppUiSound.success);
    } catch (e) {
      setState(
        () => _messages.add({'from': 'bot', 'text': 'Ошибка поддержки: $e'}),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Поддержка')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final fromUser = msg['from'] == 'user';
                  final text = msg['text'] ?? '';
                  return Align(
                    alignment: fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: text.trim().isEmpty
                          ? null
                          : () => _copyText(text),
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: fromUser
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          text,
                          style: TextStyle(
                            color: fromUser
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: PhoenixLoadingView(
                  title: 'Поддержка отвечает',
                  subtitle: 'Формируем ответ',
                  size: 40,
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: SubmitOnEnter(
                      controller: _controller,
                      enabled: !_loading,
                      onSubmit: _ask,
                      child: TextField(
                        focusNode: _inputFocusNode,
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            hintText: 'Напишите вопрос...',
                            border: OutlineInputBorder(),
                          ),
                          controller: _controller,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _loading ? null : _ask,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
