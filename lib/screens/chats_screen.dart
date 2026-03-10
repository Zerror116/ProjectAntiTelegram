import 'dart:async';

import 'package:dio/dio.dart';
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

  bool _toBool(dynamic raw) {
    if (raw is bool) return raw;
    final value = '${raw ?? ''}'.toLowerCase().trim();
    return value == 'true' || value == '1' || value == 'yes';
  }

  bool _isChatPinned(Map<String, dynamic> chat) {
    return _toBool(chat['is_pinned']);
  }

  DateTime? _chatPinnedAt(Map<String, dynamic> chat) {
    return _parseDate(chat['pinned_at']);
  }

  int _compareChats(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ap = _isChatPinned(a);
    final bp = _isChatPinned(b);
    if (ap != bp) return ap ? -1 : 1;
    if (ap && bp) {
      final apAt = _chatPinnedAt(a);
      final bpAt = _chatPinnedAt(b);
      if (apAt != null && bpAt != null) {
        final cmp = bpAt.compareTo(apAt);
        if (cmp != 0) return cmp;
      } else if (apAt != null) {
        return -1;
      } else if (bpAt != null) {
        return 1;
      }
    }
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

  String _chatDisplayTitle(Map<String, dynamic> chat) {
    final serverDisplay = (chat['display_title'] ?? '').toString().trim();
    if (serverDisplay.isNotEmpty) return serverDisplay;

    final peerDisplay = (chat['peer_display_name'] ?? '').toString().trim();
    if (peerDisplay.isNotEmpty) return peerDisplay;

    final peerName = (chat['peer_name'] ?? '').toString().trim();
    if (peerName.isNotEmpty) return peerName;

    final peerEmail = (chat['peer_email'] ?? '').toString().trim();
    if (peerEmail.isNotEmpty) return peerEmail;

    final peerPhone = (chat['peer_phone'] ?? '').toString().trim();
    if (peerPhone.isNotEmpty) return peerPhone;

    final title = (chat['title'] ?? chat['name'] ?? '').toString().trim();
    if (title.isNotEmpty && title != 'Личные сообщения') return title;
    return 'Пользователь';
  }

  bool _isMainChannel(Map<String, dynamic> chat) {
    final settings = _settingsOf(chat);
    final systemKey = (settings['system_key'] ?? '').toString().trim();
    final kind = (settings['kind'] ?? '').toString().trim();
    final title = (chat['title'] ?? '').toString().trim().toLowerCase();
    return systemKey == 'main_channel' ||
        kind == 'main_channel' ||
        title == 'основной канал';
  }

  Future<void> _updateChatListPreferences(
    Map<String, dynamic> chat, {
    bool? hidden,
    bool? pinned,
  }) async {
    final chatId = _chatIdOf(chat);
    if (chatId.isEmpty) return;
    if (hidden == true && _isMainChannel(chat)) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Основной канал нельзя удалить из списка',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    try {
      final resp = await authService.dio.patch(
        '/api/chats/$chatId/list-preferences',
        data: {
          if (hidden != null) 'hidden': hidden,
          if (pinned != null) 'pinned': pinned,
        },
      );
      final data = resp.data is Map && resp.data['data'] is Map
          ? Map<String, dynamic>.from(resp.data['data'])
          : <String, dynamic>{};
      final isHidden = _toBool(data['hidden']);
      final isPinned = _toBool(data['pinned']);
      if (!mounted) return;
      setState(() {
        final index = _chats.indexWhere((row) => _chatIdOf(row) == chatId);
        if (index < 0) return;
        if (isHidden) {
          _chats.removeAt(index);
        } else {
          _chats[index] = {
            ..._chats[index],
            'is_pinned': isPinned,
            'pinned_at': data['pinned_at'],
          };
        }
        _sortChats();
      });
      showGlobalAppNotice(
        hidden == true
            ? 'Чат удалён у вас из списка'
            : (isPinned ? 'Чат закреплён' : 'Чат откреплён'),
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Ошибка действия с чатом: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _openChatActionsMenu(
    Map<String, dynamic> chat, {
    Offset? globalPosition,
  }) async {
    final isPinned = _isChatPinned(chat);
    final canHide = !_isMainChannel(chat);
    String? action;

    if (globalPosition != null) {
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (overlay != null) {
        action = await showMenu<String>(
          context: context,
          position: RelativeRect.fromRect(
            Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
            Offset.zero & overlay.size,
          ),
          items: [
            PopupMenuItem<String>(
              value: isPinned ? 'unpin' : 'pin',
              child: Text(isPinned ? 'Открепить у себя' : 'Закрепить у себя'),
            ),
            if (canHide)
              const PopupMenuItem<String>(
                value: 'hide',
                child: Text('Удалить у себя'),
              ),
          ],
        );
      }
    } else {
      action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(
                  isPinned ? 'Открепить у себя' : 'Закрепить у себя',
                ),
                onTap: () => Navigator.of(ctx).pop(isPinned ? 'unpin' : 'pin'),
              ),
              if (canHide)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Удалить у себя'),
                  onTap: () => Navigator.of(ctx).pop('hide'),
                ),
            ],
          ),
        ),
      );
    }

    if (action == null) return;
    if (action == 'hide') {
      await _updateChatListPreferences(chat, hidden: true);
      return;
    }
    if (action == 'pin') {
      await _updateChatListPreferences(chat, pinned: true);
      return;
    }
    if (action == 'unpin') {
      await _updateChatListPreferences(chat, pinned: false);
    }
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
    if (error is DioException) {
      final responseData = error.response?.data;
      if (responseData is Map) {
        final apiError = (responseData['error'] ?? '').toString().trim();
        if (apiError.isNotEmpty) return apiError;
      }
      final message = error.message?.trim() ?? '';
      if (message.isNotEmpty) return message;
      return 'Ошибка сети';
    }
    final text = error.toString();
    final marker = 'error:';
    final idx = text.toLowerCase().indexOf(marker);
    if (idx >= 0 && idx + marker.length < text.length) {
      return text.substring(idx + marker.length).trim();
    }
    return text;
  }

  String _peerDisplayName(Map<String, dynamic> peer) {
    final alias = (peer['alias_name'] ?? '').toString().trim();
    if (alias.isNotEmpty) return alias;
    final name = (peer['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final email = (peer['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;
    final phone = (peer['phone'] ?? '').toString().trim();
    if (phone.isNotEmpty) return phone;
    return 'Пользователь';
  }

  String _peerSubtitle(Map<String, dynamic> peer) {
    final phone = (peer['phone'] ?? '').toString().trim();
    final email = (peer['email'] ?? '').toString().trim();
    if (phone.isNotEmpty && email.isNotEmpty) return '$phone • $email';
    if (phone.isNotEmpty) return phone;
    if (email.isNotEmpty) return email;
    return '';
  }

  Future<void> _openDirectChatDialog() async {
    final result = await showDialog<_DirectChatOpenResult>(
      context: context,
      builder: (_) => _DirectChatDialog(
        extractDioError: _extractDioError,
        peerDisplayName: _peerDisplayName,
        peerSubtitle: _peerSubtitle,
        resolveImageUrl: _resolveImageUrl,
        toAvatarFocus: _toAvatarFocus,
        toAvatarZoom: _toAvatarZoom,
      ),
    );
    if (!mounted || result == null) return;

    _markChatReadLocally(result.chatId);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: result.chatId,
          chatTitle: result.chatTitle,
          chatType: 'private',
          chatSettings: result.chatSettings,
        ),
      ),
    );
    if (!mounted) return;
    _scheduleChatsRefresh(delay: const Duration(milliseconds: 150));
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

class _DirectChatOpenResult {
  final String chatId;
  final String chatTitle;
  final Map<String, dynamic>? chatSettings;

  const _DirectChatOpenResult({
    required this.chatId,
    required this.chatTitle,
    required this.chatSettings,
  });
}

class _DirectChatDialog extends StatefulWidget {
  final String Function(Object error) extractDioError;
  final String Function(Map<String, dynamic> peer) peerDisplayName;
  final String Function(Map<String, dynamic> peer) peerSubtitle;
  final String? Function(String? raw) resolveImageUrl;
  final double Function(Object? raw) toAvatarFocus;
  final double Function(Object? raw) toAvatarZoom;

  const _DirectChatDialog({
    required this.extractDioError,
    required this.peerDisplayName,
    required this.peerSubtitle,
    required this.resolveImageUrl,
    required this.toAvatarFocus,
    required this.toAvatarZoom,
  });

  @override
  State<_DirectChatDialog> createState() => _DirectChatDialogState();
}

class _DirectChatDialogState extends State<_DirectChatDialog> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _contacts = [];

  bool _submitting = false;
  bool _loadingContacts = true;
  String _contactsError = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadContacts(force: true));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadContacts({bool force = false}) async {
    if (_loadingContacts && !force) return;
    setState(() {
      _loadingContacts = true;
      _contactsError = '';
    });

    try {
      final resp = await authService.dio.get('/api/chats/contacts');
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! List) {
        throw Exception('Неверный ответ сервера');
      }
      if (!mounted) return;
      setState(() {
        _contacts
          ..clear()
          ..addAll(List<Map<String, dynamic>>.from(data['data']));
        _loadingContacts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
        _contactsError = widget.extractDioError(e);
      });
    }
  }

  Future<void> _openDirect({String? query, String? userId}) async {
    final normalizedQuery = (query ?? '').trim();
    final normalizedUserId = (userId ?? '').trim();
    if (_submitting) return;
    if (normalizedQuery.isEmpty && normalizedUserId.isEmpty) return;

    setState(() => _submitting = true);
    var didCloseDialog = false;
    try {
      final resp = await authService.dio.post(
        '/api/chats/direct/open',
        data: {
          if (normalizedQuery.isNotEmpty) 'query': normalizedQuery,
          if (normalizedUserId.isNotEmpty) 'user_id': normalizedUserId,
        },
        options: Options(
          validateStatus: (code) {
            if (code == null) return false;
            return code < 500;
          },
        ),
      );

      if (resp.statusCode == 404) {
        showGlobalAppNotice(
          'Пользователь не найден в вашей группе',
          tone: AppNoticeTone.warning,
        );
        return;
      }
      if (resp.statusCode == null ||
          resp.statusCode! < 200 ||
          resp.statusCode! >= 300) {
        throw Exception(
          widget.extractDioError(
            DioException(
              requestOptions: resp.requestOptions,
              response: resp,
              type: DioExceptionType.badResponse,
            ),
          ),
        );
      }

      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) {
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
      final chatTitle = (peer['name'] ?? '').toString().trim().isNotEmpty
          ? (peer['name'] ?? '').toString().trim()
          : ((peer['email'] ?? '').toString().trim().isNotEmpty
                ? (peer['email'] ?? '').toString().trim()
                : 'Личные сообщения');
      final chatSettings = chat['settings'] is Map
          ? Map<String, dynamic>.from(chat['settings'])
          : null;

      if (!mounted) return;
      didCloseDialog = true;
      Navigator.of(context).pop(
        _DirectChatOpenResult(
          chatId: chatId,
          chatTitle: chatTitle,
          chatSettings: chatSettings,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Ошибка ЛС: ${widget.extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (!didCloseDialog && mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _addToContactsByQuery() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final resp = await authService.dio.post(
        '/api/chats/contacts',
        data: {'query': query},
        options: Options(
          validateStatus: (code) {
            if (code == null) return false;
            return code < 500;
          },
        ),
      );
      if (resp.statusCode == 404) {
        showGlobalAppNotice(
          'Контакт не найден в вашей группе',
          tone: AppNoticeTone.warning,
        );
        return;
      }
      if (resp.statusCode == null ||
          resp.statusCode! < 200 ||
          resp.statusCode! >= 300) {
        throw Exception(
          widget.extractDioError(
            DioException(
              requestOptions: resp.requestOptions,
              response: resp,
              type: DioExceptionType.badResponse,
            ),
          ),
        );
      }
      showGlobalAppNotice('Контакт добавлен', tone: AppNoticeTone.success);
      await _loadContacts(force: true);
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Ошибка добавления контакта: ${widget.extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _removeContact(String userId) async {
    if (userId.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final resp = await authService.dio.delete(
        '/api/chats/contacts/$userId',
        options: Options(
          validateStatus: (code) {
            if (code == null) return false;
            return code < 500;
          },
        ),
      );
      if (resp.statusCode == null ||
          resp.statusCode! < 200 ||
          resp.statusCode! >= 300) {
        throw Exception(
          widget.extractDioError(
            DioException(
              requestOptions: resp.requestOptions,
              response: resp,
              type: DioExceptionType.badResponse,
            ),
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _contacts.removeWhere(
          (item) => (item['contact_user_id'] ?? '').toString() == userId,
        );
      });
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Ошибка удаления контакта: ${widget.extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dialogHeight = (MediaQuery.of(context).size.height * 0.72).clamp(
      320.0,
      540.0,
    );

    return AlertDialog(
      title: const Text('Найти пользователя'),
      content: SizedBox(
        width: 500,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Телефон, email или имя',
                hintText: 'Например: 7999..., user@mail.com',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _openDirect(query: _controller.text),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _submitting
                      ? null
                      : () => _openDirect(query: _controller.text),
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Открыть ЛС'),
                ),
                OutlinedButton.icon(
                  onPressed: _submitting ? null : _addToContactsByQuery,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Добавить в контакты'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text('Контакты', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: _submitting
                      ? null
                      : () => _loadContacts(force: true),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Expanded(
              child: _loadingContacts
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _contactsError.isNotEmpty
                  ? Center(
                      child: Text(
                        'Не удалось загрузить контакты: $_contactsError',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : _contacts.isEmpty
                  ? const Center(child: Text('Контактов пока нет'))
                  : ListView.separated(
                      itemCount: _contacts.length,
                      separatorBuilder: (_, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final contact = _contacts[index];
                        final contactUserId = (contact['contact_user_id'] ?? '')
                            .toString()
                            .trim();
                        final title = widget.peerDisplayName(contact);
                        final subtitle = widget.peerSubtitle(contact);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: AppAvatar(
                            title: title,
                            imageUrl: widget.resolveImageUrl(
                              (contact['avatar_url'] ?? '').toString().trim(),
                            ),
                            focusX: widget.toAvatarFocus(
                              contact['avatar_focus_x'],
                            ),
                            focusY: widget.toAvatarFocus(
                              contact['avatar_focus_y'],
                            ),
                            zoom: widget.toAvatarZoom(contact['avatar_zoom']),
                            radius: 18,
                          ),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: subtitle.isEmpty
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: _submitting || contactUserId.isEmpty
                              ? null
                              : () => _openDirect(userId: contactUserId),
                          trailing: IconButton(
                            tooltip: 'Удалить контакт',
                            onPressed: _submitting || contactUserId.isEmpty
                                ? null
                                : () => _removeContact(contactUserId),
                            icon: const Icon(
                              Icons.person_remove_alt_1_outlined,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
