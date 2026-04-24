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
  bool _analyticsExpanded = false;

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

  String _selectedCategoryLabel() {
    return _categoryLabels[_category] ?? 'Все';
  }

  Widget _buildMetricPill({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({required Widget child}) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildCategoryFilterBar() {
    final entries = _categoryLabels.entries.toList(growable: false);
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ChoiceChip(
            label: Text(entry.value),
            selected: _category == entry.key,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) {
              setState(() {
                _category = entry.key;
              });
              unawaited(_loadAll(showLoader: false));
            },
          );
        },
      ),
    );
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
    final categoryLabel = _categoryLabels[category] ?? 'Уведомление';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: unread
            ? theme.colorScheme.primary.withValues(alpha: 0.04)
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: unread
              ? theme.colorScheme.primary.withValues(alpha: 0.24)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openInboxItem(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _categoryColor(context, category),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_categoryIcon(category)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  categoryLabel,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                formatDateTimeValue(item['created_at']),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (unread)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Новое',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title.isEmpty ? 'Уведомление' : title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: unread
                                      ? FontWeight.w800
                                      : FontWeight.w700,
                                ),
                              ),
                              if (body.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  body,
                                  maxLines: imageUrl == null ? 3 : 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (imageUrl != null) ...[
                          const SizedBox(width: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: SizedBox(
                              width: 88,
                              height: 88,
                              child: Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
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
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(
                          'Открыть',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
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
    final theme = Theme.of(context);
    return _buildSectionCard(
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(22)),
          ),
          collapsedShape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(22)),
          ),
          initiallyExpanded: _analyticsExpanded,
          onExpansionChanged: (value) {
            setState(() {
              _analyticsExpanded = value;
            });
          },
          title: Text(
            'Аналитика промо',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          subtitle: Text(
            'Кампаний: ${summary['campaigns_total'] ?? 0} • Получателей: ${summary['recipients_total'] ?? 0}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            if (_loadingExtras)
              const LinearProgressIndicator()
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildMetricPill(
                    icon: Icons.campaign_outlined,
                    label: 'Кампаний',
                    value: '${summary['campaigns_total'] ?? 0}',
                  ),
                  _buildMetricPill(
                    icon: Icons.send_outlined,
                    label: 'Отправлено',
                    value: '${summary['campaigns_sent'] ?? 0}',
                  ),
                  _buildMetricPill(
                    icon: Icons.error_outline_rounded,
                    label: 'Ошибок',
                    value: '${summary['campaigns_error'] ?? 0}',
                  ),
                  _buildMetricPill(
                    icon: Icons.group_outlined,
                    label: 'Получателей',
                    value: '${summary['recipients_total'] ?? 0}',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_creatorAnalyticsCampaigns.isEmpty)
                Text(
                  'Пока нет аналитики по промо-кампаниям.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                ..._creatorAnalyticsCampaigns.take(5).map((campaign) {
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.query_stats_outlined),
                    title: Text((campaign['title'] ?? 'Промо').toString()),
                    subtitle: Text(
                      'Отправлено: ${(campaign['deliveries_sent'] ?? 0)} • Открыто: ${(campaign['deliveries_opened'] ?? 0)}',
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
        title: const Text('Центр уведомлений'),
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
                    _buildSectionCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    Icons.notifications_active_outlined,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Центр уведомлений',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Здесь остаются все важные уведомления, даже если push не дошёл или был выключен.',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _buildMetricPill(
                                  icon: Icons.mark_email_unread_outlined,
                                  label: 'Новых',
                                  value: '$badgeCount',
                                ),
                                _buildMetricPill(
                                  icon: Icons.filter_alt_outlined,
                                  label: 'Фильтр',
                                  value: _selectedCategoryLabel(),
                                ),
                                _buildMetricPill(
                                  icon: Icons.drafts_outlined,
                                  label: 'В списке',
                                  value: '$unreadCount',
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                FilterChip(
                                  label: const Text('Только непрочитанные'),
                                  selected: _unreadOnly,
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (value) {
                                    setState(() {
                                      _unreadOnly = value;
                                    });
                                    unawaited(_loadAll(showLoader: false));
                                  },
                                ),
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
                            const SizedBox(height: 10),
                            _buildCategoryFilterBar(),
                          ],
                        ),
                      ),
                    ),
                    if (_showIosPwaOnboarding) ...[
                      const SizedBox(height: 10),
                      _buildSectionCard(
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
                      _buildSectionCard(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                Icons.inbox_outlined,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Пока здесь пусто. Когда появятся сообщения или системные уведомления, они будут доступны здесь.',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
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
