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

  final TextEditingController _promoTitleCtrl = TextEditingController();
  final TextEditingController _promoBodyCtrl = TextEditingController();
  final TextEditingController _promoLinkCtrl = TextEditingController();
  final TextEditingController _promoImageCtrl = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _notificationsSub;
  Timer? _refreshDebounce;
  bool _loading = true;
  bool _loadingExtras = false;
  bool _markAllBusy = false;
  bool _promoSending = false;
  String _message = '';
  bool _unreadOnly = false;
  String _category = '';
  List<Map<String, dynamic>> _items = const [];
  Map<String, dynamic> _creatorAnalyticsSummary = const <String, dynamic>{};
  List<Map<String, dynamic>> _creatorAnalyticsCampaigns = const [];

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
    if (!_isCreatorBase) {
      _loading = false;
      _message = 'Раздел событий доступен только создателю.';
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
    _refreshDebounce?.cancel();
    _notificationsSub?.cancel();
    _promoTitleCtrl.dispose();
    _promoBodyCtrl.dispose();
    _promoLinkCtrl.dispose();
    _promoImageCtrl.dispose();
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
          _message = 'Раздел событий доступен только создателю.';
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
      await NotificationOpenTrackerService.reportOpened(authService.dio, itemId);
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

  Future<void> _sendPromotion() async {
    final title = _promoTitleCtrl.text.trim();
    final body = _promoBodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      showAppNotice(
        context,
        'Нужны и заголовок, и текст уведомления',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _promoSending = true;
    });
    try {
      final path = _isCreatorBase
          ? '/api/notifications/promotions/test'
          : '/api/admin/notifications/promotions';
      await authService.dio.post(
        path,
        data: <String, dynamic>{
          'title': title,
          'body': body,
          'deep_link': _promoLinkCtrl.text.trim().isEmpty
              ? '/notifications'
              : _promoLinkCtrl.text.trim(),
          if (_promoImageCtrl.text.trim().isNotEmpty)
            'media': <String, dynamic>{
              'image_url': _promoImageCtrl.text.trim(),
            },
        },
      );
      if (!mounted) return;
      _promoTitleCtrl.clear();
      _promoBodyCtrl.clear();
      _promoLinkCtrl.clear();
      _promoImageCtrl.clear();
      await _loadAll(showLoader: false);
      showGlobalAppNotice(
        _isCreatorBase
            ? 'Тестовое промо отправлено вам в центр событий'
            : 'Промо-кампания поставлена в отправку',
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
          _promoSending = false;
        });
      } else {
        _promoSending = false;
      }
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
    return Card(
      elevation: unread ? 1.5 : 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openInboxItem(item),
        child: Padding(
          padding: const EdgeInsets.all(14),
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
              const SizedBox(width: 12),
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
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Chip(
                          label: Text(_categoryLabels[category] ?? category),
                          visualDensity: VisualDensity.compact,
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
                      const SizedBox(height: 8),
                      Text(body, style: theme.textTheme.bodyMedium),
                    ],
                    if (imageUrl != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
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

  Widget _buildPromoComposer() {
    if (!_isCreatorBase) return const SizedBox.shrink();
    const title = 'Тестовая промо самому себе';
    const subtitle =
        'Создатель может проверить промо только на себе. Реальную рассылку делает администратор.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promoTitleCtrl,
              decoration: const InputDecoration(
                labelText: 'Заголовок',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promoBodyCtrl,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Текст',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promoLinkCtrl,
              decoration: const InputDecoration(
                labelText: 'Deep link',
                hintText: '/notifications или /chat?chatId=...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promoImageCtrl,
              decoration: const InputDecoration(
                labelText: 'URL картинки (необязательно)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _promoSending ? null : _sendPromotion,
              icon: _promoSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _isCreatorBase
                          ? Icons.send_outlined
                          : Icons.campaign_outlined,
                    ),
              label: Text('Отправить тест себе'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreatorAnalytics() {
    if (!_isCreatorBase) return const SizedBox.shrink();
    final summary = _creatorAnalyticsSummary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                runSpacing: 8,
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
        appBar: AppBar(title: const Text('События')),
        body: const SafeArea(
          child: Center(
            child: Text('Раздел событий доступен только создателю.'),
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
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Центр событий',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                ),
                                ValueListenableBuilder<int>(
                                  valueListenable:
                                      notificationBadgeCountNotifier,
                                  builder: (context, badgeCount, _) {
                                    return Chip(
                                      label: Text('Счётчик: $badgeCount'),
                                      visualDensity: VisualDensity.compact,
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Все события складываются сюда, даже если push был выключен, не дошёл или пришёл тихо.',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
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
                                  );
                                }),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Text('Непрочитанных в списке: $unreadCount'),
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
                      Card(
                        child: ListTile(
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
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            _message,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ..._items.map(_buildInboxCard),
                    if (_items.isEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'Пока здесь пусто. Когда появятся сообщения, промо, обновления или события безопасности, они будут доступны в центре событий и в счётчике.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    _buildPromoComposer(),
                    const SizedBox(height: 12),
                    _buildCreatorAnalytics(),
                  ],
                ),
              ),
      ),
    );
  }
}
