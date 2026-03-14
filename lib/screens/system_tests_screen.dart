import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  static const String _platformCreatorEmail = 'zerotwo02166@gmail.com';

  String _messageStatus = 'sending';
  String _rolePreview = 'creator';
  bool _deliveryBusy = false;
  bool _demoPostsBusy = false;
  bool _opsBusy = false;
  bool _subscriptionTestBusy = false;
  bool _subscriptionScenarioBusy = false;
  bool _tenantMatrixBusy = false;
  bool _apiBenchmarkBusy = false;
  bool _fullSmokeBusy = false;
  bool _criticalBusy = false;
  bool _subscriptionIncludeDefault = false;
  bool _subscriptionDryRun = false;
  int _subscriptionWarningHours = 20;
  bool _tenantMatrixIncludeDeleted = false;
  bool _tenantMatrixIncludeDefault = false;
  Map<String, dynamic>? _deliverySnapshot;
  Map<String, dynamic>? _diagnosticsSnapshot;
  Map<String, dynamic>? _subscriptionSummary;
  Map<String, dynamic>? _tenantMatrixSummary;
  Map<String, dynamic>? _apiBenchmarkSummary;
  List<Map<String, dynamic>> _subscriptionSnapshot = const [];
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
    _CriticalCheckState(
      id: 'subscription_tools',
      title: 'Тесты подписки арендаторов',
      description: 'Проверяет /api/admin/test/tenants/subscriptions (dry-run).',
    ),
    _CriticalCheckState(
      id: 'tenants_matrix',
      title: 'Матрица арендаторов',
      description: 'Проверяет /api/admin/test/tenants/matrix.',
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
      if (_isPlatformCreator) {
        _loadTenantMatrix(showNotice: false);
      }
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

  List<Map<String, dynamic>> _asMapListSafe(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
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

  bool get _isPlatformCreator {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    final email = (authService.currentUser?.email ?? '').toLowerCase().trim();
    final viewRole = authService.effectiveRole.toLowerCase().trim();
    return role == 'creator' &&
        viewRole == 'creator' &&
        email == _platformCreatorEmail;
  }

  String _formatDateTimeShort(dynamic raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return '—';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    final dd = local.day.toString().padLeft(2, '0');
    final mm = local.month.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$dd.$mm ${local.year} $hh:$min';
  }

  Map<String, num> _latencyStats(List<int> values) {
    if (values.isEmpty) {
      return const {'min': 0, 'max': 0, 'avg': 0, 'p95': 0};
    }
    final sorted = [...values]..sort();
    final min = sorted.first;
    final max = sorted.last;
    final avg = values.reduce((a, b) => a + b) / values.length;
    final p95Index = ((sorted.length - 1) * 0.95).round().clamp(
      0,
      sorted.length - 1,
    );
    final p95 = sorted[p95Index];
    return {'min': min, 'max': max, 'avg': avg, 'p95': p95};
  }

  String _buildTestsReportJson() {
    final payload = <String, dynamic>{
      'generated_at': DateTime.now().toIso8601String(),
      'role': authService.effectiveRole,
      'critical': _criticalChecks
          .map(
            (c) => {
              'id': c.id,
              'title': c.title,
              'status': _criticalStatusLabel(c.status),
              'details': c.details,
              'duration_ms': c.durationMs,
            },
          )
          .toList(),
      'subscription_test': _subscriptionSummary ?? const <String, dynamic>{},
      'api_benchmark': _apiBenchmarkSummary ?? const <String, dynamic>{},
      'tenant_matrix': _tenantMatrixSummary ?? const <String, dynamic>{},
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
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

  Future<String> _checkSubscriptionTools() async {
    final role = (authService.effectiveRole).toLowerCase().trim();
    if (role != 'creator') {
      throw const _CriticalCheckSkip('Проверка доступна только создателю');
    }
    if (!_isPlatformCreator) {
      throw const _CriticalCheckSkip(
        'Доступно только платформенному создателю',
      );
    }
    final resp = await authService.dio.post(
      '/api/admin/test/tenants/subscriptions',
      data: {'mode': 'warn_soon_all', 'warning_hours': 20, 'dry_run': true},
    );
    final root = _asMap(
      resp.data,
      context: '/api/admin/test/tenants/subscriptions',
    );
    if (root['ok'] != true) {
      throw Exception('/api/admin/test/tenants/subscriptions: ok != true');
    }
    final data = _asMap(
      root['data'],
      context: '/api/admin/test/tenants/subscriptions.data',
    );
    return 'тенантов в скоупе: ${data['total'] ?? 0}, changed=${data['changed'] ?? 0}, dry_run=true';
  }

  Future<String> _checkTenantsMatrix() async {
    final role = (authService.effectiveRole).toLowerCase().trim();
    if (role != 'creator') {
      throw const _CriticalCheckSkip('Проверка доступна только создателю');
    }
    if (!_isPlatformCreator) {
      throw const _CriticalCheckSkip(
        'Доступно только платформенному создателю',
      );
    }
    final resp = await authService.dio.post(
      '/api/admin/test/tenants/matrix',
      data: {'include_deleted': false, 'include_default': false},
    );
    final root = _asMap(resp.data, context: '/api/admin/test/tenants/matrix');
    if (root['ok'] != true) {
      throw Exception('/api/admin/test/tenants/matrix: ok != true');
    }
    final data = _asMap(
      root['data'],
      context: '/api/admin/test/tenants/matrix.data',
    );
    final summary = _asMap(
      data['summary'],
      context: '/api/admin/test/tenants/matrix.summary',
    );
    return 'total=${data['total'] ?? 0}, no_main=${summary['missing_main_channel'] ?? 0}, no_staff=${summary['missing_staff'] ?? 0}';
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
      {'id': 'subscription_tools', 'runner': _checkSubscriptionTools},
      {'id': 'tenants_matrix', 'runner': _checkTenantsMatrix},
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

  Future<void> _previewEntryAnimation() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 24,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PhoenixWingLoadingView(
                  title: 'Предпросмотр анимации входа',
                  subtitle: 'Качественная анимация на основе исходной иконки',
                  size: 132,
                ),
                const SizedBox(height: 12),
                Text(
                  'Проверьте плавность, контраст и читаемость на вашем устройстве.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Закрыть'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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

  Future<Map<String, dynamic>?> _runSubscriptionBulkMode(
    String mode, {
    int? warningHours,
    bool? includeDefaultOverride,
    bool? dryRunOverride,
    List<Map<String, dynamic>>? snapshotOverride,
    bool showNotice = true,
  }) async {
    if (_subscriptionTestBusy) return null;
    final includeDefault =
        includeDefaultOverride ?? _subscriptionIncludeDefault;
    final dryRun = dryRunOverride ?? _subscriptionDryRun;
    final effectiveWarningHours = (warningHours ?? _subscriptionWarningHours)
        .clamp(1, 72);
    final snapshot = snapshotOverride ?? _subscriptionSnapshot;

    if (mode == 'restore_snapshot' && snapshot.isEmpty) {
      showAppNotice(
        context,
        'Снимок до теста пуст. Сначала запустите любой тест подписки.',
        tone: AppNoticeTone.warning,
      );
      return null;
    }

    setState(() => _subscriptionTestBusy = true);
    try {
      final payload = <String, dynamic>{
        'mode': mode,
        'include_default': includeDefault,
        'dry_run': dryRun,
      };
      if (mode == 'warn_soon_all') {
        payload['warning_hours'] = effectiveWarningHours;
      }
      if (mode == 'restore_snapshot') {
        payload['snapshot'] = snapshot;
      }

      final resp = await authService.dio.post(
        '/api/admin/test/tenants/subscriptions',
        data: payload,
      );
      final root = _asMap(
        resp.data,
        context: '/api/admin/test/tenants/subscriptions',
      );
      if (root['ok'] != true) {
        throw Exception('test.tenants.subscriptions: ok != true');
      }
      final data = _asMap(
        root['data'],
        context: '/api/admin/test/tenants/subscriptions.data',
      );

      final before = _asMapListSafe(data['before']);
      if (mode != 'restore_snapshot' && before.isNotEmpty) {
        _subscriptionSnapshot = before;
      }
      if (mode == 'activate_all' || mode == 'restore_snapshot') {
        // После восстановления/активации старый снимок уже не актуален.
        _subscriptionSnapshot = mode == 'restore_snapshot'
            ? const []
            : _subscriptionSnapshot;
      }

      if (!mounted) return data;
      setState(() {
        _subscriptionSummary = Map<String, dynamic>.from(data);
      });

      if (showNotice) {
        final total = data['total'] ?? 0;
        final changed = data['changed'] ?? 0;
        final marker = dryRun ? ' (dry-run)' : '';
        showAppNotice(
          context,
          'Тест подписки$marker: mode=$mode, изменено $changed из $total',
          tone: AppNoticeTone.success,
        );
      }
      return data;
    } catch (e) {
      if (!mounted) return null;
      showAppNotice(
        context,
        'Ошибка теста подписки: ${_safeError(e)}',
        tone: AppNoticeTone.error,
      );
      return null;
    } finally {
      if (mounted) {
        setState(() => _subscriptionTestBusy = false);
      }
    }
  }

  Future<void> _showSubscriptionBlockedTestBanner() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Тест отключения подписки'),
          content: Text(
            'Подписка отключена. Свяжитесь с Вазгеном.\n\n'
            'Это тестовая плашка, её можно закрыть.',
            style: theme.textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  void _showSubscriptionWarningTestBanner() {
    showAppNotice(
      context,
      'Подписка истекает завтра в 12:00. Продлите заранее.',
      title: 'Тест уведомления о конце подписки',
      tone: AppNoticeTone.warning,
      duration: const Duration(seconds: 4),
    );
  }

  Future<void> _runApiBenchmark() async {
    if (_apiBenchmarkBusy) return;
    setState(() => _apiBenchmarkBusy = true);
    final checks = <Map<String, dynamic>>[
      {
        'id': 'health',
        'title': '/health',
        'runner': () => authService.dio.get('/health'),
      },
      {
        'id': 'profile',
        'title': '/api/profile',
        'runner': () => authService.dio.get('/api/profile'),
      },
      {
        'id': 'chats',
        'title': '/api/chats',
        'runner': () => authService.dio.get('/api/chats'),
      },
    ];

    try {
      final report = <String, dynamic>{};
      for (final check in checks) {
        final id = check['id'].toString();
        final title = check['title'].toString();
        final runner = check['runner'] as Future<dynamic> Function();
        final samples = <int>[];
        String? error;

        for (var i = 0; i < 5; i++) {
          final sw = Stopwatch()..start();
          try {
            await runner();
            sw.stop();
            samples.add(sw.elapsedMilliseconds);
          } catch (e) {
            sw.stop();
            error = _safeError(e);
            break;
          }
        }

        if (error != null) {
          report[id] = {
            'title': title,
            'ok': false,
            'samples': samples,
            'error': error,
          };
          continue;
        }
        final stats = _latencyStats(samples);
        report[id] = {
          'title': title,
          'ok': true,
          'samples': samples,
          'min_ms': stats['min'],
          'avg_ms': stats['avg'],
          'p95_ms': stats['p95'],
          'max_ms': stats['max'],
        };
      }

      if (!mounted) return;
      setState(() {
        _apiBenchmarkSummary = {
          'generated_at': DateTime.now().toIso8601String(),
          'results': report,
        };
      });
      final hasErrors = report.values.any(
        (item) => item is Map && item['ok'] != true,
      );
      showAppNotice(
        context,
        hasErrors
            ? 'API benchmark завершен с ошибками'
            : 'API benchmark завершен успешно',
        tone: hasErrors ? AppNoticeTone.warning : AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка API benchmark: ${_safeError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _apiBenchmarkBusy = false);
    }
  }

  Future<void> _loadTenantMatrix({bool showNotice = true}) async {
    if (_tenantMatrixBusy || !_isPlatformCreator) return;
    setState(() => _tenantMatrixBusy = true);
    try {
      final resp = await authService.dio.post(
        '/api/admin/test/tenants/matrix',
        data: {
          'include_deleted': _tenantMatrixIncludeDeleted,
          'include_default': _tenantMatrixIncludeDefault,
        },
      );
      final root = _asMap(resp.data, context: '/api/admin/test/tenants/matrix');
      if (root['ok'] != true) {
        throw Exception('/api/admin/test/tenants/matrix: ok != true');
      }
      final data = _asMap(
        root['data'],
        context: '/api/admin/test/tenants/matrix.data',
      );
      if (!mounted) return;
      setState(() => _tenantMatrixSummary = data);
      if (showNotice) {
        final total = data['total'] ?? 0;
        showAppNotice(
          context,
          'Матрица арендаторов обновлена ($total)',
          tone: AppNoticeTone.success,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка матрицы арендаторов: ${_safeError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _tenantMatrixBusy = false);
    }
  }

  Future<void> _runTenantIntegrityCheck({bool refresh = true}) async {
    if (!_isPlatformCreator) {
      showAppNotice(
        context,
        'Проверка доступна только платформенному Создателю',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    if (refresh) {
      await _loadTenantMatrix(showNotice: false);
    }
    if (!mounted) return;
    final summaryRaw = _tenantMatrixSummary?['summary'];
    final summary = summaryRaw is Map
        ? Map<String, dynamic>.from(summaryRaw)
        : const <String, dynamic>{};
    final missingMain =
        int.tryParse((summary['missing_main_channel'] ?? 0).toString()) ?? 0;
    final missingStaff =
        int.tryParse((summary['missing_staff'] ?? 0).toString()) ?? 0;
    final expired = int.tryParse((summary['expired'] ?? 0).toString()) ?? 0;
    final expiringSoon =
        int.tryParse((summary['expiring_soon_24h'] ?? 0).toString()) ?? 0;

    final hasProblems =
        missingMain > 0 || missingStaff > 0 || expired > 0 || expiringSoon > 0;
    final text =
        'Проблемы: main_channel=$missingMain, staff=$missingStaff, expired=$expired, expiring_24h=$expiringSoon';
    showAppNotice(
      context,
      hasProblems ? text : 'Целостность арендаторов: критичных проблем нет',
      tone: hasProblems ? AppNoticeTone.warning : AppNoticeTone.success,
      duration: const Duration(seconds: 4),
    );
  }

  Future<void> _runFullSmokePack() async {
    if (_fullSmokeBusy) return;
    setState(() => _fullSmokeBusy = true);
    try {
      await _runCriticalChecks();
      await _runApiBenchmark();
      if (_isPlatformCreator) {
        await _loadTenantMatrix(showNotice: false);
        await _runTenantIntegrityCheck(refresh: false);
      }
      if (!mounted) return;
      showAppNotice(context, 'Смоук-пак завершен', tone: AppNoticeTone.success);
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка смоук-пака: ${_safeError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _fullSmokeBusy = false);
    }
  }

  Future<void> _copyTestsReport() async {
    final report = _buildTestsReportJson();
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    showAppNotice(
      context,
      'JSON-отчет тестов скопирован',
      tone: AppNoticeTone.success,
    );
  }

  Future<void> _runSubscriptionScenario() async {
    if (_subscriptionScenarioBusy || _subscriptionTestBusy) return;
    final snapshotBeforeScenario = List<Map<String, dynamic>>.from(
      (_subscriptionSnapshot.isNotEmpty
              ? _subscriptionSnapshot
              : _asMapListSafe(_subscriptionSummary?['before']))
          .map((row) => Map<String, dynamic>.from(row)),
    );
    if (snapshotBeforeScenario.isEmpty) {
      showAppNotice(
        context,
        'Нет снимка для безопасного восстановления. Сначала выполните любой тест подписки.',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() => _subscriptionScenarioBusy = true);
    try {
      final warnResult = await _runSubscriptionBulkMode(
        'warn_soon_all',
        warningHours: _subscriptionWarningHours,
        dryRunOverride: false,
        showNotice: false,
      );
      if (warnResult == null) return;

      final expireResult = await _runSubscriptionBulkMode(
        'expire_all',
        dryRunOverride: false,
        showNotice: false,
      );
      if (expireResult == null) return;

      final restoreResult = await _runSubscriptionBulkMode(
        'restore_snapshot',
        dryRunOverride: false,
        snapshotOverride: snapshotBeforeScenario,
        showNotice: false,
      );
      if (restoreResult == null) return;

      if (!mounted) return;
      showAppNotice(
        context,
        'Сценарий завершен: предупреждение -> истечение -> восстановление',
        tone: AppNoticeTone.success,
        duration: const Duration(seconds: 4),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка автосценария подписки: ${_safeError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _subscriptionScenarioBusy = false);
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

  Widget _subscriptionTestsCard() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;
    final summary = _subscriptionSummary ?? const <String, dynamic>{};
    final before = _asMapListSafe(summary['before']);
    final after = _asMapListSafe(summary['after']);
    final rows = after.isNotEmpty ? after : before;
    final beforeById = <String, Map<String, dynamic>>{
      for (final row in before) (row['id'] ?? '').toString(): row,
    };
    final total = summary['total'] ?? 0;
    final changed = summary['changed'] ?? 0;
    final activeCount = summary['active_count'] ?? 0;
    final blockedCount = summary['blocked_count'] ?? 0;
    final dryRunResult = _toBool(summary['dry_run']);
    final includeDefaultResult = _toBool(summary['include_default']);
    final canRun = _isPlatformCreator;
    final busy = _subscriptionTestBusy || _subscriptionScenarioBusy;

    Color statusColor(String status) {
      final value = status.trim().toLowerCase();
      if (value == 'active') return theme.colorScheme.tertiary;
      if (value == 'blocked') return theme.colorScheme.error;
      return theme.colorScheme.outline;
    }

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
            'Массовые тесты подписки арендаторов',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Действия применяются ко всем арендаторам (кроме системного default). '
            'Можно быстро включать/выключать подписки и проверять предупреждения.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (!canRun) ...[
            const SizedBox(height: 10),
            Text(
              'Эти массовые тесты доступны только платформенному Создателю.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: busy ? null : _showSubscriptionBlockedTestBanner,
                icon: const Icon(Icons.lock_outline_rounded),
                label: const Text('Тест отключения подписки'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : _showSubscriptionWarningTestBanner,
                icon: const Icon(Icons.schedule_outlined),
                label: const Text('Тест уведомления о конце подписки'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SwitchListTile.adaptive(
                  dense: true,
                  value: _subscriptionDryRun,
                  onChanged: !canRun || busy
                      ? null
                      : (value) => setState(() => _subscriptionDryRun = value),
                  title: const Text('Dry-run'),
                  subtitle: const Text('Проверка без изменения подписок'),
                ),
              ),
              Expanded(
                child: SwitchListTile.adaptive(
                  dense: true,
                  value: _subscriptionIncludeDefault,
                  onChanged: !canRun || busy
                      ? null
                      : (value) =>
                            setState(() => _subscriptionIncludeDefault = value),
                  title: const Text('Включить default'),
                  subtitle: const Text('Обычно лучше выключено'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Часы для предупреждения: $_subscriptionWarningHours ч',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Slider(
            value: _subscriptionWarningHours.toDouble(),
            min: 1,
            max: 72,
            divisions: 71,
            onChanged: !canRun || busy
                ? null
                : (value) {
                    setState(() {
                      _subscriptionWarningHours = value.round();
                    });
                  },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: !canRun || busy
                    ? null
                    : () => _runSubscriptionBulkMode('block_all'),
                icon: const Icon(Icons.block_rounded),
                label: Text(
                  busy ? 'Выполняется...' : 'Отключить всем арендаторам',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: !canRun || busy
                    ? null
                    : () => _runSubscriptionBulkMode(
                        'warn_soon_all',
                        warningHours: _subscriptionWarningHours,
                      ),
                icon: const Icon(Icons.hourglass_bottom_outlined),
                label: Text('Истекает через $_subscriptionWarningHoursч'),
              ),
              FilledButton.tonalIcon(
                onPressed: !canRun || busy
                    ? null
                    : () => _runSubscriptionBulkMode('expire_all'),
                icon: const Icon(Icons.timer_off_outlined),
                label: const Text('Истекло прямо сейчас'),
              ),
              FilledButton.tonalIcon(
                onPressed: !canRun || busy
                    ? null
                    : () => _runSubscriptionBulkMode('activate_all'),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Включить всем арендаторам'),
              ),
              FilledButton.tonalIcon(
                onPressed: !canRun || busy || _subscriptionSnapshot.isEmpty
                    ? null
                    : () => _runSubscriptionBulkMode('restore_snapshot'),
                icon: const Icon(Icons.restore_rounded),
                label: Text(
                  _subscriptionSnapshot.isEmpty
                      ? 'Восстановить (снимка нет)'
                      : 'Восстановить до теста',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: !canRun || busy ? null : _runSubscriptionScenario,
                icon: const Icon(Icons.auto_mode_outlined),
                label: const Text('Автосценарий (warn->expire->restore)'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Результат: mode=${summary['mode'] ?? '—'}, total=$total, changed=$changed, '
            'active=$activeCount, blocked=$blockedCount, dry_run=$dryRunResult, include_default=$includeDefaultResult',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Text(
              'Запустите любой тест подписки, чтобы увидеть список арендаторов до/после.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...rows.take(10).map((row) {
              final id = (row['id'] ?? '').toString();
              final code = (row['code'] ?? '').toString().trim();
              final name = (row['name'] ?? '').toString().trim();
              final status = (row['status'] ?? '').toString().trim();
              final prev = beforeById[id];
              final prevStatus = (prev?['status'] ?? '').toString().trim();
              final nowExpiry = _formatDateTimeShort(
                row['subscription_expires_at'],
              );
              final prevExpiry = _formatDateTimeShort(
                prev?['subscription_expires_at'],
              );
              final changedStatus = prev != null && prevStatus != status;
              return Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: statusColor(status)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$code ${name.isEmpty ? '' : '· $name'}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Статус: ${prevStatus.isEmpty ? '—' : prevStatus} -> $status'
                            '${changedStatus ? '  (изменен)' : ''}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            'Подписка: $prevExpiry -> $nowExpiry',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
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

  Widget _smokeControlCard() {
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
            'Смоук-пак и отчёт',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Один запуск проверяет критичные API, benchmark и матрицу арендаторов (для платформенного создателя).',
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
                onPressed: _fullSmokeBusy ? null : _runFullSmokePack,
                icon: const Icon(Icons.playlist_add_check_circle_outlined),
                label: Text(
                  _fullSmokeBusy
                      ? 'Смоук-пак выполняется...'
                      : 'Запустить смоук-пак',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _copyTestsReport,
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Копировать JSON-отчёт'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _apiBenchmarkCard() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;
    final resultsRaw = _apiBenchmarkSummary?['results'];
    final results = resultsRaw is Map
        ? Map<String, dynamic>.from(resultsRaw)
        : const <String, dynamic>{};

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
                onPressed: _apiBenchmarkBusy ? null : _runApiBenchmark,
                icon: const Icon(Icons.speed_rounded),
                label: Text(
                  _apiBenchmarkBusy
                      ? 'Benchmark выполняется...'
                      : 'Запустить API benchmark',
                ),
              ),
              Text(
                '5 запросов на endpoint',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (results.isEmpty)
            Text(
              'Пока нет данных benchmark',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...results.values.whereType<Map>().map((raw) {
              final row = Map<String, dynamic>.from(raw);
              final ok = _toBool(row['ok']);
              final title = (row['title'] ?? '').toString();
              final error = (row['error'] ?? '').toString().trim();
              final avg = row['avg_ms'];
              final p95 = row['p95_ms'];
              final max = row['max_ms'];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      ok ? Icons.check_circle_outline : Icons.error_outline,
                      color: ok
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ok
                            ? '$title · avg=${avg ?? 0}ms, p95=${p95 ?? 0}ms, max=${max ?? 0}ms'
                            : '$title · ошибка: $error',
                        style: theme.textTheme.bodySmall,
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

  Widget _tenantMatrixCard() {
    final theme = Theme.of(context);
    final compact = MediaQuery.of(context).size.width < 680;
    final data = _tenantMatrixSummary ?? const <String, dynamic>{};
    final summaryRaw = data['summary'];
    final summary = summaryRaw is Map
        ? Map<String, dynamic>.from(summaryRaw)
        : const <String, dynamic>{};
    final rows = _asMapListSafe(data['rows']);
    final canRun = _isPlatformCreator;

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
            children: [
              FilledButton.tonalIcon(
                onPressed: !canRun || _tenantMatrixBusy
                    ? null
                    : () => _loadTenantMatrix(showNotice: true),
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Матрица арендаторов'),
              ),
              FilledButton.tonalIcon(
                onPressed: !canRun || _tenantMatrixBusy
                    ? null
                    : () => _runTenantIntegrityCheck(refresh: true),
                icon: const Icon(Icons.rule_folder_outlined),
                label: const Text('Проверка целостности'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SwitchListTile.adaptive(
                  dense: true,
                  value: _tenantMatrixIncludeDefault,
                  onChanged: !canRun || _tenantMatrixBusy
                      ? null
                      : (value) =>
                            setState(() => _tenantMatrixIncludeDefault = value),
                  title: const Text('Показывать default'),
                ),
              ),
              Expanded(
                child: SwitchListTile.adaptive(
                  dense: true,
                  value: _tenantMatrixIncludeDeleted,
                  onChanged: !canRun || _tenantMatrixBusy
                      ? null
                      : (value) =>
                            setState(() => _tenantMatrixIncludeDeleted = value),
                  title: const Text('Показывать удаленных'),
                ),
              ),
            ],
          ),
          if (!canRun)
            Text(
              'Матрица доступна только платформенному Создателю.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Итог: total=${data['total'] ?? 0}, active=${summary['active'] ?? 0}, '
            'blocked=${summary['blocked'] ?? 0}, expired=${summary['expired'] ?? 0}, '
            'soon24h=${summary['expiring_soon_24h'] ?? 0}, no_main=${summary['missing_main_channel'] ?? 0}, no_staff=${summary['missing_staff'] ?? 0}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text(
              'Нет данных. Нажмите "Матрица арендаторов".',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...rows.take(12).map((row) {
              final code = (row['code'] ?? '').toString().trim();
              final status = (row['status'] ?? '').toString().trim();
              final dbMode = (row['db_mode'] ?? '').toString().trim();
              final users = row['user_count'] ?? 0;
              final staff = row['staff_count'] ?? 0;
              final hasMain = _toBool(row['has_main_channel']);
              final expiresAt = _formatDateTimeShort(
                row['subscription_expires_at'],
              );
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  '$code · status=$status · db=$dbMode · users=$users · staff=$staff · main=$hasMain · exp=$expiresAt',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }),
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
            _sectionTitle('Смоук-пак'),
            const SizedBox(height: 12),
            _smokeControlCard(),
            const SizedBox(height: 24),
            _sectionTitle('Тесты подписки'),
            const SizedBox(height: 12),
            _subscriptionTestsCard(),
            const SizedBox(height: 24),
            _sectionTitle('API Benchmark'),
            const SizedBox(height: 12),
            _apiBenchmarkCard(),
            if (_isPlatformCreator) ...[
              const SizedBox(height: 24),
              _sectionTitle('Арендаторы'),
              const SizedBox(height: 12),
              _tenantMatrixCard(),
            ],
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const PhoenixWingLoadingView(
                    title: 'Проверка входной анимации',
                    subtitle: 'Реальный лоадер стартового экрана',
                    size: 108,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _previewEntryAnimation,
                    icon: const Icon(Icons.play_circle_outline_rounded),
                    label: const Text('Открыть тест анимации входа'),
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
