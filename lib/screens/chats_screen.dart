import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../src/utils/chat_api.dart';
import '../src/utils/messenger_ui_helpers.dart';
import '../src/utils/media_url.dart';
import '../utils/date_time_utils.dart';
import '../widgets/app_avatar.dart';
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
  bool _rulesPromptInProgress = false;

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
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
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

  String _chatDisplayTitle(Map<String, dynamic> chat) {
    final serverDisplay = (chat['display_title'] ?? '').toString().trim();
    if (serverDisplay.isNotEmpty) return serverDisplay;

    final peerDisplay = (chat['peer_display_name'] ?? '').toString().trim();
    if (peerDisplay.isNotEmpty) return peerDisplay;

    final peerName = (chat['peer_name'] ?? '').toString().trim();
    if (peerName.isNotEmpty) return peerName;

    final peerPhone = (chat['peer_phone'] ?? '').toString().trim();
    if (peerPhone.isNotEmpty) return peerPhone;

    final title = (chat['title'] ?? chat['name'] ?? '').toString().trim();
    if (title.isNotEmpty && title != 'Личные сообщения') return title;
    return 'Пользователь';
  }

  bool _isMainTitle(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return false;
    return value == 'основной канал' || value.startsWith('основной канал ');
  }

  bool _isMainChannel(Map<String, dynamic> chat) {
    final settings = _settingsOf(chat);
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

  Future<Map<String, dynamic>?> _resolveMainChannelFallback() async {
    try {
      final rows = await loadChatsCollection();
      final main = rows.firstWhere(
        _isMainChannel,
        orElse: () => const <String, dynamic>{},
      );
      final id = (main['id'] ?? '').toString().trim();
      if (id.isEmpty) return null;
      return main;
    } catch (_) {
      return null;
    }
  }

  String _chatLoadErrorText(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401) {
        return 'Сессия сейчас обновляется. Попробуйте открыть чаты ещё раз через пару секунд.';
      }
      if (status == 404) {
        return 'Список чатов временно недоступен. Попробуйте обновить страницу.';
      }
      if (status == 502 || status == 503 || status == 504) {
        return 'Сервер чатов сейчас перегружен. Попробуйте ещё раз чуть позже.';
      }
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'Не удалось подключиться к чатам. Проверьте интернет и попробуйте снова.';
      }
    }
    return 'Не удалось загрузить чаты. Попробуйте ещё раз.';
  }

  Future<void> _openChat(Map<String, dynamic> chat) async {
    var selectedChat = Map<String, dynamic>.from(chat);
    final isMain = _isMainChannel(selectedChat);
    if (isMain) {
      final resolved = await _resolveMainChannelFallback();
      if (resolved != null) {
        selectedChat = {...selectedChat, ...resolved};
      }
    }

    var chatId = _chatIdOf(selectedChat).trim();
    if (chatId.isEmpty) {
      // Retry once after background refresh to handle stale local list state.
      await _loadChats(showLoader: false);
      if (!mounted) return;
      Map<String, dynamic>? recovered;
      if (isMain) {
        recovered = await _resolveMainChannelFallback();
      } else {
        final wantedTitle = _chatDisplayTitle(
          selectedChat,
        ).trim().toLowerCase();
        if (wantedTitle.isNotEmpty) {
          for (final row in _chats) {
            final rowId = _chatIdOf(row).trim();
            if (rowId.isEmpty) continue;
            final rowTitle = _chatDisplayTitle(row).trim().toLowerCase();
            if (rowTitle == wantedTitle) {
              recovered = Map<String, dynamic>.from(row);
              break;
            }
          }
        }
      }
      if (recovered != null) {
        selectedChat = {...selectedChat, ...recovered};
        chatId = _chatIdOf(selectedChat).trim();
      }
    }
    if (chatId.isEmpty) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Не удалось открыть чат: отсутствует ID канала. Обновите список чатов.',
        tone: AppNoticeTone.error,
      );
      return;
    }

    final title = _chatDisplayTitle(selectedChat);
    final chatType = (selectedChat['type'] ?? '').toString();
    final chatSettings = selectedChat['settings'] is Map
        ? Map<String, dynamic>.from(selectedChat['settings'])
        : null;

    try {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: title,
            chatType: chatType,
            chatSettings: chatSettings,
          ),
        ),
      );
      if (!mounted) return;
      _scheduleChatsRefresh(delay: const Duration(milliseconds: 150));
    } catch (e) {
      if (!mounted) return;
      showGlobalAppNotice(
        'Ошибка открытия чата: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
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
          if (hidden case final value) 'hidden': value,
          if (pinned case final value) 'pinned': value,
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
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
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
                title: Text(isPinned ? 'Открепить у себя' : 'Закрепить у себя'),
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
    return messengerBuildLastMessagePreview(
      rawText: (chat['last_message'] ?? chat['last'] ?? '').toString(),
      senderId: (chat['last_message_sender_id'] ?? '').toString(),
      senderName: (chat['last_message_sender_name'] ?? '').toString(),
      currentUserId: authService.currentUser?.id ?? '',
    );
  }

  bool _isSupportChat(Map<String, dynamic> chat) {
    final settings = _settingsOf(chat);
    final kind = (settings['kind'] ?? '').toString().trim().toLowerCase();
    return kind == 'support_ticket' || _toBool(settings['support_ticket']);
  }

  ({
    Color background,
    Color foreground,
    Color border,
  }) _supportToneColors(
    ThemeData theme,
    MessengerSupportStatusTone tone,
  ) {
    return switch (tone) {
      MessengerSupportStatusTone.primary => (
        background: theme.colorScheme.primaryContainer,
        foreground: theme.colorScheme.onPrimaryContainer,
        border: theme.colorScheme.primary.withValues(alpha: 0.28),
      ),
      MessengerSupportStatusTone.secondary => (
        background: theme.colorScheme.secondaryContainer,
        foreground: theme.colorScheme.onSecondaryContainer,
        border: theme.colorScheme.secondary.withValues(alpha: 0.28),
      ),
      MessengerSupportStatusTone.success => (
        background: theme.colorScheme.tertiaryContainer,
        foreground: theme.colorScheme.onTertiaryContainer,
        border: theme.colorScheme.tertiary.withValues(alpha: 0.28),
      ),
      MessengerSupportStatusTone.neutral => (
        background: theme.colorScheme.surfaceContainerHigh,
        foreground: theme.colorScheme.onSurfaceVariant,
        border: theme.colorScheme.outlineVariant,
      ),
    };
  }

  Widget _buildMetaChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
    required Color border,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildChatMetaChips(Map<String, dynamic> chat, ThemeData theme) {
    final chips = <Widget>[];
    if (_isChatPinned(chat)) {
      chips.add(
        _buildMetaChip(
          theme,
          icon: Icons.push_pin_rounded,
          label: 'Закреплён',
          background: theme.colorScheme.primaryContainer.withValues(alpha: 0.72),
          foreground: theme.colorScheme.onPrimaryContainer,
          border: theme.colorScheme.primary.withValues(alpha: 0.26),
        ),
      );
    }

    if (_isSupportChat(chat)) {
      final settings = _settingsOf(chat);
      final statusRaw = (chat['support_ticket_status'] ??
              settings['support_ticket_status'] ??
              '')
          .toString();
      final statusLabel = messengerSupportStatusLabel(statusRaw);
      if (statusLabel.isNotEmpty) {
        final colors = _supportToneColors(
          theme,
          messengerSupportStatusTone(statusRaw),
        );
        chips.add(
          _buildMetaChip(
            theme,
            icon: Icons.support_agent_rounded,
            label: statusLabel,
            background: colors.background,
            foreground: colors.foreground,
            border: colors.border,
          ),
        );
      }

      if (statusRaw.trim().toLowerCase() == 'open') {
        chips.add(
          _buildMetaChip(
            theme,
            icon: Icons.schedule_rounded,
            label: messengerSupportWaitingLabel(waitingCustomer: false),
            background: theme.colorScheme.surfaceContainerHighest,
            foreground: theme.colorScheme.onSurfaceVariant,
            border: theme.colorScheme.outlineVariant,
          ),
        );
      }

      final assignee = (chat['support_assignee_name'] ??
              settings['support_assignee_name'] ??
              '')
          .toString()
          .trim();
      if (assignee.isNotEmpty) {
        chips.add(
          _buildMetaChip(
            theme,
            icon: Icons.person_outline_rounded,
            label: assignee,
            background: theme.colorScheme.surfaceContainerHigh,
            foreground: theme.colorScheme.onSurfaceVariant,
            border: theme.colorScheme.outlineVariant,
          ),
        );
      }
    }

    return chips;
  }

  _ChatListBadgeSpec _chatBadgeSpec(Map<String, dynamic> chat) {
    final settings = _settingsOf(chat);
    final title = _chatDisplayTitle(chat).toLowerCase().trim();
    final kind = (settings['kind'] ?? '').toString().trim().toLowerCase();
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final type = (chat['type'] ?? '').toString().trim().toLowerCase();
    final supportTicket =
        kind == 'support_ticket' || _toBool(settings['support_ticket']);

    if (_isMainChannel(chat)) {
      return const _ChatListBadgeSpec(
        label: 'Основной',
        icon: Icons.campaign_outlined,
        tone: _ChatListBadgeTone.primary,
      );
    }
    if (kind == 'reserved_orders' ||
        systemKey == 'reserved_orders' ||
        title == 'забронированный товар') {
      return const _ChatListBadgeSpec(
        label: 'Reserved',
        icon: Icons.inventory_2_outlined,
        tone: _ChatListBadgeTone.tertiary,
      );
    }
    if (kind == 'bug_reports' || title == 'баг-репорты') {
      return const _ChatListBadgeSpec(
        label: 'Bug',
        icon: Icons.bug_report_outlined,
        tone: _ChatListBadgeTone.error,
      );
    }
    if (supportTicket) {
      return const _ChatListBadgeSpec(
        label: 'Support',
        icon: Icons.support_agent_outlined,
        tone: _ChatListBadgeTone.secondary,
      );
    }
    if (title.contains('архив')) {
      return const _ChatListBadgeSpec(
        label: 'Архив',
        icon: Icons.archive_outlined,
        tone: _ChatListBadgeTone.neutral,
      );
    }
    if (type == 'private') {
      return const _ChatListBadgeSpec(
        label: 'ЛС',
        icon: Icons.person_outline,
        tone: _ChatListBadgeTone.neutral,
      );
    }
    if (type == 'channel') {
      return const _ChatListBadgeSpec(
        label: 'Канал',
        icon: Icons.forum_outlined,
        tone: _ChatListBadgeTone.neutral,
      );
    }
    return const _ChatListBadgeSpec(
      label: 'Чат',
      icon: Icons.chat_bubble_outline,
      tone: _ChatListBadgeTone.neutral,
    );
  }

  Widget _buildChatBadge(Map<String, dynamic> chat, ThemeData theme) {
    final spec = _chatBadgeSpec(chat);
    final colors = spec.resolve(theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(spec.icon, size: 13, color: colors.foreground),
          const SizedBox(width: 5),
          Text(
            spec.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.foreground,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatsLoadingSkeleton(ThemeData theme) {
    return ListView.builder(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
      itemCount: 7,
      itemBuilder: (context, index) => _ChatsSkeletonCard(
        index: index,
        theme: theme,
      ),
    );
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
    final phone = (peer['phone'] ?? '').toString().trim();
    if (phone.isNotEmpty) return phone;
    return 'Пользователь';
  }

  String _peerSubtitle(Map<String, dynamic> peer) {
    final phone = (peer['phone'] ?? '').toString().trim();
    if (phone.isNotEmpty) return phone;
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

  Future<void> _openAvatarPreview({
    required String title,
    required String? imageUrl,
    required double focusX,
    required double focusY,
    required double zoom,
  }) async {
    final resolvedImageUrl = (imageUrl ?? '').trim();
    if (resolvedImageUrl.isEmpty) return;
    final media = MediaQuery.of(context);
    final isCompact = media.size.width < 640;
    final previewDiameter = math.min(
      media.size.width - (isCompact ? 36 : 120),
      media.size.height - (isCompact ? 220 : 260),
    ).clamp(180.0, isCompact ? 320.0 : 420.0);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть аватар',
      barrierColor: Colors.black.withValues(alpha: 0.72),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: previewDiameter,
                      height: previewDiameter,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.24),
                            blurRadius: 28,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: AppAvatar(
                          title: title,
                          imageUrl: resolvedImageUrl,
                          focusX: focusX,
                          focusY: focusY,
                          zoom: zoom,
                          radius: previewDiameter / 2,
                          fallbackIcon: Icons.person_outline,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(media.size.width - 40, 420),
                      ),
                      child: Text(
                        title,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close),
                      label: const Text('Закрыть'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildPreviewableAvatar({
    required String title,
    required String? imageUrl,
    required double focusX,
    required double focusY,
    required double zoom,
    required double radius,
    IconData fallbackIcon = Icons.forum_outlined,
  }) {
    final hasImage = (imageUrl ?? '').trim().isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: !hasImage
          ? null
          : () => _openAvatarPreview(
              title: title,
              imageUrl: imageUrl,
              focusX: focusX,
              focusY: focusY,
              zoom: zoom,
            ),
      child: AppAvatar(
        title: title,
        imageUrl: imageUrl,
        focusX: focusX,
        focusY: focusY,
        zoom: zoom,
        radius: radius,
        fallbackIcon: fallbackIcon,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadChats(showLoader: true);
    unawaited(refreshSupportQueueNotices());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureRulesPromptShown());
    });
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
        return;
      }

      if (type == 'socket:connected') {
        _scheduleChatsRefresh(delay: const Duration(milliseconds: 150));
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    _refreshDebounceTimer?.cancel();
    super.dispose();
  }

  String _rulesPrefKey() {
    final userId = authService.currentUser?.id.trim();
    if (userId == null || userId.isEmpty) return 'chat_rules_seen_guest';
    return 'chat_rules_seen_$userId';
  }

  Future<void> _showRulesDialog({bool persistSeen = false}) async {
    if (!mounted) return;
    if (_rulesPromptInProgress) return;
    _rulesPromptInProgress = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Правила канала'),
          content: const Text(
            'Это макет правил, в будущем он будет обновлён.\n\n'
            'Пока соблюдайте приятное общение, без матов, желательно.\n\n'
            'Пока что главное правило: если что-то работает не так или сломается, напишите в этом же приложении через меню "Настройки" -> "Сообщить о проблеме".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Понятно'),
            ),
          ],
        ),
      );
      if (persistSeen) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_rulesPrefKey(), true);
      }
    } finally {
      _rulesPromptInProgress = false;
    }
  }

  Future<void> _ensureRulesPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadySeen = prefs.getBool(_rulesPrefKey()) ?? false;
    if (alreadySeen) return;
    await _showRulesDialog(persistSeen: true);
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
      final nextChats = await loadChatsCollection()..sort(_compareChats);
      if (!mounted) return;
      setState(() {
        _chats = nextChats;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      if (_chats.isEmpty) {
        setState(() => _error = _chatLoadErrorText(e));
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
    final title = _chatDisplayTitle(chat);
    final time = _formatTime(chat['updated_at'] ?? chat['time']);
    final settings = _settingsOf(chat);
    final chatType = (chat['type'] ?? '').toString().trim().toLowerCase();
    final usePeerAvatar = chatType == 'private';
    final peerAvatarUrl = _resolveImageUrl(
      (chat['peer_avatar_url'] ?? '').toString(),
    );
    final channelAvatarUrl = _resolveImageUrl(
      (settings['avatar_url'] ?? '').toString(),
    );
    final avatarUrl = usePeerAvatar
        ? (peerAvatarUrl ?? channelAvatarUrl)
        : channelAvatarUrl;
    final avatarFocusX = usePeerAvatar && peerAvatarUrl != null
        ? _toAvatarFocus(chat['peer_avatar_focus_x'])
        : _toAvatarFocus(settings['avatar_focus_x']);
    final avatarFocusY = usePeerAvatar && peerAvatarUrl != null
        ? _toAvatarFocus(chat['peer_avatar_focus_y'])
        : _toAvatarFocus(settings['avatar_focus_y']);
    final avatarZoom = usePeerAvatar && peerAvatarUrl != null
        ? _toAvatarZoom(chat['peer_avatar_zoom'])
        : _toAvatarZoom(settings['avatar_zoom']);
    final preview = _lastMessagePreview(chat);
    final unreadCount = int.tryParse('${chat['unread_count'] ?? 0}') ?? 0;
    final badge = _buildChatBadge(chat, theme);
    final metaChips = _buildChatMetaChips(chat, theme);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => _openChat(chat),
          onLongPress: () => _openChatActionsMenu(chat),
          onSecondaryTapDown: (details) => _openChatActionsMenu(
            chat,
            globalPosition: details.globalPosition,
          ),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.surface,
                  theme.colorScheme.surfaceContainerLowest,
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: 0.04),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                _buildPreviewableAvatar(
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
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                badge,
                                const SizedBox(height: 8),
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (time.isNotEmpty)
                                Text(
                                  time,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: unreadCount > 0
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (metaChips.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: metaChips,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                height: 1.25,
                                color: unreadCount > 0
                                    ? theme.colorScheme.onSurface
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
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
    final lightweightMode = performanceModeNotifier.value;
    final mainContent = RefreshIndicator(
      onRefresh: _loadChats,
      child: Container(
        decoration: lightweightMode
            ? BoxDecoration(color: theme.colorScheme.surface)
            : BoxDecoration(
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
            ? _buildChatsLoadingSkeleton(theme)
            : _error.isNotEmpty
            ? ListView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
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
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 72),
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 58,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'Пока нет доступных чатов',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Когда появятся личные сообщения, support или системные каналы, они появятся здесь.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _openDirectChatDialog,
                        icon: const Icon(Icons.person_outline),
                        label: const Text('Личные сообщения'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loadChats,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Обновить'),
                      ),
                    ],
                  ),
                ],
              )
            : ListView.builder(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                itemCount: _chats.length,
                itemBuilder: (context, i) => _buildItem(_chats[i]),
              ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Чаты')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Личные сообщения',
        onPressed: _openDirectChatDialog,
        child: const Icon(Icons.person_outline),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: mainContent),
            Positioned(
              left: 14,
              bottom: 14,
              child: FloatingActionButton.small(
                heroTag: 'chat-rules-button',
                tooltip: 'Правила канала',
                onPressed: () => _showRulesDialog(persistSeen: false),
                child: const Text(
                  '?!',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
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
  final List<Map<String, dynamic>> _searchCandidates = [];
  Timer? _lookupDebounceTimer;
  int _lookupRequestSeq = 0;
  Map<String, dynamic>? _exactCandidate;
  String _selectedCandidateId = '';

  bool _submitting = false;
  bool _loadingContacts = true;
  bool _lookupLoading = false;
  String _contactsError = '';
  String _lookupMessage = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleQueryChanged);
    unawaited(_loadContacts(force: true));
  }

  @override
  void dispose() {
    _lookupDebounceTimer?.cancel();
    _controller.removeListener(_handleQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  DateTime? _parseDate(dynamic raw) {
    return parseDateTimeValue(raw);
  }

  String _peerId(Map<String, dynamic> peer) {
    return (peer['id'] ?? peer['contact_user_id'] ?? '').toString().trim();
  }

  bool _isInContacts(Map<String, dynamic> peer) {
    final raw = peer['is_in_contacts'];
    if (raw is bool) return raw;
    final value = '${raw ?? ''}'.toLowerCase().trim();
    return value == 'true' || value == '1' || value == 't' || value == 'yes';
  }

  String _normalizeDigits(String raw) {
    return raw.replaceAll(RegExp(r'\D'), '');
  }

  bool _isLikelyEmail(String raw) {
    final value = raw.trim();
    return value.contains('@') && value.length >= 5;
  }

  bool _canStartLookup(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return false;
    final digits = _normalizeDigits(value);
    if (_isLikelyEmail(value)) return true;
    if (digits.length >= 10) return true;
    if (digits.length >= 4) return true;
    return value.length >= 3;
  }

  int _compareContacts(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ad = _parseDate(
      a['recent_at'] ??
          a['contact_updated_at'] ??
          a['updated_at'] ??
          a['contact_created_at'] ??
          a['created_at'],
    );
    final bd = _parseDate(
      b['recent_at'] ??
          b['contact_updated_at'] ??
          b['updated_at'] ??
          b['contact_created_at'] ??
          b['created_at'],
    );
    if (ad == null && bd == null) {
      final an = widget.peerDisplayName(a).toLowerCase();
      final bn = widget.peerDisplayName(b).toLowerCase();
      return an.compareTo(bn);
    }
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad);
  }

  void _sortContactsInPlace(List<Map<String, dynamic>> items) {
    items.sort(_compareContacts);
  }

  Set<String> _contactIds() {
    return _contacts
        .map((item) => _peerId(item))
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Map<String, dynamic> _applyContactFlag(
    Map<String, dynamic> peer,
    Set<String> contactIds,
  ) {
    final peerId = _peerId(peer);
    if (peerId.isEmpty) return peer;
    final fromContactList = _contacts.firstWhere(
      (item) => _peerId(item) == peerId,
      orElse: () => const <String, dynamic>{},
    );
    final knownInContacts =
        contactIds.contains(peerId) ||
        _isInContacts(peer) ||
        fromContactList.isNotEmpty;
    return {
      ...peer,
      if (fromContactList.isNotEmpty &&
          (peer['alias_name'] ?? '').toString().trim().isEmpty)
        'alias_name': fromContactList['alias_name'],
      'is_in_contacts': knownInContacts,
      'contact_created_at':
          peer['contact_created_at'] ?? fromContactList['contact_created_at'],
      'contact_updated_at':
          peer['contact_updated_at'] ?? fromContactList['contact_updated_at'],
      'recent_at': peer['recent_at'] ?? fromContactList['recent_at'],
    };
  }

  void _syncSearchWithContacts() {
    final contactIds = _contactIds();
    _exactCandidate = _exactCandidate == null
        ? null
        : _applyContactFlag(_exactCandidate!, contactIds);
    for (var i = 0; i < _searchCandidates.length; i++) {
      _searchCandidates[i] = _applyContactFlag(
        _searchCandidates[i],
        contactIds,
      );
    }
  }

  void _markUserAsContactLocally(
    String userId, {
    String aliasName = '',
    dynamic contactCreatedAt,
    dynamic contactUpdatedAt,
  }) {
    if (userId.isEmpty) return;
    final nowIso = DateTime.now().toIso8601String();
    Map<String, dynamic> updatePeer(Map<String, dynamic> peer) {
      return {
        ...peer,
        'is_in_contacts': true,
        if (aliasName.isNotEmpty) 'alias_name': aliasName,
        'contact_created_at': contactCreatedAt ?? peer['contact_created_at'],
        'contact_updated_at': contactUpdatedAt ?? nowIso,
        'recent_at': contactUpdatedAt ?? nowIso,
      };
    }

    final index = _contacts.indexWhere((item) => _peerId(item) == userId);
    if (index >= 0) {
      _contacts[index] = {
        ...updatePeer(_contacts[index]),
        'contact_user_id': userId,
      };
    } else {
      Map<String, dynamic> base = const <String, dynamic>{};
      final candidate = _searchCandidates.firstWhere(
        (item) => _peerId(item) == userId,
        orElse: () => const <String, dynamic>{},
      );
      if (candidate.isNotEmpty) {
        base = candidate;
      } else if (_exactCandidate != null &&
          _peerId(_exactCandidate!) == userId) {
        base = _exactCandidate!;
      }
      if (base.isNotEmpty) {
        _contacts.add({...updatePeer(base), 'contact_user_id': userId});
      }
    }
    _sortContactsInPlace(_contacts);

    if (_exactCandidate != null && _peerId(_exactCandidate!) == userId) {
      _exactCandidate = updatePeer(_exactCandidate!);
    }
    for (var i = 0; i < _searchCandidates.length; i++) {
      if (_peerId(_searchCandidates[i]) == userId) {
        _searchCandidates[i] = updatePeer(_searchCandidates[i]);
      }
    }
  }

  void _markUserAsNotContactLocally(String userId) {
    if (userId.isEmpty) return;
    if (_exactCandidate != null && _peerId(_exactCandidate!) == userId) {
      _exactCandidate = {..._exactCandidate!, 'is_in_contacts': false};
    }
    for (var i = 0; i < _searchCandidates.length; i++) {
      if (_peerId(_searchCandidates[i]) == userId) {
        _searchCandidates[i] = {
          ..._searchCandidates[i],
          'is_in_contacts': false,
        };
      }
    }
  }

  Map<String, dynamic>? _selectedCandidate() {
    if (_selectedCandidateId.isNotEmpty) {
      if (_exactCandidate != null &&
          _peerId(_exactCandidate!) == _selectedCandidateId) {
        return _exactCandidate;
      }
      for (final candidate in _searchCandidates) {
        if (_peerId(candidate) == _selectedCandidateId) return candidate;
      }
    }
    if (_exactCandidate != null) return _exactCandidate;
    if (_searchCandidates.length == 1) return _searchCandidates.first;
    return null;
  }

  void _handleQueryChanged() {
    final query = _controller.text.trim();
    _lookupDebounceTimer?.cancel();

    if (query.isEmpty) {
      setState(() {
        _lookupLoading = false;
        _lookupMessage = '';
        _exactCandidate = null;
        _searchCandidates.clear();
        _selectedCandidateId = '';
      });
      return;
    }

    if (!_canStartLookup(query)) {
      setState(() {
        _lookupLoading = false;
        _lookupMessage = 'Введите минимум 3 символа или полный email/номер';
        _exactCandidate = null;
        _searchCandidates.clear();
        _selectedCandidateId = '';
      });
      return;
    }

    _lookupDebounceTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_lookupUsers(query));
    });
  }

  Future<void> _lookupUsers(String query) async {
    final requestSeq = ++_lookupRequestSeq;
    if (mounted) {
      setState(() {
        _lookupLoading = true;
        _lookupMessage = '';
      });
    }

    try {
      final resp = await authService.dio.get(
        '/api/chats/direct/search',
        queryParameters: {'query': query, 'limit': 10},
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

      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) {
        throw Exception('Неверный ответ сервера');
      }
      final payload = Map<String, dynamic>.from(data['data']);
      final exact = payload['exact'] is Map
          ? Map<String, dynamic>.from(payload['exact'])
          : null;
      final candidatesRaw = payload['candidates'] is List
          ? List<Map<String, dynamic>>.from(payload['candidates'])
          : <Map<String, dynamic>>[];

      final seenIds = <String>{};
      final candidates = <Map<String, dynamic>>[];
      for (final item in candidatesRaw) {
        final id = _peerId(item);
        if (id.isEmpty || seenIds.contains(id)) continue;
        seenIds.add(id);
        candidates.add(item);
      }

      String selectedId = _selectedCandidateId;
      if (selectedId.isNotEmpty &&
          !(exact != null && _peerId(exact) == selectedId) &&
          !candidates.any((item) => _peerId(item) == selectedId)) {
        selectedId = '';
      }
      if (selectedId.isEmpty && exact != null) {
        selectedId = _peerId(exact);
      }
      if (selectedId.isEmpty && candidates.length == 1) {
        selectedId = _peerId(candidates.first);
      }

      if (!mounted || requestSeq != _lookupRequestSeq) return;
      setState(() {
        _lookupLoading = false;
        _lookupMessage = (payload['message'] ?? '').toString().trim();
        _exactCandidate = exact;
        _searchCandidates
          ..clear()
          ..addAll(candidates);
        _selectedCandidateId = selectedId;
        _syncSearchWithContacts();
      });
    } catch (e) {
      if (!mounted || requestSeq != _lookupRequestSeq) return;
      setState(() {
        _lookupLoading = false;
        _lookupMessage = 'Ошибка поиска: ${widget.extractDioError(e)}';
        _exactCandidate = null;
        _searchCandidates.clear();
        _selectedCandidateId = '';
      });
    }
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
      final loaded = List<Map<String, dynamic>>.from(data['data']);
      _sortContactsInPlace(loaded);
      setState(() {
        _contacts
          ..clear()
          ..addAll(loaded);
        _syncSearchWithContacts();
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
      final chatTitle = (chat['display_title'] ?? '').toString().trim().isNotEmpty
          ? (chat['display_title'] ?? '').toString().trim()
          : widget.peerDisplayName(peer);
      final chatSettings = chat['settings'] is Map
          ? Map<String, dynamic>.from(chat['settings'])
          : null;

      final peerId = _peerId(peer);
      if (peerId.isNotEmpty && _isInContacts(peer)) {
        _markUserAsContactLocally(
          peerId,
          aliasName: (peer['alias_name'] ?? '').toString().trim(),
          contactCreatedAt: peer['contact_created_at'],
          contactUpdatedAt: peer['contact_updated_at'],
        );
      }

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

  Future<void> _openDirectFromSelection() async {
    final selected = _selectedCandidate();
    final selectedId = selected == null ? '' : _peerId(selected);
    if (selectedId.isNotEmpty) {
      await _openDirect(userId: selectedId);
      return;
    }
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    await _openDirect(query: query);
  }

  Future<void> _addToContacts({String? query, String? userId}) async {
    final normalizedQuery = (query ?? '').trim();
    final normalizedUserId = (userId ?? '').trim();
    if (normalizedQuery.isEmpty && normalizedUserId.isEmpty) return;
    if (_submitting) return;

    setState(() => _submitting = true);
    try {
      final resp = await authService.dio.post(
        '/api/chats/contacts',
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

      final payload = resp.data is Map && resp.data['data'] is Map
          ? Map<String, dynamic>.from(resp.data['data'])
          : <String, dynamic>{};
      final created = payload['created'] == true;
      final peer = payload['peer'] is Map
          ? Map<String, dynamic>.from(payload['peer'])
          : <String, dynamic>{};
      final peerId = _peerId(peer);
      final aliasName = (payload['alias_name'] ?? peer['alias_name'] ?? '')
          .toString()
          .trim();

      if (peerId.isNotEmpty) {
        _markUserAsContactLocally(
          peerId,
          aliasName: aliasName,
          contactCreatedAt: peer['contact_created_at'],
          contactUpdatedAt:
              peer['contact_updated_at'] ?? DateTime.now().toIso8601String(),
        );
      }

      showGlobalAppNotice(
        created ? 'Контакт добавлен' : 'Пользователь уже в контактах',
        tone: created ? AppNoticeTone.success : AppNoticeTone.info,
      );
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

  Future<void> _addToContactsBySelection() async {
    final selected = _selectedCandidate();
    final selectedId = selected == null ? '' : _peerId(selected);
    if (selectedId.isNotEmpty) {
      await _addToContacts(userId: selectedId);
      return;
    }
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    await _addToContacts(query: query);
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
        _contacts.removeWhere((item) => _peerId(item) == userId);
        _markUserAsNotContactLocally(userId);
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

  Widget _buildSearchPeerTile(Map<String, dynamic> peer) {
    final theme = Theme.of(context);
    final peerId = _peerId(peer);
    final title = widget.peerDisplayName(peer);
    final subtitle = widget.peerSubtitle(peer);
    final isSelected =
        _selectedCandidateId.isNotEmpty && peerId == _selectedCandidateId;
    final inContacts = _isInContacts(peer);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: peerId.isEmpty
            ? null
            : () {
                setState(() => _selectedCandidateId = peerId);
              },
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 2,
          ),
          leading: AppAvatar(
            title: title,
            imageUrl: widget.resolveImageUrl(
              (peer['avatar_url'] ?? '').toString().trim(),
            ),
            focusX: widget.toAvatarFocus(peer['avatar_focus_x']),
            focusY: widget.toAvatarFocus(peer['avatar_focus_y']),
            zoom: widget.toAvatarZoom(peer['avatar_zoom']),
            radius: 18,
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle.isEmpty
              ? null
              : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                inContacts ? 'В контактах' : 'Не в контактах',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: inContacts
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isSelected)
                Icon(
                  Icons.check_circle,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLookupPanel() {
    final theme = Theme.of(context);
    final query = _controller.text.trim();
    final canLookup = _canStartLookup(query);
    final exact = _exactCandidate;
    final exactId = exact == null ? '' : _peerId(exact);
    final candidatesWithoutExact = _searchCandidates
        .where((item) => _peerId(item) != exactId)
        .toList();

    String helper = '';
    if (query.isEmpty) {
      helper = 'Введите email, номер или имя для поиска';
    } else if (!canLookup) {
      helper = 'Введите минимум 3 символа или полный email/номер';
    } else if (_lookupLoading) {
      helper = 'Ищем пользователей...';
    } else if (_lookupMessage.isNotEmpty) {
      helper = _lookupMessage;
    } else if (exact == null && candidatesWithoutExact.isEmpty) {
      helper = 'Пользователи не найдены';
    } else if (exact != null) {
      helper = 'Проверьте данные и выберите действие ниже';
    } else {
      helper = 'Выберите человека из списка';
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surfaceContainerLowest,
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Проверка данных', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              if (_lookupLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            helper,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (exact != null) ...[
            const SizedBox(height: 8),
            Text('Точное совпадение', style: theme.textTheme.labelLarge),
            _buildSearchPeerTile(exact),
          ],
          if (candidatesWithoutExact.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Найденные пользователи', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 170),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: candidatesWithoutExact.length,
                separatorBuilder: (_, index) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _buildSearchPeerTile(candidatesWithoutExact[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContactTile(Map<String, dynamic> contact) {
    final contactUserId = _peerId(contact);
    final title = widget.peerDisplayName(contact);
    final subtitle = widget.peerSubtitle(contact);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        title: title,
        imageUrl: widget.resolveImageUrl(
          (contact['avatar_url'] ?? '').toString().trim(),
        ),
        focusX: widget.toAvatarFocus(contact['avatar_focus_x']),
        focusY: widget.toAvatarFocus(contact['avatar_focus_y']),
        zoom: widget.toAvatarZoom(contact['avatar_zoom']),
        radius: 18,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: _submitting || contactUserId.isEmpty
          ? null
          : () => _openDirect(userId: contactUserId),
      trailing: IconButton(
        tooltip: 'Удалить контакт',
        onPressed: _submitting || contactUserId.isEmpty
            ? null
            : () => _removeContact(contactUserId),
        icon: const Icon(Icons.person_remove_alt_1_outlined),
      ),
    );
  }

  Widget _buildContactsSection() {
    if (_loadingContacts) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_contactsError.isNotEmpty) {
      return Center(
        child: Text(
          'Не удалось загрузить контакты: $_contactsError',
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_contacts.isEmpty) {
      return const Center(child: Text('Контактов пока нет'));
    }

    final recent = _contacts.take(5).toList();
    return ListView(
      children: [
        if (recent.isNotEmpty) ...[
          Text('Недавние', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: recent.map((contact) {
              final id = _peerId(contact);
              final title = widget.peerDisplayName(contact);
              return ActionChip(
                avatar: const Icon(Icons.chat_bubble_outline, size: 16),
                label: Text(title, overflow: TextOverflow.ellipsis),
                onPressed: _submitting || id.isEmpty
                    ? null
                    : () => _openDirect(userId: id),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Text('Все контакты', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
        ],
        ..._contacts.map(_buildContactTile),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dialogHeight = (MediaQuery.of(context).size.height * 0.72).clamp(
      320.0,
      620.0,
    );
    final query = _controller.text.trim();
    final selected = _selectedCandidate();
    final selectedId = selected == null ? '' : _peerId(selected);
    final selectedInContacts = selected != null && _isInContacts(selected);
    final allowFallbackByFullIdentifier =
        _isLikelyEmail(query) || _normalizeDigits(query).length >= 10;
    final canOpenDirect =
        !_submitting &&
        (selectedId.isNotEmpty ||
            (selected == null && allowFallbackByFullIdentifier));
    final canAddContact =
        !_submitting && selectedId.isNotEmpty && !selectedInContacts;

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
              onSubmitted: (_) => _openDirectFromSelection(),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: canOpenDirect ? _openDirectFromSelection : null,
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Открыть ЛС'),
                ),
                OutlinedButton.icon(
                  onPressed: canAddContact ? _addToContactsBySelection : null,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Добавить в контакты'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildLookupPanel(),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.contacts_outlined, size: 18),
                const SizedBox(width: 6),
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
            Expanded(child: _buildContactsSection()),
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

enum _ChatListBadgeTone { primary, secondary, tertiary, error, neutral }

class _ChatListBadgeSpec {
  const _ChatListBadgeSpec({
    required this.label,
    required this.icon,
    required this.tone,
  });

  final String label;
  final IconData icon;
  final _ChatListBadgeTone tone;

  _ChatListBadgeColors resolve(ThemeData theme) {
    switch (tone) {
      case _ChatListBadgeTone.primary:
        return _ChatListBadgeColors(
          background: theme.colorScheme.primaryContainer,
          foreground: theme.colorScheme.onPrimaryContainer,
          border: theme.colorScheme.primary.withValues(alpha: 0.18),
        );
      case _ChatListBadgeTone.secondary:
        return _ChatListBadgeColors(
          background: theme.colorScheme.secondaryContainer,
          foreground: theme.colorScheme.onSecondaryContainer,
          border: theme.colorScheme.secondary.withValues(alpha: 0.18),
        );
      case _ChatListBadgeTone.tertiary:
        return _ChatListBadgeColors(
          background: theme.colorScheme.tertiaryContainer,
          foreground: theme.colorScheme.onTertiaryContainer,
          border: theme.colorScheme.tertiary.withValues(alpha: 0.18),
        );
      case _ChatListBadgeTone.error:
        return _ChatListBadgeColors(
          background: theme.colorScheme.errorContainer,
          foreground: theme.colorScheme.onErrorContainer,
          border: theme.colorScheme.error.withValues(alpha: 0.18),
        );
      case _ChatListBadgeTone.neutral:
        return _ChatListBadgeColors(
          background: theme.colorScheme.surfaceContainerHigh,
          foreground: theme.colorScheme.onSurfaceVariant,
          border: theme.colorScheme.outlineVariant,
        );
    }
  }
}

class _ChatListBadgeColors {
  const _ChatListBadgeColors({
    required this.background,
    required this.foreground,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color border;
}

class _ChatsSkeletonCard extends StatelessWidget {
  const _ChatsSkeletonCard({
    required this.index,
    required this.theme,
  });

  final int index;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final widths = <double>[0.72, 0.58, 0.66, 0.49, 0.61, 0.54, 0.69];
    final subtitleWidths = <double>[0.86, 0.76, 0.82, 0.68, 0.73, 0.78, 0.84];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              theme.colorScheme.surfaceContainerLowest,
            ],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              _SkeletonBlock(
                width: 52,
                height: 52,
                radius: 26,
                theme: theme,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _SkeletonBlock(
                          width: 78,
                          height: 24,
                          radius: 999,
                          theme: theme,
                        ),
                        const Spacer(),
                        _SkeletonBlock(
                          width: 42,
                          height: 14,
                          radius: 8,
                          theme: theme,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FractionallySizedBox(
                      widthFactor: widths[index % widths.length],
                      child: _SkeletonBlock(
                        width: double.infinity,
                        height: 18,
                        radius: 9,
                        theme: theme,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FractionallySizedBox(
                      widthFactor: subtitleWidths[index % subtitleWidths.length],
                      child: _SkeletonBlock(
                        width: double.infinity,
                        height: 14,
                        radius: 8,
                        theme: theme,
                      ),
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
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    required this.width,
    required this.height,
    required this.radius,
    required this.theme,
  });

  final double width;
  final double height;
  final double radius;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.surfaceContainerHigh,
          ],
        ),
      ),
    );
  }
}
