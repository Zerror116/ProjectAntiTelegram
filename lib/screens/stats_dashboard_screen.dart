import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';

class StatsDashboardScreen extends StatefulWidget {
  const StatsDashboardScreen({super.key});

  @override
  State<StatsDashboardScreen> createState() => _StatsDashboardScreenState();
}

class _StatsDashboardScreenState extends State<StatsDashboardScreen> {
  bool _loading = true;
  bool _financeLoading = false;
  bool _returnsLoading = false;
  String _error = '';
  Map<String, dynamic> _extended = const <String, dynamic>{};
  Map<String, dynamic> _finance = const <String, dynamic>{};
  Map<String, dynamic> _returns = const <String, dynamic>{};
  final Set<String> _expandedWorkerIds = <String>{};
  final Map<String, String> _workerDetailModes = <String, String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed ?? 0;
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value?.toString() ?? '');
    return parsed ?? 0;
  }

  String _formatMoney(dynamic value, {bool compact = false}) {
    final amount = _toDouble(value);
    final digits = compact && amount == amount.roundToDouble() ? 0 : 2;
    final fixed = amount.toStringAsFixed(digits);
    final parts = fixed.split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ' ',
    );
    if (digits == 0) return '$whole ₽';
    return '$whole.${parts[1]} ₽';
  }

  String _dayShortLabel(String rawDay) {
    final date = DateTime.tryParse(rawDay);
    if (date == null) return rawDay;
    const labels = <int, String>{
      DateTime.monday: 'Пн',
      DateTime.tuesday: 'Вт',
      DateTime.wednesday: 'Ср',
      DateTime.thursday: 'Чт',
      DateTime.friday: 'Пт',
      DateTime.saturday: 'Сб',
      DateTime.sunday: 'Вс',
    };
    return labels[date.weekday] ?? rawDay;
  }

  String _workerStatusLabel(Map<String, dynamic> worker) {
    if (worker['active_today'] == true) return 'Работает сегодня';
    if (_toInt(worker['posts_current_week']) > 0) return 'Работал на неделе';
    return 'Пока без активности';
  }

  Color _workerStatusColor(ThemeData theme, Map<String, dynamic> worker) {
    if (worker['active_today'] == true) return const Color(0xFF1F9D55);
    if (_toInt(worker['posts_current_week']) > 0) {
      return theme.colorScheme.primary;
    }
    return theme.colorScheme.outline;
  }

  String _currentModeForWorker(String workerId) {
    return _workerDetailModes[workerId] ?? 'current_week';
  }

  List<Map<String, dynamic>> _detailDaysForMode(
    Map<String, dynamic> worker,
    String mode,
  ) {
    switch (mode) {
      case 'previous_week':
        return _asMapList(worker['days_previous_week']);
      case 'history_14':
        return _asMapList(worker['history_14_days']);
      case 'current_week':
      default:
        return _asMapList(worker['days_current_week']);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }

    try {
      final extResp = await authService.dio.get(
        '/api/profile/stats/extended',
        queryParameters: {'downtime_window_days': 30},
      );
      final extRoot = _asMap(extResp.data);
      if (extRoot['ok'] != true || extRoot['data'] is! Map) {
        throw Exception('Ошибка загрузки расширенной статистики');
      }
      final nextExtended = _asMap(extRoot['data']);

      if (!mounted) return;
      setState(() {
        _extended = nextExtended;
        _finance = const <String, dynamic>{};
        _returns = const <String, dynamic>{};
        _financeLoading = true;
        _returnsLoading = true;
        _loading = false;
        _error = '';
      });
      unawaited(_loadSecondaryStats());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadSecondaryStats() async {
    try {
      final results = await Future.wait<dynamic>([
        authService.dio.get(
          '/api/admin/ops/finance/summary',
          queryParameters: {'period': 'month'},
        ),
        authService.dio.get(
          '/api/admin/ops/returns/analytics',
          queryParameters: {'days': 30, 'top_limit': 8},
        ),
      ]);
      final financeRoot = _asMap(results[0].data);
      final returnsRoot = _asMap(results[1].data);
      if (!mounted) return;
      setState(() {
        _finance = financeRoot['ok'] == true && financeRoot['data'] is Map
            ? _asMap(financeRoot['data'])
            : const <String, dynamic>{};
        _returns = returnsRoot['ok'] == true && returnsRoot['data'] is Map
            ? _asMap(returnsRoot['data'])
            : const <String, dynamic>{};
        _financeLoading = false;
        _returnsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _financeLoading = false;
        _returnsLoading = false;
      });
    }
  }

  Widget _section({
    required String title,
    required Widget child,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if ((subtitle ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _summaryCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: 160,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(height: 10),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactMetricRow({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _weekStatusStrip(List<Map<String, dynamic>> days) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: days.map((day) {
        final worked = day['worked'] == true;
        final isToday = day['is_today'] == true;
        final postsCount = _toInt(day['posts_count']);
        final bgColor = worked
            ? const Color(0x1422C55E)
            : theme.colorScheme.surfaceContainerHighest;
        final borderColor = isToday
            ? theme.colorScheme.primary
            : worked
                ? const Color(0x6622C55E)
                : theme.colorScheme.outlineVariant;
        final iconColor = worked
            ? const Color(0xFF1F9D55)
            : theme.colorScheme.outline;
        return Container(
          width: 52,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            children: [
              Text(
                _dayShortLabel((day['day'] ?? '').toString()),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Icon(
                worked ? Icons.check_rounded : Icons.close_rounded,
                size: 16,
                color: iconColor,
              ),
              const SizedBox(height: 4),
              Text(
                postsCount > 0 ? '$postsCount' : '0',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _detailModeSwitch(String workerId) {
    final mode = _currentModeForWorker(workerId);
    final items = const <MapEntry<String, String>>[
      MapEntry('current_week', 'Эта неделя'),
      MapEntry('previous_week', 'Прошлая'),
      MapEntry('history_14', '14 дней'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((entry) {
        return ChoiceChip(
          label: Text(entry.value),
          selected: mode == entry.key,
          onSelected: (_) {
            setState(() {
              _workerDetailModes[workerId] = entry.key;
            });
          },
        );
      }).toList(),
    );
  }

  Widget _dayScaleRows(List<Map<String, dynamic>> days) {
    final theme = Theme.of(context);
    if (days.isEmpty) {
      return Text(
        'Нет данных по выбранному периоду.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final maxAmount = days.fold<double>(
      0,
      (maxValue, day) => _toDouble(day['posted_amount']) > maxValue
          ? _toDouble(day['posted_amount'])
          : maxValue,
    );
    final maxPosts = days.fold<int>(
      0,
      (maxValue, day) => _toInt(day['posts_count']) > maxValue
          ? _toInt(day['posts_count'])
          : maxValue,
    );

    return Column(
      children: days.map((day) {
        final worked = day['worked'] == true;
        final amount = _toDouble(day['posted_amount']);
        final posts = _toInt(day['posts_count']);
        final baseValue = maxAmount > 0 ? amount : posts.toDouble();
        final maxBase = maxAmount > 0 ? maxAmount : maxPosts.toDouble();
        final ratio = maxBase <= 0 || baseValue <= 0
            ? 0.0
            : (baseValue / maxBase).clamp(0.08, 1.0);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  _dayShortLabel((day['day'] ?? '').toString()),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                worked ? Icons.check_circle_rounded : Icons.cancel_rounded,
                size: 16,
                color: worked ? const Color(0xFF1F9D55) : theme.colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Stack(
                    children: [
                      Container(
                        height: 12,
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      FractionallySizedBox(
                        widthFactor: ratio,
                        child: Container(
                          height: 12,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: worked
                                  ? const [Color(0xFF27C46B), Color(0xFF0EA5E9)]
                                  : [
                                      theme.colorScheme.outlineVariant,
                                      theme.colorScheme.outline,
                                    ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 124,
                child: Text(
                  worked
                      ? '$posts пост. · ${_formatMoney(amount, compact: true)}'
                      : 'нет постов',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _workerCard(Map<String, dynamic> worker) {
    final theme = Theme.of(context);
    final workerId = (worker['worker_id'] ?? '').toString();
    final isExpanded = _expandedWorkerIds.contains(workerId);
    final currentWeekDays = _asMapList(worker['days_current_week']);
    final detailDays = _detailDaysForMode(worker, _currentModeForWorker(workerId));
    final statusColor = _workerStatusColor(theme, worker);
    final todayAmount = _formatMoney(worker['posted_amount_today'], compact: true);
    final todayPosts = _toInt(worker['posts_today']);
    final todayRevisions = _toInt(worker['revisions_today']);
    final weekPosts = _toInt(worker['posts_current_week']);
    final weekRevisions = _toInt(worker['revisions_current_week']);
    final weekAmount = _formatMoney(worker['posted_amount_current_week'], compact: true);
    final workedDays = _toInt(worker['days_worked_current_week']);
    final downtime = _asMap(worker['post_downtime']);
    final workerName = (worker['worker_name'] ?? 'Работник').toString().trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        workerName.isEmpty ? 'Работник' : workerName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _workerStatusLabel(worker),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: isExpanded ? 'Скрыть детали' : 'Показать детали',
                  onPressed: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedWorkerIds.remove(workerId);
                      } else {
                        _expandedWorkerIds.add(workerId);
                      }
                    });
                  },
                  icon: Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _summaryCard(
                  label: 'Сегодня выложил',
                  value: todayAmount,
                  icon: Icons.currency_ruble_rounded,
                ),
                _summaryCard(
                  label: 'Постов сегодня',
                  value: '$todayPosts',
                  icon: Icons.today_rounded,
                ),
                _summaryCard(
                  label: 'Неделя',
                  value: '$weekPosts пост.',
                  icon: Icons.calendar_view_week_rounded,
                ),
                _summaryCard(
                  label: 'Ревизий сегодня',
                  value: '$todayRevisions',
                  icon: Icons.rule_rounded,
                ),
                _summaryCard(
                  label: 'Ревизий неделя',
                  value: '$weekRevisions',
                  icon: Icons.fact_check_rounded,
                ),
                _summaryCard(
                  label: 'Дней работал',
                  value: '$workedDays / 7',
                  icon: Icons.event_available_rounded,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'На неделе: $weekAmount',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _weekStatusStrip(currentWeekDays),
            if (isExpanded) ...[
              const SizedBox(height: 14),
              _detailModeSwitch(workerId),
              const SizedBox(height: 12),
              _dayScaleRows(detailDays),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timeline_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Средний простой: ${_toDouble(downtime['avg_gap_minutes']).toStringAsFixed(1)} мин · '
                        'максимум: ${_toDouble(downtime['max_gap_minutes']).toStringAsFixed(1)} мин',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWorkerSection() {
    final theme = Theme.of(context);
    final summary = _asMap(_extended['summary']);
    final workers = _asMapList(_extended['workers'])
      ..sort((a, b) {
        final activeCompare = (b['active_today'] == true ? 1 : 0)
            .compareTo(a['active_today'] == true ? 1 : 0);
        if (activeCompare != 0) return activeCompare;
        final amountCompare = _toDouble(b['posted_amount_today'])
            .compareTo(_toDouble(a['posted_amount_today']));
        if (amountCompare != 0) return amountCompare;
        final todayPostsCompare = _toInt(b['posts_today'])
            .compareTo(_toInt(a['posts_today']));
        if (todayPostsCompare != 0) return todayPostsCompare;
        final weekCompare = _toInt(b['posts_current_week'])
            .compareTo(_toInt(a['posts_current_week']));
        if (weekCompare != 0) return weekCompare;
        return (a['worker_name'] ?? '').toString().compareTo(
          (b['worker_name'] ?? '').toString(),
        );
      });

    return _section(
      title: 'Кто работает',
      subtitle:
          'Показываем работников, их активность по дням, сумму выкладки и сколько товаров они провели через ревизию.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _summaryCard(
                label: 'Работают сегодня',
                value: '${_toInt(summary['workers_active_today'])}',
                icon: Icons.badge_rounded,
              ),
              _summaryCard(
                label: 'Работали на неделе',
                value: '${_toInt(summary['workers_active_current_week'])}',
                icon: Icons.group_rounded,
              ),
              _summaryCard(
                label: 'Выложили сегодня',
                value: _formatMoney(summary['posted_amount_today'], compact: true),
                icon: Icons.sell_rounded,
              ),
              _summaryCard(
                label: 'Постов сегодня',
                value: '${_toInt(summary['posts_today'])}',
                icon: Icons.post_add_rounded,
              ),
              _summaryCard(
                label: 'Ревизий сегодня',
                value: '${_toInt(summary['revisions_today'])}',
                icon: Icons.rule_rounded,
              ),
              _summaryCard(
                label: 'Ревизий неделя',
                value: '${_toInt(summary['revisions_current_week'])}',
                icon: Icons.fact_check_rounded,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (workers.isEmpty)
            Text(
              'Нет данных по работникам.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...workers.map(_workerCard),
        ],
      ),
    );
  }

  Widget _buildFinanceSection() {
    final financeSummary = _asMap(_finance['summary']);
    if (_financeLoading) {
      return _section(
        title: 'Финансы за 30 дней',
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (financeSummary.isEmpty) return const SizedBox.shrink();
    return _section(
      title: 'Финансы за 30 дней',
      child: Column(
        children: [
          _compactMetricRow(
            label: 'Выручка',
            value: _formatMoney(financeSummary['revenue']),
            icon: Icons.payments_outlined,
          ),
          const SizedBox(height: 8),
          _compactMetricRow(
            label: 'Прибыль',
            value: _formatMoney(financeSummary['profit']),
            icon: Icons.trending_up_rounded,
          ),
          const SizedBox(height: 8),
          _compactMetricRow(
            label: 'Средний чек',
            value: _formatMoney(financeSummary['avg_check']),
            icon: Icons.receipt_long_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildReturnsSection() {
    final returnsSummary = _asMap(_returns['summary']);
    if (_returnsLoading) {
      return _section(
        title: 'Брак и претензии',
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (returnsSummary.isEmpty) return const SizedBox.shrink();
    return _section(
      title: 'Брак и претензии',
      child: Column(
        children: [
          _compactMetricRow(
            label: 'Всего претензий',
            value: '${_toInt(returnsSummary['total_claims'])}',
            icon: Icons.rule_folder_outlined,
          ),
          const SizedBox(height: 8),
          _compactMetricRow(
            label: 'Сумма брака',
            value: _formatMoney(returnsSummary['defect_sum']),
            icon: Icons.report_problem_outlined,
          ),
          const SizedBox(height: 8),
          _compactMetricRow(
            label: 'Активных одобренных',
            value: '${_toInt(returnsSummary['approved_active_claims'])}',
            icon: Icons.verified_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 22),
        children: [
          _buildWorkerSection(),
          _buildFinanceSection(),
          _buildReturnsSection(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = authService.effectiveRole.toLowerCase().trim();
    final allowed = role == 'admin' || role == 'tenant' || role == 'creator';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Статистика'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: () => _load(silent: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: !allowed
          ? const Center(
              child: Text(
                'Доступно только для администратора, арендатора и создателя',
              ),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty && _extended.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 10),
                            FilledButton(
                              onPressed: () => _load(),
                              child: const Text('Повторить'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _buildContent(),
    );
  }
}
