// lib/screens/chats_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import 'chat_screen.dart';
import 'create_chat_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _loadChats();
    // Listen to global chat events (created/updated)
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type'] as String? ?? '';
      if (type == 'chat:created' || type == 'chat:message' || type == 'chat:message:global') {
        // reload chats when new public chat created or message arrives
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

  Widget _buildAvatar(String title) {
    final initials = title.trim().isEmpty
        ? '?'
        : title.trim().split(' ').map((s) => s.isEmpty ? '' : s[0]).take(2).join().toUpperCase();
    return CircleAvatar(child: Text(initials));
  }

  Widget _buildItem(Map<String, dynamic> chat) {
    final title = (chat['title'] ?? chat['name'] ?? 'Чат').toString();
    final last = (chat['last_message'] ?? chat['last'] ?? '').toString();
    final time = (chat['updated_at'] ?? chat['time'] ?? '').toString();

    return ListTile(
      leading: _buildAvatar(title),
      title: Text(title),
      subtitle: Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(time, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      onTap: () {
        final chatId = chat['id']?.toString() ?? '';
        Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId, chatTitle: title)));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = authService.currentUser?.role;
    final canCreate = role == 'creator' || role == 'admin';

    return Scaffold(
      appBar: AppBar(title: const Text('Чаты')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadChats,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty
                  ? ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_error, style: const TextStyle(color: Colors.red)),
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
                  : ListView.separated(
                      itemCount: _chats.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _buildItem(_chats[i]),
                    ),
        ),
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton(
              onPressed: () async {
                final created = await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateChatScreen()));
                if (created == true) _loadChats();
              },
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
