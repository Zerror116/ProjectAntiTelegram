import 'package:flutter/material.dart';

import '../main.dart';

class StatsDashboardScreen extends StatefulWidget {
  const StatsDashboardScreen({super.key});

  @override
  State<StatsDashboardScreen> createState() => _StatsDashboardScreenState();
}

class _StatsDashboardScreenState extends State<StatsDashboardScreen> {
  bool _loading = true;
  String _error = '';
  Map<String, dynamic> _extended = const <String, dynamic>{};
  Map<String, dynamic> _finance = const <String, dynamic>{};
  Map<String, dynamic> _returns = const <String, dynamic>{};

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

  String _formatMoney(dynamic value) {
    final amount = _toDouble(value);
    return '${amount.toStringAsFixed(2)} ₽';
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

      Map<String, dynamic> nextFinance = const <String, dynamic>{};
      try {
        final financeResp = await authService.dio.get(
          '/api/admin/ops/finance/summary',
          queryParameters: {'period': 'month'},
        );
        final financeRoot = _asMap(financeResp.data);
        if (financeRoot['ok'] == true && financeRoot['data'] is Map) {
          nextFinance = _asMap(financeRoot['data']);
        }
      } catch (_) {}

      Map<String, dynamic> nextReturns = const <String, dynamic>{};
      try {
        final returnsResp = await authService.dio.get(
          '/api/admin/ops/returns/analytics',
          queryParameters: {'days': 30, 'top_limit': 8},
        );
        final returnsRoot = _asMap(returnsResp.data);
        if (returnsRoot['ok'] == true && returnsRoot['data'] is Map) {
          nextReturns = _asMap(returnsRoot['data']);
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _extended = nextExtended;
        _finance = nextFinance;
        _returns = nextReturns;
        _loading = false;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Widget _metricTile({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
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

  Widget _workerWeekLine(String title, List<Map<String, dynamic>> days) {
    final theme = Theme.of(context);
    if (days.isEmpty) {
      return Text(
        '$title: нет данных',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final compact = days
        .map((day) {
          final dayLabel = (day['day'] ?? '').toString();
          final shortDay = dayLabel.length >= 10 ? dayLabel.substring(8, 10) : dayLabel;
          return '$shortDay:${_toInt(day['posts_count'])}';
        })
        .join('  ');
    return Text(
      '$title: $compact',
      style: theme.textTheme.bodySmall,
    );
  }

  Widget _buildContent() {
    final theme = Theme.of(context);
    final summary = _asMap(_extended['summary']);
    final workers = _asMapList(_extended['workers'])
      ..sort(
        (a, b) => _toInt(
          b['posts_current_week'],
        ).compareTo(_toInt(a['posts_current_week'])),
      );
    final financeSummary = _asMap(_finance['summary']);
    final returnsSummary = _asMap(_returns['summary']);

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 22),
        children: [
          _section(
            title: 'Команда за неделю',
            subtitle:
                'Текущая неделя vs предыдущая + средний простой между постами',
            child: Column(
              children: [
                _metricTile(
                  label: 'Рабочих всего',
                  value: '${_toInt(summary['workers_total'])}',
                  icon: Icons.groups_rounded,
                ),
                const SizedBox(height: 8),
                _metricTile(
                  label: 'Активны на этой неделе',
                  value: '${_toInt(summary['workers_active_current_week'])}',
                  icon: Icons.today_rounded,
                ),
                const SizedBox(height: 8),
                _metricTile(
                  label: 'Активны на прошлой неделе',
                  value: '${_toInt(summary['workers_active_previous_week'])}',
                  icon: Icons.history_toggle_off_rounded,
                ),
                const SizedBox(height: 8),
                _metricTile(
                  label: 'Постов: неделя / прошлая',
                  value:
                      '${_toInt(summary['posts_current_week'])} / ${_toInt(summary['posts_previous_week'])}',
                  icon: Icons.post_add_rounded,
                ),
                const SizedBox(height: 8),
                _metricTile(
                  label: 'Простой между постами (средний / максимум)',
                  value:
                      '${_toDouble(summary['overall_avg_gap_minutes']).toStringAsFixed(1)} / ${_toDouble(summary['overall_max_gap_minutes']).toStringAsFixed(1)} мин',
                  icon: Icons.timer_outlined,
                ),
              ],
            ),
          ),
          if (financeSummary.isNotEmpty)
            _section(
              title: 'Финансы (30 дней)',
              child: Column(
                children: [
                  _metricTile(
                    label: 'Выручка',
                    value: _formatMoney(financeSummary['revenue']),
                    icon: Icons.payments_outlined,
                  ),
                  const SizedBox(height: 8),
                  _metricTile(
                    label: 'Прибыль',
                    value: _formatMoney(financeSummary['profit']),
                    icon: Icons.trending_up_rounded,
                  ),
                  const SizedBox(height: 8),
                  _metricTile(
                    label: 'Средний чек',
                    value: _formatMoney(financeSummary['avg_check']),
                    icon: Icons.receipt_long_outlined,
                  ),
                ],
              ),
            ),
          if (returnsSummary.isNotEmpty)
            _section(
              title: 'Брак и претензии (30 дней)',
              child: Column(
                children: [
                  _metricTile(
                    label: 'Всего претензий',
                    value: '${_toInt(returnsSummary['total_claims'])}',
                    icon: Icons.rule_folder_outlined,
                  ),
                  const SizedBox(height: 8),
                  _metricTile(
                    label: 'Сумма брака',
                    value: _formatMoney(returnsSummary['defect_sum']),
                    icon: Icons.report_problem_outlined,
                  ),
                  const SizedBox(height: 8),
                  _metricTile(
                    label: 'Активных одобренных',
                    value: '${_toInt(returnsSummary['approved_active_claims'])}',
                    icon: Icons.verified_outlined,
                  ),
                ],
              ),
            ),
          _section(
            title: 'Рабочие по дням',
            child: workers.isEmpty
                ? Text(
                    'Нет данных по рабочим.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Column(
                    children: workers.map((worker) {
                      final name = (worker['worker_name'] ?? 'Работник')
                          .toString()
                          .trim();
                      final currentDays = _asMapList(worker['days_current_week']);
                      final previousDays =
                          _asMapList(worker['days_previous_week']);
                      final downtime = _asMap(worker['post_downtime']);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name.isEmpty ? 'Работник' : name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Неделя: ${_toInt(worker['posts_current_week'])} постов '
                              '(${_toInt(worker['days_worked_current_week'])}/7 дней) • '
                              'Прошлая: ${_toInt(worker['posts_previous_week'])} '
                              '(${_toInt(worker['days_worked_previous_week'])}/7)',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Простой: avg ${_toDouble(downtime['avg_gap_minutes']).toStringAsFixed(1)} '
                              'мин, max ${_toDouble(downtime['max_gap_minutes']).toStringAsFixed(1)} мин',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _workerWeekLine('Текущая неделя', currentDays),
                            const SizedBox(height: 2),
                            _workerWeekLine('Прошлая неделя', previousDays),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
          ),
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
              child: Text('Доступно только для администратора, арендатора и создателя'),
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
