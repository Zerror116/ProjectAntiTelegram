import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/notification_open_tracker_service.dart';
import '../services/web_notification_service.dart';
import '../src/utils/media_url.dart';
import '../src/utils/notification_navigation.dart';
import '../utils/date_time_utils.dart';
import 'notification_preferences_screen.dart';
import 'pwa_guide_screen.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  static const Map<String, String> _categoryLabels = <String, String>{
    '': 'Все',
    'chat': 'Чаты',
    'support': 'Поддержка',
    'reserved': 'Забронированный товар',
    'delivery': 'Доставка',
    'promo': 'Акции',
    'updates': 'Обновления',
    'security': 'Безопасность',
  };

  StreamSubscription<Map<String, dynamic>>? _notificationsSub;
  Timer? _refreshDebounce;
  bool _loading = true;
  bool _loadingExtras = false;
  bool _markAllBusy = false;
  String _message = '';
  bool _unreadOnly = false;
  String _category = '';
  List<Map<String, dynamic>> _items = const [];
  Map<String, dynamic> _creatorAnalyticsSummary = const <String, dynamic>{};
  List<Map<String, dynamic>> _creatorAnalyticsCampaigns = const [];
  String? _previousShellSection;

  bool get _isCreatorBase {
    return authService.effectiveRole.toLowerCase().trim() == 'creator';
  }

  bool get _showIosPwaOnboarding {
    return kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !WebNotificationService.isStandaloneDisplayMode;
  }

  @override
  void initState() {
    super.initState();
    _previousShellSection = activeShellSectionNotifier.value;
    activeShellSectionNotifier.value = 'notifications';
    if (!_isCreatorBase) {
      _loading = false;
      _message = 'Центр уведомлений доступен только создателю.';
      return;
    }
    _loadAll();
    _notificationsSub = notificationEventsController.stream.listen((event) {
      final type = (event['type'] ?? '').toString().trim().toLowerCase();
      if (!mounted) return;
      if (!type.startsWith('notification:')) return;
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(const Duration(milliseconds: 350), () {
        unawaited(_loadAll(showLoader: false));
      });
    });
  }

  @override
  void dispose() {
    if (activeShellSectionNotifier.value == 'notifications') {
      final fallback = (_previousShellSection ?? '').trim();
      activeShellSectionNotifier.value = fallback.isEmpty
          ? 'settings'
          : fallback;
    }
    _refreshDebounce?.cancel();
    _notificationsSub?.cancel();
    super.dispose();
  }

  String _extractDioMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        return (data['error'] ?? data['message'] ?? 'Ошибка сервера')
            .toString();
      }
      return error.message ?? 'Ошибка сервера';
    }
    return error.toString();
  }

  Map<String, dynamic> _mapOf(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  Future<void> _loadAll({bool showLoader = true}) async {
    if (!_isCreatorBase) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = 'Центр уведомлений доступен только создателю.';
        });
      } else {
        _loading = false;
      }
      return;
    }
    if (showLoader && mounted) {
      setState(() {
        _loading = true;
        _message = '';
      });
    }
    try {
      await _loadInbox();
      await _loadExtras();
      await refreshNotificationBadgeCount();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = _extractDioMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      } else {
        _loading = false;
      }
    }
  }

  Future<void> _loadInbox() async {
    final response = await authService.dio.get(
      '/api/notifications/inbox',
      queryParameters: <String, dynamic>{
        if (_unreadOnly) 'status': 'unread',
        if (_category.isNotEmpty) 'category': _category,
        'limit': 100,
      },
    );
    final root = response.data;
    final rows = root is Map && root['ok'] == true && root['data'] is List
        ? (root['data'] as List)
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    if (!mounted) return;
    setState(() {
      _items = rows;
    });
  }

  Future<void> _loadExtras() async {
    if (!_isCreatorBase) return;
    if (mounted) {
      setState(() {
        _loadingExtras = true;
      });
    }
    try {
      if (_isCreatorBase) {
        final response = await authService.dio.get(
          '/api/creator/notifications/analytics',
        );
        final root = response.data;
        final data = root is Map && root['ok'] == true && root['data'] is Map
            ? Map<String, dynamic>.from(root['data'])
            : const <String, dynamic>{};
        if (mounted) {
          setState(() {
            _creatorAnalyticsSummary = data['summary'] is Map
                ? Map<String, dynamic>.from(data['summary'])
                : const <String, dynamic>{};
            _creatorAnalyticsCampaigns = data['campaigns'] is List
                ? (data['campaigns'] as List)
                      .whereType<Map>()
                      .map((row) => Map<String, dynamic>.from(row))
                      .toList(growable: false)
                : const <Map<String, dynamic>>[];
          });
        }
      }
    } catch (_) {
      // Non-blocking for inbox.
    } finally {
      if (mounted) {
        setState(() {
          _loadingExtras = false;
        });
      } else {
        _loadingExtras = false;
      }
    }
  }

  Future<void> _openPreferences() async {
    if (!_isCreatorBase) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const NotificationPreferencesScreen(),
      ),
    );
    await _loadAll(showLoader: false);
  }

  Future<void> _markAllAsRead() async {
    setState(() {
      _markAllBusy = true;
    });
    try {
      await authService.dio.post('/api/notifications/inbox/read-all');
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((item) => <String, dynamic>{...item, 'status': 'read'})
            .toList(growable: false);
      });
      await refreshNotificationBadgeCount();
      showGlobalAppNotice(
        'Все уведомления отмечены как прочитанные',
        title: 'Уведомления',
        tone: AppNoticeTone.success,
      );
    } catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        _extractDioMessage(error),
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _markAllBusy = false;
        });
      } else {
        _markAllBusy = false;
      }
    }
  }

  Future<void> _openInboxItem(Map<String, dynamic> item) async {
    final itemId = (item['id'] ?? '').toString().trim();
    final status = (item['status'] ?? 'unread').toString().trim().toLowerCase();
    if (status == 'unread') {
      await NotificationOpenTrackerService.reportOpened(
        authService.dio,
        itemId,
      );
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((entry) {
              if ((entry['id'] ?? '').toString().trim() != itemId) {
                return entry;
              }
              return <String, dynamic>{...entry, 'status': 'read'};
            })
            .toList(growable: false);
      });
      await refreshNotificationBadgeCount();
    }
    if (!mounted) return;
    final payload = _mapOf(item['payload']);
    final deepLink = (item['deep_link'] ?? '').toString().trim();
    final opened = await openNotificationDeepLink(
      context,
      deepLink,
      payload: payload,
    );
    if (!opened && mounted) {
      showAppNotice(
        context,
        'Уведомление отмечено как прочитанное. Для него пока нет отдельного экрана перехода.',
        tone: AppNoticeTone.info,
      );
    }
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case 'chat':
        return Icons.chat_bubble_outline_rounded;
      case 'support':
        return Icons.support_agent_rounded;
      case 'reserved':
        return Icons.inventory_2_outlined;
      case 'delivery':
        return Icons.local_shipping_outlined;
      case 'promo':
        return Icons.local_offer_outlined;
      case 'updates':
        return Icons.system_update_alt_rounded;
      case 'security':
        return Icons.shield_outlined;
      default:
        return Icons.notifications_outlined;
    }
  }

  Color _categoryColor(BuildContext context, String category) {
    final scheme = Theme.of(context).colorScheme;
    switch (category) {
      case 'support':
      case 'reserved':
        return scheme.tertiaryContainer;
      case 'promo':
      case 'updates':
        return scheme.secondaryContainer;
      case 'security':
        return scheme.errorContainer;
      default:
        return scheme.primaryContainer;
    }
  }

  String? _previewImageUrl(Map<String, dynamic> item) {
    final media = _mapOf(item['media']);
    final raw =
        (media['image_url'] ?? media['url'] ?? media['thumbnail_url'] ?? '')
            .toString()
            .trim();
    if (raw.isEmpty) return null;
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
  }

  Widget _buildInboxCard(Map<String, dynamic> item) {
    final theme = Theme.of(context);
    final category = (item['category'] ?? '').toString().trim().toLowerCase();
    final title = (item['title'] ?? 'Уведомление').toString().trim();
    final body = (item['body'] ?? '').toString().trim();
    final unread =
        (item['status'] ?? 'unread').toString().trim().toLowerCase() ==
        'unread';
    final imageUrl = _previewImageUrl(item);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: unread
              ? theme.colorScheme.primary.withValues(alpha: 0.28)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _openInboxItem(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _categoryColor(context, category),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_categoryIcon(category)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title.isEmpty ? 'Уведомление' : title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread
                                  ? FontWeight.w800
                                  : FontWeight.w700,
                            ),
                          ),
                        ),
                        if (unread)
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Chip(
                          label: Text(_categoryLabels[category] ?? category),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        Text(
                          formatDateTimeValue(item['created_at']),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        body,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    if (imageUrl != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Container(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.image_not_supported_outlined,
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCreatorAnalytics() {
    if (!_isCreatorBase) return const SizedBox.shrink();
    final summary = _creatorAnalyticsSummary;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Аналитика промо создателя',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            if (_loadingExtras)
              const LinearProgressIndicator()
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Chip(
                    label: Text(
                      'Кампаний: ${(summary['campaigns_total'] ?? 0)}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      'Отправлено: ${(summary['campaigns_sent'] ?? 0)}',
                    ),
                  ),
                  Chip(
                    label: Text('Ошибок: ${(summary['campaigns_error'] ?? 0)}'),
                  ),
                  Chip(
                    label: Text(
                      'Получателей: ${(summary['recipients_total'] ?? 0)}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_creatorAnalyticsCampaigns.isEmpty)
                const Text('Пока нет аналитики по промо-кампаниям.')
              else
                ..._creatorAnalyticsCampaigns.take(6).map((campaign) {
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.query_stats_outlined),
                    title: Text((campaign['title'] ?? 'Промо').toString()),
                    subtitle: Text(
                      'Отправлено: ${(campaign['deliveries_sent'] ?? 0)} • Ошибок: ${(campaign['deliveries_failed'] ?? 0)} • Открыто: ${(campaign['deliveries_opened'] ?? 0)}',
                    ),
                    trailing: Text(formatDateTimeValue(campaign['created_at'])),
                  );
                }),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCreatorBase) {
      return Scaffold(
        appBar: AppBar(title: const Text('Центр уведомлений')),
        body: const SafeArea(
          child: Center(
            child: Text('Центр уведомлений доступен только создателю.'),
          ),
        ),
      );
    }
    final unreadCount = _items
        .where(
          (item) =>
              (item['status'] ?? 'unread').toString().trim().toLowerCase() ==
              'unread',
        )
        .length;
    final badgeCount = notificationInboxBadgeCountNotifier.value;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Уведомления'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _openPreferences,
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Настройки уведомлений',
          ),
          IconButton(
            onPressed: _loading ? null : () => _loadAll(showLoader: false),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _loadAll(showLoader: false),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Центр уведомлений',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                ),
                                Chip(
                                  label: Text('Новых: $badgeCount'),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Все уведомления и важные действия складываются сюда, даже если push был выключен, не дошёл или пришёл тихо.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                ChoiceChip(
                                  label: Text(
                                    _unreadOnly
                                        ? 'Только непрочитанные'
                                        : 'Все статусы',
                                  ),
                                  selected: _unreadOnly,
                                  onSelected: (value) {
                                    setState(() {
                                      _unreadOnly = value;
                                    });
                                    unawaited(_loadAll(showLoader: false));
                                  },
                                  visualDensity: VisualDensity.compact,
                                ),
                                ..._categoryLabels.entries.map((entry) {
                                  return ChoiceChip(
                                    label: Text(entry.value),
                                    selected: _category == entry.key,
                                    onSelected: (_) {
                                      setState(() {
                                        _category = entry.key;
                                      });
                                      unawaited(_loadAll(showLoader: false));
                                    },
                                    visualDensity: VisualDensity.compact,
                                  );
                                }),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Непрочитанных в списке: $unreadCount',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                                const Spacer(),
                                TextButton.icon(
                                  onPressed: _markAllBusy
                                      ? null
                                      : _markAllAsRead,
                                  icon: _markAllBusy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.done_all_rounded),
                                  label: const Text('Прочитать всё'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_showIosPwaOnboarding) ...[
                      const SizedBox(height: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: const Icon(
                            Icons.add_to_home_screen_outlined,
                          ),
                          title: const Text('iPhone/iPad: включение web push'),
                          subtitle: const Text(
                            'Сначала добавьте сайт на экран «Домой», потом откройте ярлык и включите системные уведомления.',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PwaGuideScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    if (_message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _message,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    ..._items.map(_buildInboxCard),
                    if (_items.isEmpty)
                      Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Пока здесь пусто. Когда появятся сообщения, промо, обновления или события безопасности, они будут доступны в центре уведомлений и в счётчике.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    _buildCreatorAnalytics(),
                  ],
                ),
              ),
      ),
    );
  }
}
