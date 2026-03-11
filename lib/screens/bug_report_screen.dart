import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/submit_on_enter.dart';

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
  String? _selectedTemplate;

  static const List<Map<String, String>> _templates = [
    {
      'title': 'Не открывается чат',
      'body':
          'Что не открывается:\nШаги:\nЧто должно было произойти:\nЧто произошло:',
    },
    {
      'title': 'Ошибка корзины',
      'body':
          'Какой товар:\nЧто пытались сделать:\nЧто ожидали:\nЧто получили:',
    },
    {
      'title': 'Проблема с уведомлением',
      'body': 'На каком устройстве:\nЧто ожидали:\nЧто произошло по факту:',
    },
    {
      'title': 'Другая проблема',
      'body':
          'Опишите проблему:\nШаги для повторения:\nОжидаемый результат:\nФактический результат:',
    },
  ];

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

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _message = 'Опишите проблему перед отправкой');
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
              'Сообщение отправлено. Его увидит администрация в отдельном служебном канале.',
        );
        showAppNotice(
          context,
          'Проблема отправлена',
          tone: AppNoticeTone.success,
        );
      } else {
        if (!mounted) return;
        setState(() => _message = 'Не удалось отправить сообщение о проблеме');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _extractDioMessage(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _applyTemplate(Map<String, String> template) {
    final body = template['body'] ?? '';
    setState(() {
      _selectedTemplate = template['title'];
      _message = '';
      _controller.text = body;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    });
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = _message.startsWith('Сообщение отправлено');
    return Scaffold(
      appBar: AppBar(title: const Text('Сообщить о проблеме')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Опишите, что сломалось',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Сообщение попадёт в отдельный закрытый служебный канал. Клиенты этот канал не видят.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _templates.map((template) {
                final selected = _selectedTemplate == template['title'];
                return ChoiceChip(
                  label: Text(template['title'] ?? 'Шаблон'),
                  selected: selected,
                  onSelected: (_) => _applyTemplate(template),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            SubmitOnEnter(
              controller: _controller,
              enabled: !_sending,
              onSubmit: _send,
              child: TextField(
                focusNode: _focusNode,
                controller: _controller,
                minLines: 6,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    hintText:
                        'Что случилось?\n1) Шаги\n2) Что ожидали\n3) Что получили',
                    border: OutlineInputBorder(),
                  ),
                  controller: _controller,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.report_problem_outlined),
                label: Text(_sending ? 'Отправка...' : 'Отправить сообщение'),
              ),
            ),
            if (_message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: success
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  _message,
                  style: TextStyle(
                    color: success
                        ? theme.colorScheme.onSecondaryContainer
                        : theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
