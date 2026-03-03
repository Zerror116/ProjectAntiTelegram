import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/phoenix_loader.dart';

class SystemTestsScreen extends StatefulWidget {
  const SystemTestsScreen({super.key});

  @override
  State<SystemTestsScreen> createState() => _SystemTestsScreenState();
}

class _SystemTestsScreenState extends State<SystemTestsScreen> {
  String _messageStatus = 'sending';
  String _rolePreview = 'creator';
  bool _deliveryBusy = false;
  Map<String, dynamic>? _deliverySnapshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDeliverySnapshot();
    });
  }

  String _roleTitle(String role) {
    switch (role) {
      case 'admin':
        return 'Администратор';
      case 'worker':
        return 'Работник';
      case 'client':
        return 'Клиент';
      case 'creator':
      default:
        return 'Создатель';
    }
  }

  String _roleDescription(String role) {
    switch (role) {
      case 'admin':
        return 'Видит админ-панель, может публиковать и обрабатывать.';
      case 'worker':
        return 'Видит панель работника, отправляет товары в очередь.';
      case 'client':
        return 'Не пишет в публичные каналы, покупает и следит за корзиной.';
      case 'creator':
      default:
        return 'Полный доступ ко всем разделам и сценариям.';
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'read':
        return Icons.done_all_rounded;
      case 'sent':
        return Icons.done_rounded;
      case 'error':
        return Icons.error_outline_rounded;
      case 'sending':
      default:
        return Icons.schedule_rounded;
    }
  }

  Color _statusColor(ThemeData theme, String status) {
    switch (status) {
      case 'read':
        return theme.colorScheme.primary;
      case 'error':
        return theme.colorScheme.error;
      case 'sent':
        return theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.88);
      case 'sending':
      default:
        return theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.72);
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'read':
        return 'Прочитано';
      case 'sent':
        return 'Отправлено';
      case 'error':
        return 'Ошибка';
      case 'sending':
      default:
        return 'Отправляется';
    }
  }

  Future<void> _testNotice(
    AppNoticeTone tone,
    String title,
    String message,
  ) async {
    showAppNotice(
      context,
      message,
      title: title,
      tone: tone,
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _testSound(AppUiSound sound) async {
    await playAppSound(sound);
  }

  Future<void> _loadDeliverySnapshot() async {
    setState(() => _deliveryBusy = true);
    try {
      final resp = await authService.dio.get('/api/admin/delivery/dashboard');
      final data = resp.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        setState(
          () => _deliverySnapshot = Map<String, dynamic>.from(data['data']),
        );
        showAppNotice(
          context,
          'Состояние доставки обновлено',
          tone: AppNoticeTone.success,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка доставки: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _deliveryBusy = false);
      }
    }
  }

  Future<void> _resetDeliverySnapshot() async {
    setState(() => _deliveryBusy = true);
    try {
      await authService.dio.post('/api/admin/delivery/reset');
      await _loadDeliverySnapshot();
      if (!mounted) return;
      showAppNotice(
        context,
        'Доставка очищена',
        tone: AppNoticeTone.warning,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка очистки доставки: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _deliveryBusy = false);
      }
    }
  }

  Future<void> _seedDeliveryClients(int count) async {
    setState(() => _deliveryBusy = true);
    try {
      final resp = await authService.dio.post(
        '/api/admin/delivery/demo-seed',
        data: {'count': count},
      );
      await _loadDeliverySnapshot();
      if (!mounted) return;
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      showAppNotice(
        context,
        'Добавлено тестовых клиентов: ${payload['created_users'] ?? count}',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка генерации тестовых клиентов: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _deliveryBusy = false);
      }
    }
  }

  Widget _sectionTitle(String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    );
  }

  Widget _messagePreviewCard() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Как выглядит ваше сообщение',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 360),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Проверка статуса сообщений',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '12:47',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.74),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _statusIcon(_messageStatus),
                          size: 16,
                          color: _statusColor(theme, _messageStatus),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Текущий статус: ${_statusLabel(_messageStatus)}',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _deliveryPreviewCard() {
    final theme = Theme.of(context);
    final activeBatchRaw = _deliverySnapshot?['active_batch'];
    final activeBatch = activeBatchRaw is Map
        ? Map<String, dynamic>.from(activeBatchRaw)
        : null;
    final customersRaw = activeBatch == null ? null : activeBatch['customers'];
    final customers = customersRaw is List ? customersRaw : const [];
    final settingsRaw = _deliverySnapshot?['settings'];
    final settings = settingsRaw is Map
        ? Map<String, dynamic>.from(settingsRaw)
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Проверка доставки',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Порог: ${settings?['threshold_amount'] ?? '—'} RUB',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Text(
            activeBatch == null
                ? 'Активного листа сейчас нет'
                : 'Лист: ${activeBatch['delivery_label'] ?? 'Доставка'} | Клиентов: ${customers.length}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy ? null : _loadDeliverySnapshot,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(_deliveryBusy ? 'Проверяем...' : 'Проверить доставку'),
              ),
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy ? null : _resetDeliverySnapshot,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Очистить доставку'),
              ),
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy ? null : () => _seedDeliveryClients(10),
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('Добавить 10 клиентов'),
              ),
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy ? null : () => _seedDeliveryClients(20),
                icon: const Icon(Icons.groups_2_outlined),
                label: const Text('Добавить 20 клиентов'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Тесты')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionTitle('Сообщения'),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'sending', label: Text('Отправляется')),
                ButtonSegment(value: 'sent', label: Text('Отправлено')),
                ButtonSegment(value: 'read', label: Text('Прочитано')),
                ButtonSegment(value: 'error', label: Text('Ошибка')),
              ],
              selected: {_messageStatus},
              onSelectionChanged: (selection) {
                setState(() => _messageStatus = selection.first);
              },
            ),
            const SizedBox(height: 12),
            _messagePreviewCard(),
            const SizedBox(height: 24),
            _sectionTitle('Роли'),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'creator', label: Text('Создатель')),
                ButtonSegment(value: 'admin', label: Text('Админ')),
                ButtonSegment(value: 'worker', label: Text('Рабочий')),
                ButtonSegment(value: 'client', label: Text('Клиент')),
              ],
              selected: {_rolePreview},
              onSelectionChanged: (selection) {
                setState(() => _rolePreview = selection.first);
              },
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _roleTitle(_rolePreview),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _roleDescription(_rolePreview),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _sectionTitle('Уведомления'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _testNotice(
                    AppNoticeTone.info,
                    'Тест баннера',
                    'Проверка обычного уведомления',
                  ),
                  icon: const Icon(Icons.notifications_none_rounded),
                  label: const Text('Info'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _testNotice(
                    AppNoticeTone.success,
                    'Успех',
                    'Операция выполнена',
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Success'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _testNotice(
                    AppNoticeTone.warning,
                    'Внимание',
                    'Проверьте промежуточное состояние',
                  ),
                  icon: const Icon(Icons.warning_amber_rounded),
                  label: const Text('Warning'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _testNotice(
                    AppNoticeTone.error,
                    'Ошибка',
                    'Проверка аварийного сценария',
                  ),
                  icon: const Icon(Icons.error_outline),
                  label: const Text('Error'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _sectionTitle('Звуки'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonal(
                  onPressed: () => _testSound(AppUiSound.tap),
                  child: const Text('Клик'),
                ),
                FilledButton.tonal(
                  onPressed: () => _testSound(AppUiSound.sent),
                  child: const Text('Отправка'),
                ),
                FilledButton.tonal(
                  onPressed: () => _testSound(AppUiSound.incoming),
                  child: const Text('Входящее'),
                ),
                FilledButton.tonal(
                  onPressed: () => _testSound(AppUiSound.success),
                  child: const Text('Успех'),
                ),
                FilledButton.tonal(
                  onPressed: () => _testSound(AppUiSound.warning),
                  child: const Text('Предупреждение'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _sectionTitle('Доставка'),
            const SizedBox(height: 12),
            _deliveryPreviewCard(),
            const SizedBox(height: 24),
            _sectionTitle('Загрузка'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: const PhoenixLoadingView(
                title: 'Проверка лоадера',
                subtitle: 'Так выглядит анимированная загрузка',
                size: 60,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
