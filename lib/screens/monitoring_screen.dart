import 'dart:convert';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/notification_device_service.dart';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  bool _loading = true;
  String _error = '';
  Map<String, dynamic> _center = const <String, dynamic>{};
  Map<String, dynamic> _realtime = const <String, dynamic>{};
  Map<String, dynamic> _releases = const <String, dynamic>{};
  List<Map<String, dynamic>> _events = const <Map<String, dynamic>>[];
  final Set<String> _expandedEventIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 0;
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final centerResp = await authService.dio.get(
        '/api/admin/ops/monitoring/center',
      );
      final realtimeResp = await authService.dio.get(
        '/api/admin/ops/monitoring/realtime',
      );
      final releasesResp = await authService.dio.get(
        '/api/admin/ops/monitoring/releases',
      );
      final eventsResp = await authService.dio.get(
        '/api/admin/ops/monitoring/events',
        queryParameters: {'limit': 80},
      );
      if (!mounted) return;
      setState(() {
        _center = _asMap(_asMap(centerResp.data)['data']);
        _realtime = _asMap(_asMap(realtimeResp.data)['data']);
        _releases = _asMap(_asMap(releasesResp.data)['data']);
        _events = _asMapList(_asMap(eventsResp.data)['data']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _resolveEvent(String eventId) async {
    try {
      await authService.dio.patch('/api/admin/ops/monitoring/events/$eventId/resolve');
      if (!mounted) return;
      setState(() {
        _events = _events
            .map((event) => event['id'] == eventId
                ? <String, dynamic>{...event, 'resolved': true}
                : event)
            .toList(growable: false);
      });
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось отметить событие: $e',
        tone: AppNoticeTone.error,
      );
    }
  }

  Widget _section(String title, Widget child, {String? subtitle}) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
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
              subtitle!,
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

  Widget _metricChip(String label, String value, {Color? tone}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone?.withValues(alpha: 0.14) ?? theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
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

  Widget _kv(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreatorScopeSection() {
    final user = authService.currentUser;
    final socketDiag = runtimeSocketDiagnosticsSnapshot();
    final endpointDiag = NotificationDeviceService.lastSyncSnapshot;
    return _section(
      'Tenant Scope',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Базовая роль', user?.role ?? '—'),
          _kv('Эффективная роль', authService.effectiveRole),
          _kv('View role', authService.viewRole ?? '—'),
          _kv('Tenant code', authService.creatorTenantScopeCode ?? user?.tenantCode ?? '—'),
          _kv('Tenant name', user?.tenantName ?? '—'),
          _kv('Сессия', authService.isSessionDegraded
              ? 'degraded: ${authService.sessionDegradedReason ?? 'unknown'}'
              : 'normal'),
          _kv('Socket', jsonEncode(socketDiag)),
          _kv('Device endpoint', jsonEncode(endpointDiag)),
        ],
      ),
      subtitle: 'Creator-only диагностика текущего scope, сокета и device endpoint.',
    );
  }

  Widget _buildCenterSection() {
    final monitoring = _asMap(_center['monitoring']);
    final queue = _asMap(_center['queue']);
    final antifraud = _asMap(_center['antifraud']);
    final database = _asMap(_center['database']);
    final push = _asMap(_center['push']);
    return _section(
      'Центр мониторинга',
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _metricChip('Ошибка 7д', '${_toInt(monitoring['error'])}'),
          _metricChip('Critical 7д', '${_toInt(monitoring['critical'])}'),
          _metricChip('Pending посты', '${_toInt(queue['pending_posts'])}'),
          _metricChip('Активные блоки', '${_toInt(antifraud['active_blocks'])}'),
          _metricChip('DB latency', '${_toInt(database['latency_ms'])} ms'),
          _metricChip('Push endpoints', '${_toInt(push['active_endpoint_count'])}'),
        ],
      ),
    );
  }

  Widget _buildRealtimeSection() {
    final snapshot = _asMap(_realtime['snapshot']);
    final disconnects = _asMapList(snapshot['top_disconnect_reasons']);
    return _section(
      'Realtime',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _metricChip('Соединения', '${_toInt(snapshot['active_connections'])}'),
              _metricChip('Recovered', '${_toInt(snapshot['recovered_connections'])}'),
              _metricChip('Unrecovered', '${_toInt(snapshot['unrecovered_connections'])}'),
              _metricChip('Join denied', '${_toInt(snapshot['join_denied'])}'),
              _metricChip('Replay fallback', '${_toInt(snapshot['replay_fallback_count'])}'),
              _metricChip('Outbox fail', '${_toInt(snapshot['outbox_retry_failures'])}'),
            ],
          ),
          if (disconnects.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Top disconnect reasons'),
            const SizedBox(height: 8),
            ...disconnects.map(
              (row) => _kv(
                row['key']?.toString() ?? 'unknown',
                '${_toInt(row['count'])}',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReleaseSection() {
    final latest = _asMapList(_releases['latest']);
    return _section(
      'Релизы и smoke',
      Column(
        children: latest.take(6).map((row) {
          final status = (row['status'] ?? '').toString();
          final color = switch (status) {
            'pass' => Colors.green,
            'warn' => Colors.orange,
            'fail' => Colors.red,
            _ => Colors.blueGrey,
          };
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.24)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (row['title'] ?? 'Release check').toString(),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                _kv('Scope', (row['scope'] ?? '—').toString()),
                _kv('Status', status),
                _kv('Version', '${row['version_name'] ?? '—'}+${row['build_number'] ?? '—'}'),
                _kv('Target', (row['target'] ?? '—').toString()),
                _kv('Summary', (row['summary'] ?? '—').toString()),
              ],
            ),
          );
        }).toList(growable: false),
      ),
    );
  }

  Widget _buildEventsSection() {
    final theme = Theme.of(context);
    return _section(
      'События',
      Column(
        children: _events.map((event) {
          final id = (event['id'] ?? '').toString();
          final level = (event['level'] ?? 'info').toString();
          final expanded = _expandedEventIds.contains(id);
          final details = event['details'];
          final color = switch (level) {
            'critical' => theme.colorScheme.error,
            'error' => theme.colorScheme.error,
            'warn' => Colors.orange,
            _ => theme.colorScheme.primary,
          };
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              children: [
                ListTile(
                  onTap: () {
                    setState(() {
                      if (expanded) {
                        _expandedEventIds.remove(id);
                      } else {
                        _expandedEventIds.add(id);
                      }
                    });
                  },
                  title: Text((event['message'] ?? 'Событие').toString()),
                  subtitle: Text(
                    '${event['subsystem'] ?? 'general'} • ${event['code'] ?? '—'} • ${event['created_at'] ?? ''}',
                  ),
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.16),
                    child: Icon(Icons.bug_report_outlined, color: color),
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (event['resolved'] != true)
                        TextButton(
                          onPressed: () => _resolveEvent(id),
                          child: const Text('Resolve'),
                        ),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                ),
                if (expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(details),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          );
        }).toList(growable: false),
      ),
      subtitle: 'Показываются уже очищенные structured events без токенов и содержимого ЛС.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Мониторинг')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(onPressed: _load, child: const Text('Повторить')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Мониторинг'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildCenterSection(),
            _buildRealtimeSection(),
            _buildReleaseSection(),
            _buildCreatorScopeSection(),
            _buildEventsSection(),
          ],
        ),
      ),
    );
  }
}
