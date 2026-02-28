import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
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

  String _chatIdOf(Map<String, dynamic> chat) => (chat['id'] ?? '').toString();

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
    });
  }

  void _removeChatLocally(String chatId) {
    if (chatId.isEmpty) return;
    setState(() {
      _chats = _chats.where((c) => _chatIdOf(c) != chatId).toList();
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
    if (raw == null) return null;
    if (raw is DateTime) return raw.toLocal();
    return DateTime.tryParse(raw.toString())?.toLocal();
  }

  String _formatTime(dynamic raw) {
    final date = _parseDate(raw);
    if (date == null) return '';
    String pad(int v) => v < 10 ? '0$v' : '$v';
    final now = DateTime.now();
    final sameDay =
        date.year == now.year && date.month == now.month && date.day == now.day;
    if (sameDay) {
      return '${pad(date.hour)}:${pad(date.minute)}';
    }
    return '${pad(date.day)}.${pad(date.month)}';
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
    final currentUserId = authService.currentUser?.id ?? '';
    final prefix = senderId.isNotEmpty && senderId == currentUserId
        ? 'Вы'
        : (senderName.isNotEmpty ? senderName : 'Система');
    return '$prefix: $text';
  }

  @override
  void initState() {
    super.initState();
    _loadChats();
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type'] as String? ?? '';
      final data = event['data'];

      if (type == 'chat:created') {
        if (data is Map && data['chat'] is Map) {
          _upsertChatLocally(Map<String, dynamic>.from(data['chat']));
        } else {
          _loadChats();
        }
        return;
      }

      if (type == 'chat:updated') {
        if (data is Map && data['chat'] is Map) {
          _upsertChatLocally(Map<String, dynamic>.from(data['chat']));
        } else {
          _loadChats();
        }
        return;
      }

      if (type == 'chat:deleted') {
        if (data is Map) {
          _removeChatLocally((data['chatId'] ?? '').toString());
        }
        return;
      }

      if (type == 'chat:message' ||
          type == 'chat:message:global' ||
          type == 'chat:message:deleted') {
        _loadChats();
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadChats() async {
    setState(() {
      _loading = true;
      _error = '';
    });

    try {
      final resp = await authService.dio.get('/api/chats');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        setState(() => _chats = List<Map<String, dynamic>>.from(data['data']));
      } else {
        setState(() => _error = 'Неверный ответ сервера');
      }
    } catch (e) {
      setState(() => _error = 'Ошибка загрузки чатов: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            final chatId = chat['id']?.toString() ?? '';
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
            );
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
      appBar: AppBar(title: const Text('Чаты')),
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
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _error,
                          style: const TextStyle(color: Colors.red),
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
