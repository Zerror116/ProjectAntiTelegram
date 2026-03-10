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
  bool _demoPostsBusy = false;
  bool _opsBusy = false;
  Map<String, dynamic>? _deliverySnapshot;
  Map<String, dynamic>? _diagnosticsSnapshot;

  @override
  void initState() {
    super.initState();
    if ((authService.effectiveRole).toLowerCase().trim() != 'creator') {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDeliverySnapshot();
      _loadDiagnosticsSnapshot();
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
      showAppNotice(context, 'Ошибка доставки: $e', tone: AppNoticeTone.error);
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
      showAppNotice(context, 'Доставка очищена', tone: AppNoticeTone.warning);
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

  Future<void> _publishDemoPosts(int count) async {
    setState(() => _demoPostsBusy = true);
    try {
      final resp = await authService.dio.post(
        '/api/admin/test/publish-demo-posts',
        data: {'count': count},
      );
      if (!mounted) return;
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      showAppNotice(
        context,
        'Тестовых постов отправлено: ${payload['count'] ?? count}',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка тестовой отправки постов: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _demoPostsBusy = false);
      }
    }
  }

  Future<void> _loadDiagnosticsSnapshot() async {
    setState(() => _opsBusy = true);
    try {
      final resp = await authService.dio.get(
        '/api/admin/ops/diagnostics/center',
      );
      final data = resp.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        setState(
          () => _diagnosticsSnapshot = Map<String, dynamic>.from(data['data']),
        );
        showAppNotice(
          context,
          'Диагностика обновлена',
          tone: AppNoticeTone.success,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка диагностики: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _opsBusy = false);
      }
    }
  }

  Future<void> _sendSmartNotificationPing() async {
    setState(() => _opsBusy = true);
    try {
      await authService.dio.post(
        '/api/admin/ops/notifications/test',
        data: {
          'type': 'order',
          'priority': 'high',
          'title': 'Тест smart-уведомления',
          'message': 'Проверка приоритета и тихих часов',
        },
      );
      if (!mounted) return;
      showAppNotice(
        context,
        'Smart-уведомление отправлено',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка smart-уведомления: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _opsBusy = false);
      }
    }
  }

  Future<void> _seedFullDemoMode() async {
    setState(() => _opsBusy = true);
    try {
      final resp = await authService.dio.post(
        '/api/admin/ops/demo-mode/seed',
        data: {'clients': 12, 'products': 20},
      );
      if (!mounted) return;
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      showAppNotice(
        context,
        'Demo seed: клиентов ${payload['clients_created_or_reused'] ?? 0}, постов ${payload['products_queued'] ?? 0}',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(context, 'Ошибка demo seed: $e', tone: AppNoticeTone.error);
    } finally {
      if (mounted) {
        setState(() => _opsBusy = false);
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

  Widget _opsCenterCard() {
    final compact = MediaQuery.of(context).size.width < 680;
    final diagnostics = _diagnosticsSnapshot ?? const <String, dynamic>{};
    final monitoring = diagnostics['monitoring'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(diagnostics['monitoring'])
        : <String, dynamic>{};
    final api = diagnostics['api'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(diagnostics['api'])
        : <String, dynamic>{};
    final database = diagnostics['database'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(diagnostics['database'])
        : <String, dynamic>{};
    final socket = diagnostics['socket'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(diagnostics['socket'])
        : <String, dynamic>{};

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _opsBusy ? null : _loadDiagnosticsSnapshot,
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('Обновить диагностику'),
              ),
              FilledButton.tonalIcon(
                onPressed: _opsBusy ? null : _sendSmartNotificationPing,
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Тест smart-уведомления'),
              ),
              FilledButton.tonalIcon(
                onPressed: _opsBusy ? null : _seedFullDemoMode,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Demo режим 1-клик'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('API uptime: ${(api['uptime_sec'] ?? 0).toString()} сек'),
          Text('DB latency: ${(database['latency_ms'] ?? 0).toString()} ms'),
          Text(
            'Socket clients: ${(socket['connected_clients'] ?? 0).toString()}',
          ),
          Text(
            'Monitoring: critical ${(monitoring['critical'] ?? 0).toString()}, error ${(monitoring['error'] ?? 0).toString()}',
          ),
        ],
      ),
    );
  }

  Widget _messagePreviewCard() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 16),
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
    final compact = MediaQuery.of(context).size.width < 680;
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
      padding: EdgeInsets.all(compact ? 12 : 16),
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
                label: Text(
                  _deliveryBusy ? 'Проверяем...' : 'Проверить доставку',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy ? null : _resetDeliverySnapshot,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Очистить доставку'),
              ),
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy
                    ? null
                    : () => _seedDeliveryClients(10),
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('Добавить 10 клиентов'),
              ),
              FilledButton.tonalIcon(
                onPressed: _deliveryBusy
                    ? null
                    : () => _seedDeliveryClients(20),
                icon: const Icon(Icons.groups_2_outlined),
                label: const Text('Добавить 20 клиентов'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _demoPostsCard() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Тест отправки постов',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Создает и постепенно публикует тестовые товарные посты в Основной канал с заглушкой фото и случайными данными.',
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
                onPressed: _demoPostsBusy ? null : () => _publishDemoPosts(10),
                icon: const Icon(Icons.queue_play_next_outlined),
                label: const Text('10 постов'),
              ),
              FilledButton.tonalIcon(
                onPressed: _demoPostsBusy ? null : () => _publishDemoPosts(25),
                icon: const Icon(Icons.dynamic_feed_outlined),
                label: const Text('25 постов'),
              ),
              FilledButton.tonalIcon(
                onPressed: _demoPostsBusy ? null : () => _publishDemoPosts(50),
                icon: const Icon(Icons.local_fire_department_outlined),
                label: const Text('50 постов'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if ((authService.effectiveRole).toLowerCase().trim() != 'creator') {
      return Scaffold(
        appBar: AppBar(title: const Text('Тесты')),
        body: const SafeArea(
          child: Center(
            child: Text('Вкладка тестов доступна только в режиме создателя'),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;

    return Scaffold(
      appBar: AppBar(title: const Text('Тесты')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(compact ? 10 : 16),
          children: [
            _sectionTitle('Сообщения'),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
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
            ),
            const SizedBox(height: 12),
            _messagePreviewCard(),
            const SizedBox(height: 24),
            _sectionTitle('Роли'),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
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
            ),
            const SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(compact ? 12 : 16),
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
            _sectionTitle('Публикация'),
            const SizedBox(height: 12),
            _demoPostsCard(),
            const SizedBox(height: 24),
            _sectionTitle('Операционный центр'),
            const SizedBox(height: 12),
            _opsCenterCard(),
            const SizedBox(height: 24),
            _sectionTitle('Загрузка'),
            const SizedBox(height: 12),
            Container(
              padding: EdgeInsets.symmetric(
                vertical: compact ? 18 : 24,
                horizontal: compact ? 12 : 16,
              ),
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
