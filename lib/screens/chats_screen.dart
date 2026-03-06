import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../utils/date_time_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/phoenix_loader.dart';
import 'chat_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;
  String _error = '';
  StreamSubscription? _chatEventsSub;
  Timer? _refreshDebounceTimer;
  bool _refreshInFlight = false;
  bool _refreshQueued = false;
  bool _loadedOnce = false;

  String _chatIdOf(Map<String, dynamic> chat) => (chat['id'] ?? '').toString();

  int _compareChats(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ad = _parseDate(a['updated_at'] ?? a['time']);
    final bd = _parseDate(b['updated_at'] ?? b['time']);
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad);
  }

  void _sortChats() {
    _chats.sort(_compareChats);
  }

  void _upsertChatLocally(Map<String, dynamic> chat) {
    final chatId = _chatIdOf(chat);
    if (chatId.isEmpty) return;
    final normalized = Map<String, dynamic>.from(chat);
    setState(() {
      final index = _chats.indexWhere((c) => _chatIdOf(c) == chatId);
      if (index >= 0) {
        _chats[index] = {..._chats[index], ...normalized};
      } else {
        _chats.insert(0, normalized);
      }
      _sortChats();
    });
  }

  void _removeChatLocally(String chatId) {
    if (chatId.isEmpty) return;
    setState(() {
      _chats = _chats.where((c) => _chatIdOf(c) != chatId).toList();
    });
  }

  void _applyIncomingMessagePreview(
    String chatId,
    Map<String, dynamic> message,
  ) {
    if (chatId.isEmpty) return;
    final text = (message['text'] ?? '').toString();
    final senderId = (message['sender_id'] ?? '').toString();
    final senderName = (message['sender_name'] ?? '').toString();
    final createdAt =
        (message['created_at'] ?? DateTime.now().toIso8601String()).toString();
    final currentUserId = authService.currentUser?.id.trim() ?? '';
    final fromCurrentUser =
        senderId.isNotEmpty &&
        currentUserId.isNotEmpty &&
        senderId == currentUserId;
    final isActiveChat = activeChatIdNotifier.value == chatId;
    final patch = <String, dynamic>{
      'id': chatId,
      'last_message': text,
      'updated_at': createdAt,
      'last_message_sender_id': senderId,
      'last_message_sender_name': senderName,
      'last_message_sender_avatar_url': message['sender_avatar_url'],
      'last_message_sender_avatar_focus_x': message['sender_avatar_focus_x'],
      'last_message_sender_avatar_focus_y': message['sender_avatar_focus_y'],
      'last_message_sender_avatar_zoom': message['sender_avatar_zoom'],
    };
    setState(() {
      final index = _chats.indexWhere((c) => _chatIdOf(c) == chatId);
      final previousUnread = index >= 0
          ? int.tryParse('${_chats[index]['unread_count'] ?? 0}') ?? 0
          : 0;
      patch['unread_count'] = (!fromCurrentUser && !isActiveChat)
          ? previousUnread + 1
          : 0;
      if (index >= 0) {
        _chats[index] = {..._chats[index], ...patch};
      } else {
        _chats.insert(0, patch);
      }
      _sortChats();
    });
  }

  void _markChatReadLocally(String chatId) {
    if (chatId.isEmpty) return;
    setState(() {
      final index = _chats.indexWhere((c) => _chatIdOf(c) == chatId);
      if (index < 0) return;
      _chats[index] = {..._chats[index], 'unread_count': 0};
    });
  }

  void _scheduleChatsRefresh({Duration delay = const Duration(seconds: 1)}) {
    _refreshDebounceTimer?.cancel();
    _refreshDebounceTimer = Timer(delay, () {
      unawaited(_loadChats());
    });
  }

  Map<String, dynamic> _settingsOf(Map<String, dynamic> chat) {
    final raw = chat['settings'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }

  String? _resolveImageUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    final base = authService.dio.options.baseUrl.trim();
    if (base.isEmpty) return value;
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  double _toAvatarFocus(Object? raw) {
    final value = double.tryParse('${raw ?? ''}');
    if (value == null || !value.isFinite) return 0;
    return value.clamp(-1.0, 1.0);
  }

  double _toAvatarZoom(Object? raw) {
    final value = double.tryParse('${raw ?? ''}');
    if (value == null || !value.isFinite) return 1;
    return value.clamp(1.0, 4.0);
  }

  DateTime? _parseDate(dynamic raw) {
    return parseDateTimeValue(raw);
  }

  String _formatTime(dynamic raw) {
    return formatDateTimeValue(raw);
  }

  String _compactMessage(String text) {
    final normalized = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
    if (normalized.isEmpty) return 'Пока без сообщений';
    return normalized;
  }

  String _lastMessagePreview(Map<String, dynamic> chat) {
    final rawText = (chat['last_message'] ?? chat['last'] ?? '').toString();
    final text = _compactMessage(rawText);
    if (text == 'Пока без сообщений') return text;

    final senderId = (chat['last_message_sender_id'] ?? '').toString().trim();
    final senderName = (chat['last_message_sender_name'] ?? '')
        .toString()
        .trim();
    if (senderId.isEmpty || senderName == 'Система') {
      return text;
    }
    final currentUserId = authService.currentUser?.id ?? '';
    final prefix = senderId.isNotEmpty && senderId == currentUserId
        ? 'Вы'
        : senderName;
    return '$prefix: $text';
  }

  String _extractDioError(Object error) {
    final text = error.toString();
    final marker = 'error:';
    final idx = text.toLowerCase().indexOf(marker);
    if (idx >= 0 && idx + marker.length < text.length) {
      return text.substring(idx + marker.length).trim();
    }
    return text;
  }

  Future<void> _openDirectChatDialog() async {
    final controller = TextEditingController();
    bool submitting = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> submit() async {
              final query = controller.text.trim();
              if (query.isEmpty) return;
              setModalState(() => submitting = true);
              try {
                final resp = await authService.dio.post(
                  '/api/chats/direct/open',
                  data: {'query': query},
                );
                final data = resp.data;
                if (data is! Map ||
                    data['ok'] != true ||
                    data['data'] is! Map) {
                  throw Exception('Неверный ответ сервера');
                }
                final payload = Map<String, dynamic>.from(data['data']);
                final chat = payload['chat'] is Map
                    ? Map<String, dynamic>.from(payload['chat'])
                    : <String, dynamic>{};
                final peer = payload['peer'] is Map
                    ? Map<String, dynamic>.from(payload['peer'])
                    : <String, dynamic>{};
                final chatId = (chat['id'] ?? '').toString();
                if (chatId.isEmpty) {
                  throw Exception('Не удалось открыть чат');
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
                final title = (peer['name'] ?? '').toString().trim().isNotEmpty
                    ? (peer['name'] ?? '').toString().trim()
                    : ((peer['email'] ?? '').toString().trim().isNotEmpty
                          ? (peer['email'] ?? '').toString().trim()
                          : 'Личные сообщения');
                if (!mounted) return;
                _markChatReadLocally(chatId);
                await Navigator.push(
                  this.context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      chatId: chatId,
                      chatTitle: title,
                      chatType: 'private',
                      chatSettings: chat['settings'] is Map
                          ? Map<String, dynamic>.from(chat['settings'])
                          : null,
                    ),
                  ),
                );
                _scheduleChatsRefresh(delay: const Duration(milliseconds: 150));
              } catch (e) {
                if (!mounted) return;
                showGlobalAppNotice(
                  'Ошибка ЛС: ${_extractDioError(e)}',
                  tone: AppNoticeTone.error,
                );
              } finally {
                if (ctx.mounted) {
                  setModalState(() => submitting = false);
                }
              }
            }

            return AlertDialog(
              title: const Text('Найти пользователя'),
              content: SizedBox(
                width: 420,
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Телефон, email или имя',
                    hintText: 'Например: 7999..., user@mail.com',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting ? null : () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                FilledButton.icon(
                  onPressed: submitting ? null : submit,
                  icon: submitting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.forum_outlined),
                  label: const Text('Открыть ЛС'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadChats(showLoader: true);
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type'] as String? ?? '';
      final data = event['data'];

      if (type == 'chat:created') {
        if (data is Map && data['chat'] is Map) {
          _upsertChatLocally(Map<String, dynamic>.from(data['chat']));
        }
        _scheduleChatsRefresh();
        return;
      }

      if (type == 'chat:updated') {
        if (data is Map && data['chat'] is Map) {
          _upsertChatLocally(Map<String, dynamic>.from(data['chat']));
        }
        _scheduleChatsRefresh();
        return;
      }

      if (type == 'chat:pinned') {
        _scheduleChatsRefresh();
        return;
      }

      if (type == 'chat:deleted') {
        if (data is Map) {
          _removeChatLocally((data['chatId'] ?? '').toString());
        }
        return;
      }

      if (type == 'chat:message' || type == 'chat:message:global') {
        if (data is Map) {
          final msg = data['message'];
          final chatId = (data['chatId'] ?? msg?['chat_id'] ?? msg?['chatId'])
              ?.toString();
          if (chatId != null && msg is Map) {
            _applyIncomingMessagePreview(
              chatId,
              Map<String, dynamic>.from(msg),
            );
          }
        }
        _scheduleChatsRefresh();
      }

      if (type == 'chat:message:deleted') {
        _scheduleChatsRefresh();
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    _refreshDebounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadChats({bool showLoader = false}) async {
    if (_refreshInFlight) {
      _refreshQueued = true;
      return;
    }

    _refreshInFlight = true;
    final shouldShowLoader = showLoader && !_loadedOnce && _chats.isEmpty;

    if (shouldShowLoader && mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    } else if (mounted && _error.isNotEmpty) {
      setState(() => _error = '');
    }

    try {
      final resp = await authService.dio.get('/api/chats');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final nextChats = List<Map<String, dynamic>>.from(data['data'])
          ..sort(_compareChats);
        if (!mounted) return;
        setState(() {
          _chats = nextChats;
          _loadedOnce = true;
        });
      } else {
        if (!mounted) return;
        if (_chats.isEmpty) {
          setState(() => _error = 'Неверный ответ сервера');
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (_chats.isEmpty) {
        setState(() => _error = 'Ошибка загрузки чатов: $e');
      }
    } finally {
      _refreshInFlight = false;
      if (mounted && shouldShowLoader) {
        setState(() => _loading = false);
      } else {
        _loading = false;
      }
      if (_refreshQueued) {
        _refreshQueued = false;
        _scheduleChatsRefresh(delay: const Duration(milliseconds: 250));
      }
    }
  }

  Widget _buildItem(Map<String, dynamic> chat) {
    final theme = Theme.of(context);
    final title = (chat['title'] ?? chat['name'] ?? 'Чат').toString();
    final time = _formatTime(chat['updated_at'] ?? chat['time']);
    final settings = _settingsOf(chat);
    final avatarUrl = _resolveImageUrl(
      (settings['avatar_url'] ?? '').toString(),
    );
    final avatarFocusX = _toAvatarFocus(settings['avatar_focus_x']);
    final avatarFocusY = _toAvatarFocus(settings['avatar_focus_y']);
    final avatarZoom = _toAvatarZoom(settings['avatar_zoom']);
    final preview = _lastMessagePreview(chat);
    final unreadCount = int.tryParse('${chat['unread_count'] ?? 0}') ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            final chatId = chat['id']?.toString() ?? '';
            _markChatReadLocally(chatId);
            final chatType = (chat['type'] ?? '').toString();
            final chatSettings = chat['settings'] is Map
                ? Map<String, dynamic>.from(chat['settings'])
                : null;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  chatId: chatId,
                  chatTitle: title,
                  chatType: chatType,
                  chatSettings: chatSettings,
                ),
              ),
            ).then((_) {
              _scheduleChatsRefresh(delay: const Duration(milliseconds: 150));
            });
          },
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                AppAvatar(
                  title: title,
                  imageUrl: avatarUrl,
                  focusX: avatarFocusX,
                  focusY: avatarFocusY,
                  zoom: avatarZoom,
                  radius: 26,
                  fallbackIcon: Icons.forum_outlined,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (time.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Text(
                              time,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (unreadCount > 0) ...[
                            const SizedBox(width: 10),
                            Container(
                              constraints: const BoxConstraints(
                                minWidth: 22,
                                minHeight: 22,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                unreadCount > 99 ? '99+' : '$unreadCount',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.25,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          IconButton(
            tooltip: 'Личные сообщения',
            onPressed: _openDirectChatDialog,
            icon: const Icon(Icons.person_add_alt_1_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadChats,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.surfaceContainerLowest,
                  theme.colorScheme.surface,
                ],
              ),
            ),
            child: _loading
                ? const PhoenixLoadingView(
                    title: 'Загружаем чаты',
                    subtitle: 'Получаем каналы и личные переписки',
                    size: 52,
                  )
                : _error.isNotEmpty
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _error,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ElevatedButton(
                          onPressed: _loadChats,
                          child: const Text('Повторить'),
                        ),
                      ),
                    ],
                  )
                : _chats.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      const SizedBox(height: 80),
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 52,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          'Пока нет доступных чатов',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: _chats.length,
                    itemBuilder: (context, i) => _buildItem(_chats[i]),
                  ),
          ),
        ),
      ),
    );
  }
}
