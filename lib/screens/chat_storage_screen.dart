import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/chat_outbox_service.dart';

class ChatStorageScreen extends StatefulWidget {
  const ChatStorageScreen({
    super.key,
    required this.onClearVisualCache,
    required this.onClearSavedSessions,
  });

  final Future<void> Function() onClearVisualCache;
  final Future<void> Function() onClearSavedSessions;

  @override
  State<ChatStorageScreen> createState() => _ChatStorageScreenState();
}

class _ChatStorageScreenState extends State<ChatStorageScreen> {
  bool _loading = true;
  bool _busy = false;
  _ChatStorageStats _stats = const _ChatStorageStats();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final items = await chatOutboxService.listAll();
      final imageCache = PaintingBinding.instance.imageCache;
      final currentSize = imageCache.currentSizeBytes;
      final liveSize = imageCache.liveImageCount;
      var draftsBytes = 0;
      var failedCount = 0;
      final chatWeights = <String, int>{};
      for (final item in items) {
        final retryPayload = item.retryPayload;
        final bytes = retryPayload['bytes'];
        if (bytes is List<int>) {
          draftsBytes += bytes.length;
        } else if (bytes != null) {
          try {
            final normalized = (jsonDecode(jsonEncode(bytes)) as List).length;
            draftsBytes += normalized;
          } catch (_) {}
        } else if (retryPayload['file_size'] is num) {
          draftsBytes += (retryPayload['file_size'] as num).toInt();
        }
        if (item.status == 'error' || item.status == 'failed_permanent') {
          failedCount += 1;
        }
        chatWeights.update(item.chatId, (value) => value + 1, ifAbsent: () => 1);
      }
      final heaviestChats = chatWeights.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (!mounted) return;
      setState(() {
        _stats = _ChatStorageStats(
          outboxDraftCount: items.length,
          outboxDraftBytes: draftsBytes,
          failedUploadsCount: failedCount,
          imageCacheBytes: currentSize,
          liveImageCount: liveSize,
          heaviestChats: heaviestChats.take(5).toList(growable: false),
        );
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _formatBytes(int raw) {
    if (raw <= 0) return '0 Б';
    const units = ['Б', 'КБ', 'МБ', 'ГБ'];
    var value = raw.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final normalized = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$normalized ${units[unit]}';
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _valueTile({required IconData icon, required String label, required String value}) {
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
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile({required IconData icon, required String title, required String subtitle, required VoidCallback? onTap}) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Хранилище'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Локальные медиа и очередь сообщений',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Экран показывает локальный кэш, очередь outbox и самые тяжёлые чаты на текущем устройстве.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                _valueTile(
                  icon: Icons.schedule_send_outlined,
                  label: 'Черновики outbox',
                  value: '${_stats.outboxDraftCount} • ${_formatBytes(_stats.outboxDraftBytes)}',
                ),
                const SizedBox(height: 10),
                _valueTile(
                  icon: Icons.warning_amber_rounded,
                  label: 'Ошибки загрузки',
                  value: '${_stats.failedUploadsCount}',
                ),
                const SizedBox(height: 10),
                _valueTile(
                  icon: Icons.image_outlined,
                  label: 'Кэш изображений',
                  value: '${_formatBytes(_stats.imageCacheBytes)} • активных ${_stats.liveImageCount}',
                ),
                if (_stats.heaviestChats.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Самые тяжёлые чаты',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  ..._stats.heaviestChats.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _valueTile(
                        icon: Icons.chat_bubble_outline_rounded,
                        label: entry.key,
                        value: '${entry.value} draft',
                      ),
                    ),
                  ),
                ],
                _actionTile(
                  icon: Icons.cleaning_services_outlined,
                  title: 'Очистить кэш изображений',
                  subtitle: 'Сбросить локальный image cache и освободить память.',
                  onTap: _busy ? null : () => _runAction(widget.onClearVisualCache),
                ),
                _actionTile(
                  icon: Icons.delete_sweep_outlined,
                  title: 'Удалить failed uploads',
                  subtitle: 'Очистить безнадёжно сломанные и неотправленные элементы очереди.',
                  onTap: _busy ? null : () => _runAction(chatOutboxService.clearFailed),
                ),
                _actionTile(
                  icon: Icons.layers_clear_outlined,
                  title: 'Очистить весь outbox',
                  subtitle: 'Удалить все локальные черновики и очередь медиа на этом устройстве.',
                  onTap: _busy ? null : () => _runAction(chatOutboxService.clearAll),
                ),
                _actionTile(
                  icon: Icons.phonelink_erase_outlined,
                  title: 'Очистить сохранённые входы',
                  subtitle: 'Удалить локально сохранённые группы и входы с устройства.',
                  onTap: _busy ? null : () => _runAction(widget.onClearSavedSessions),
                ),
              ],
            ),
    );
  }
}

class _ChatStorageStats {
  const _ChatStorageStats({
    this.outboxDraftCount = 0,
    this.outboxDraftBytes = 0,
    this.failedUploadsCount = 0,
    this.imageCacheBytes = 0,
    this.liveImageCount = 0,
    this.heaviestChats = const [],
  });

  final int outboxDraftCount;
  final int outboxDraftBytes;
  final int failedUploadsCount;
  final int imageCacheBytes;
  final int liveImageCount;
  final List<MapEntry<String, int>> heaviestChats;
}
