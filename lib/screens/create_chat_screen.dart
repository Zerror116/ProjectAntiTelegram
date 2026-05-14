// lib/screens/create_chat_screen.dart
import 'package:flutter/material.dart';
import '../main.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_micro_interactions.dart';

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

  int get _flowStep {
    if (_titleCtrl.text.trim().isEmpty) return 0;
    if (_loading) return 2;
    return 1;
  }

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

      final ok =
          (status == 201) ||
          (data is Map && (data['ok'] == true || data['data'] != null));
      if (ok) {
        // Показываем краткое подтверждение и возвращаем true
        if (!mounted) return;
        showAppNotice(
          context,
          'Чат успешно создан',
          tone: AppNoticeTone.success,
        );
        Navigator.of(context).pop(true);
        return;
      }

      // Попытка извлечь сообщение ошибки из ответа
      String msg = 'Ошибка создания чата';
      if (data is Map) {
        if (data['error'] != null) {
          msg = data['error'].toString();
        } else if (data['message'] != null) {
          msg = data['message'].toString();
        }
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PhoenixStepperStrip(
              steps: const ['Название', 'Тип', 'Создание'],
              activeIndex: _flowStep,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleCtrl,
              onChanged: (_) => setState(() {}),
              decoration: withInputLanguageBadge(
                const InputDecoration(
                  labelText: 'Название чата',
                  hintText: 'Введите название',
                ),
                controller: _titleCtrl,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Container(
                key: ValueKey<String>(_type),
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Тип чата',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Публичный'),
                          selected: _type == 'public',
                          avatar: const Icon(Icons.tag_rounded, size: 18),
                          onSelected: (_) => setState(() => _type = 'public'),
                        ),
                        ChoiceChip(
                          label: const Text('Приватный'),
                          selected: _type == 'private',
                          avatar: const Icon(Icons.lock_outline, size: 18),
                          onSelected: (_) => setState(() => _type = 'private'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          _type == 'public'
                              ? Icons.groups_outlined
                              : Icons.person_add_alt_1_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _type == 'public'
                                ? 'Участники увидят общий чат в списке доступных.'
                                : 'Участников можно будет добавить точечно после создания.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_error, style: const TextStyle(color: Colors.red)),
            ],
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _create,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _loading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                      )
                    : const Text('Создать'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
