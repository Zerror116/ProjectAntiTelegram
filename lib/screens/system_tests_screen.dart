import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/phoenix_loader.dart';

enum _CriticalCheckStatus { idle, running, passed, failed, skipped }

class _CriticalCheckSkip implements Exception {
  final String reason;
  const _CriticalCheckSkip(this.reason);
}

class _CriticalCheckState {
  final String id;
  final String title;
  final String description;
  final _CriticalCheckStatus status;
  final String details;
  final int durationMs;

  const _CriticalCheckState({
    required this.id,
    required this.title,
    required this.description,
    this.status = _CriticalCheckStatus.idle,
    this.details = '',
    this.durationMs = 0,
  });

  _CriticalCheckState copyWith({
    _CriticalCheckStatus? status,
    String? details,
    int? durationMs,
  }) {
    return _CriticalCheckState(
      id: id,
      title: title,
      description: description,
      status: status ?? this.status,
      details: details ?? this.details,
      durationMs: durationMs ?? this.durationMs,
    );
  }
}

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
  bool _criticalBusy = false;
  Map<String, dynamic>? _deliverySnapshot;
  Map<String, dynamic>? _diagnosticsSnapshot;
  DateTime? _criticalLastRunAt;
  List<_CriticalCheckState> _criticalChecks = const [
    _CriticalCheckState(
      id: 'profile_scope',
      title: 'Профиль и tenant-контекст',
      description: 'Проверяет /api/profile и базовые поля пользователя.',
    ),
    _CriticalCheckState(
      id: 'chats_main',
      title: 'Список чатов + Основной канал',
      description: 'Проверяет /api/chats и наличие основного канала.',
    ),
    _CriticalCheckState(
      id: 'direct_search',
      title: 'Поиск ЛС по номеру/email',
      description:
          'Проверяет /api/chats/direct/search на полный идентификатор.',
    ),
    _CriticalCheckState(
      id: 'support_templates',
      title: 'Шаблоны поддержки',
      description: 'Проверяет /api/admin/ops/support/templates.',
    ),
    _CriticalCheckState(
      id: 'notifications_center',
      title: 'Центр уведомлений',
      description: 'Проверяет /api/admin/ops/notifications/center.',
    ),
    _CriticalCheckState(
      id: 'returns_analytics',
      title: 'Аналитика возвратов',
      description: 'Проверяет /api/admin/ops/returns/analytics.',
    ),
    _CriticalCheckState(
      id: 'diagnostics_center',
      title: 'Диагностика Ops',
      description: 'Проверяет /api/admin/ops/diagnostics/center.',
    ),
  ];

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

  String _safeError(Object error) {
    final text = error.toString().trim();
    if (text.startsWith('Exception: ')) {
      return text.replaceFirst('Exception: ', '').trim();
    }
    return text;
  }

  Map<String, dynamic> _asMap(dynamic raw, {required String context}) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw Exception('$context: ожидался JSON-объект');
  }

  List<Map<String, dynamic>> _asMapList(
    dynamic raw, {
    required String context,
  }) {
    if (raw is! List) {
      throw Exception('$context: ожидался JSON-массив');
    }
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  bool _toBool(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = raw?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes';
  }

  bool _isMainTitle(String raw) {
    final value = raw.trim().toLowerCase();
    return value == 'основной канал' || value.startsWith('основной канал ');
  }

  bool _isMainChannelRow(Map<String, dynamic> chat) {
    final settingsRaw = chat['settings'];
    final settings = settingsRaw is Map
        ? Map<String, dynamic>.from(settingsRaw)
        : const <String, dynamic>{};
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final kind = (settings['kind'] ?? '').toString().trim().toLowerCase();
    final isMainFlag =
        _toBool(chat['is_main_channel']) ||
        _toBool(settings['is_main_channel']);
    final title = (chat['title'] ?? '').toString();
    final displayTitle = (chat['display_title'] ?? '').toString();
    final name = (chat['name'] ?? '').toString();
    return systemKey == 'main_channel' ||
        kind == 'main_channel' ||
        isMainFlag ||
        _isMainTitle(title) ||
        _isMainTitle(displayTitle) ||
        _isMainTitle(name);
  }

  void _updateCriticalCheck(
    String id,
    _CriticalCheckStatus status, {
    String? details,
    int? durationMs,
  }) {
    if (!mounted) return;
    setState(() {
      _criticalChecks = _criticalChecks.map((check) {
        if (check.id != id) return check;
        return check.copyWith(
          status: status,
          details: details ?? check.details,
          durationMs: durationMs ?? check.durationMs,
        );
      }).toList();
    });
  }

  IconData _criticalStatusIcon(_CriticalCheckStatus status) {
    switch (status) {
      case _CriticalCheckStatus.running:
        return Icons.sync_rounded;
      case _CriticalCheckStatus.passed:
        return Icons.check_circle_rounded;
      case _CriticalCheckStatus.failed:
        return Icons.error_rounded;
      case _CriticalCheckStatus.skipped:
        return Icons.remove_circle_outline_rounded;
      case _CriticalCheckStatus.idle:
        return Icons.radio_button_unchecked_rounded;
    }
  }

  Color _criticalStatusColor(ThemeData theme, _CriticalCheckStatus status) {
    switch (status) {
      case _CriticalCheckStatus.running:
        return theme.colorScheme.primary;
      case _CriticalCheckStatus.passed:
        return theme.colorScheme.tertiary;
      case _CriticalCheckStatus.failed:
        return theme.colorScheme.error;
      case _CriticalCheckStatus.skipped:
        return theme.colorScheme.outline;
      case _CriticalCheckStatus.idle:
        return theme.colorScheme.outline;
    }
  }

  String _criticalStatusLabel(_CriticalCheckStatus status) {
    switch (status) {
      case _CriticalCheckStatus.running:
        return 'Выполняется';
      case _CriticalCheckStatus.passed:
        return 'OK';
      case _CriticalCheckStatus.failed:
        return 'Ошибка';
      case _CriticalCheckStatus.skipped:
        return 'Пропуск';
      case _CriticalCheckStatus.idle:
        return 'Ожидание';
    }
  }

  Future<String> _checkProfileScope() async {
    final resp = await authService.dio.get('/api/profile');
    final root = _asMap(resp.data, context: '/api/profile');
    if (root['ok'] != true) {
      throw Exception('/api/profile: ok != true');
    }
    final user = _asMap(
      root['user'] ?? root['data'] ?? const {},
      context: '/api/profile.user',
    );
    final email = (user['email'] ?? '').toString().trim();
    final role = (user['role'] ?? authService.effectiveRole)
        .toString()
        .trim()
        .toLowerCase();
    final tenantCode = (user['tenant_code'] ?? user['tenantCode'] ?? '')
        .toString()
        .trim();

    if (email.isEmpty) {
      throw Exception('/api/profile: email пустой');
    }
    if (role != 'creator' && tenantCode.isEmpty) {
      throw Exception('/api/profile: tenant_code пустой для роли $role');
    }
    if (role == 'creator') {
      return 'role=$role, email=$email';
    }
    return 'role=$role, tenant=$tenantCode';
  }

  Future<String> _checkChatsMainChannel() async {
    final resp = await authService.dio.get('/api/chats');
    final root = _asMap(resp.data, context: '/api/chats');
    if (root['ok'] != true) {
      throw Exception('/api/chats: ok != true');
    }
    final chats = _asMapList(root['data'], context: '/api/chats.data');
    if (chats.isEmpty) {
      throw Exception('/api/chats: список пустой');
    }
    final hasMain = chats.any(_isMainChannelRow);
    if (!hasMain) {
      throw Exception('Основной канал не найден');
    }
    return 'чатов: ${chats.length}, основной канал найден';
  }

  Future<String> _checkDirectSearch() async {
    final fallbackProbe = authService.currentUser?.phone?.trim() ?? '';
    final fallbackDigits = fallbackProbe.replaceAll(RegExp(r'\D'), '');
    final query = fallbackDigits.length >= 10
        ? fallbackDigits
        : authService.currentUser?.email.trim() ?? '89990000000';

    final resp = await authService.dio.get(
      '/api/chats/direct/search',
      queryParameters: {'query': query, 'limit': 10},
    );
    final root = _asMap(resp.data, context: '/api/chats/direct/search');
    if (root['ok'] != true) {
      throw Exception('/api/chats/direct/search: ok != true');
    }
    final data = _asMap(root['data'], context: '/api/chats/direct/search.data');
    final tooShort = _toBool(data['too_short']);
    if (tooShort) {
      throw Exception('direct/search вернул too_short для полного запроса');
    }
    final candidates = data['candidates'];
    if (candidates is! List) {
      throw Exception('direct/search: candidates не массив');
    }
    final exact = data['exact'];
    return 'query="$query", exact=${exact == null ? 'нет' : 'есть'}, candidates=${candidates.length}';
  }

  Future<String> _checkSupportTemplates() async {
    final resp = await authService.dio.get('/api/admin/ops/support/templates');
    final root = _asMap(resp.data, context: '/api/admin/ops/support/templates');
    if (root['ok'] != true) {
      throw Exception('/api/admin/ops/support/templates: ok != true');
    }
    final rows = _asMapList(
      root['data'],
      context: '/api/admin/ops/support/templates.data',
    );
    return 'активных шаблонов: ${rows.length}';
  }

  Future<String> _checkNotificationsCenter() async {
    final resp = await authService.dio.get(
      '/api/admin/ops/notifications/center',
      queryParameters: {'limit': 20},
    );
    final root = _asMap(
      resp.data,
      context: '/api/admin/ops/notifications/center',
    );
    if (root['ok'] != true) {
      throw Exception('/api/admin/ops/notifications/center: ok != true');
    }
    final data = _asMap(
      root['data'],
      context: '/api/admin/ops/notifications/center.data',
    );
    final summary = _asMap(data['summary'], context: 'notifications.summary');
    final items = data['items'];
    if (items is! List) {
      throw Exception('notifications.items не массив');
    }
    return 'attention=${summary['total_attention'] ?? 0}, событий=${items.length}';
  }

  Future<String> _checkReturnsAnalytics() async {
    final resp = await authService.dio.get(
      '/api/admin/ops/returns/analytics',
      queryParameters: {'days': 30, 'top_limit': 8},
    );
    final root = _asMap(resp.data, context: '/api/admin/ops/returns/analytics');
    if (root['ok'] != true) {
      throw Exception('/api/admin/ops/returns/analytics: ok != true');
    }
    final data = _asMap(
      root['data'],
      context: '/api/admin/ops/returns/analytics.data',
    );
    final summary = _asMap(data['summary'], context: 'returns.summary');
    final totalClaims = summary['total_claims'] ?? 0;
    final defectSum = summary['defect_sum'] ?? 0;
    return 'заявок=$totalClaims, сумма брака=$defectSum ₽';
  }

  Future<String> _checkDiagnosticsCenter() async {
    final role = (authService.effectiveRole).toLowerCase().trim();
    if (role != 'creator') {
      throw const _CriticalCheckSkip('Проверка доступна только создателю');
    }
    final resp = await authService.dio.get('/api/admin/ops/diagnostics/center');
    final root = _asMap(
      resp.data,
      context: '/api/admin/ops/diagnostics/center',
    );
    if (root['ok'] != true) {
      throw Exception('/api/admin/ops/diagnostics/center: ok != true');
    }
    final data = _asMap(
      root['data'],
      context: '/api/admin/ops/diagnostics/center.data',
    );
    final monitoring = _asMap(
      data['monitoring'],
      context: 'diagnostics.monitoring',
    );
    return 'critical=${monitoring['critical'] ?? 0}, error=${monitoring['error'] ?? 0}';
  }

  Future<void> _runCriticalChecks() async {
    if (_criticalBusy) return;
    final checks = <Map<String, dynamic>>[
      {'id': 'profile_scope', 'runner': _checkProfileScope},
      {'id': 'chats_main', 'runner': _checkChatsMainChannel},
      {'id': 'direct_search', 'runner': _checkDirectSearch},
      {'id': 'support_templates', 'runner': _checkSupportTemplates},
      {'id': 'notifications_center', 'runner': _checkNotificationsCenter},
      {'id': 'returns_analytics', 'runner': _checkReturnsAnalytics},
      {'id': 'diagnostics_center', 'runner': _checkDiagnosticsCenter},
    ];

    setState(() {
      _criticalBusy = true;
      _criticalChecks = _criticalChecks
          .map(
            (item) => item.copyWith(
              status: _CriticalCheckStatus.idle,
              details: '',
              durationMs: 0,
            ),
          )
          .toList();
    });

    var passed = 0;
    var failed = 0;
    var skipped = 0;

    for (final item in checks) {
      if (!mounted) return;
      final id = item['id'] as String;
      final runner = item['runner'] as Future<String> Function();
      _updateCriticalCheck(
        id,
        _CriticalCheckStatus.running,
        details: 'Выполняется...',
      );
      final sw = Stopwatch()..start();
      try {
        final details = await runner();
        sw.stop();
        _updateCriticalCheck(
          id,
          _CriticalCheckStatus.passed,
          details: details,
          durationMs: sw.elapsedMilliseconds,
        );
        passed += 1;
      } on _CriticalCheckSkip catch (skip) {
        sw.stop();
        _updateCriticalCheck(
          id,
          _CriticalCheckStatus.skipped,
          details: skip.reason,
          durationMs: sw.elapsedMilliseconds,
        );
        skipped += 1;
      } catch (error) {
        sw.stop();
        _updateCriticalCheck(
          id,
          _CriticalCheckStatus.failed,
          details: _safeError(error),
          durationMs: sw.elapsedMilliseconds,
        );
        failed += 1;
      }
    }

    if (!mounted) return;
    setState(() {
      _criticalBusy = false;
      _criticalLastRunAt = DateTime.now();
    });

    final total = checks.length;
    final tone = failed > 0 ? AppNoticeTone.error : AppNoticeTone.success;
    final summary =
        'Критичные проверки: OK $passed, ошибок $failed, пропусков $skipped из $total';
    showAppNotice(
      context,
      summary,
      tone: tone,
      duration: const Duration(seconds: 4),
    );
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

  Widget _criticalChecksCard() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;
    final passed = _criticalChecks
        .where((item) => item.status == _CriticalCheckStatus.passed)
        .length;
    final failed = _criticalChecks
        .where((item) => item.status == _CriticalCheckStatus.failed)
        .length;
    final skipped = _criticalChecks
        .where((item) => item.status == _CriticalCheckStatus.skipped)
        .length;

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
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: _criticalBusy ? null : _runCriticalChecks,
                icon: Icon(
                  _criticalBusy
                      ? Icons.hourglass_top_rounded
                      : Icons.fact_check_outlined,
                ),
                label: Text(
                  _criticalBusy
                      ? 'Проверяем...'
                      : 'Запустить критичные проверки',
                ),
              ),
              Text(
                'OK $passed · Ошибок $failed · Пропусков $skipped',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (_criticalLastRunAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Последний прогон: ${_criticalLastRunAt!.hour.toString().padLeft(2, '0')}:${_criticalLastRunAt!.minute.toString().padLeft(2, '0')}:${_criticalLastRunAt!.second.toString().padLeft(2, '0')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_criticalBusy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 3),
          ],
          const SizedBox(height: 12),
          ..._criticalChecks.map((check) {
            final color = _criticalStatusColor(theme, check.status);
            final detailText = check.details.trim().isEmpty
                ? check.description
                : check.details.trim();
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      _criticalStatusIcon(check.status),
                      size: 18,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          check.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detailText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    check.durationMs > 0
                        ? '${_criticalStatusLabel(check.status)} · ${check.durationMs} ms'
                        : _criticalStatusLabel(check.status),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
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
            'Порог: ${settings?['threshold_amount'] ?? '—'} ₽',
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
            _sectionTitle('Критичные проверки'),
            const SizedBox(height: 12),
            _criticalChecksCard(),
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
