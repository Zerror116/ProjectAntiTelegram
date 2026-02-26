// lib/screens/chat_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  const ChatScreen({super.key, required this.chatId, required this.chatTitle});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  StreamSubscription? _chatSub;

  // ✅ ИСПРАВЛЕНИЕ: Отслеживаем ID сообщений, чтобы избежать дублирования
  final Set<String> _messageIds = {};

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _joinRoom();
    // Listen to global chat events and append messages for this chat
    _chatSub = chatEventsController.stream.listen((event) {
      final type = event['type'] as String? ?? '';
      final data = event['data'];
      if (type == 'chat:message' && data is Map) {
        final msg = data['message'] ?? data;
        final chatId = data['chatId'] ?? msg['chat_id'] ?? msg['chatId'];
        final msgId = msg['id']?.toString();

        // ✅ ИСПРАВЛЕНИЕ: Проверяем, есть ли уже такое сообщение
        if (chatId != null && chatId.toString() == widget.chatId) {
          if (msgId != null && !_messageIds.contains(msgId)) {
            setState(() {
              _messages.add(Map<String, dynamic>.from(msg));
              _messageIds.add(msgId);
            });
            debugPrint('✅ Message added via Socket: $msgId');
          } else if (msgId == null) {
            // Если нет ID, добавляем (старый формат)
            setState(() {
              _messages.add(Map<String, dynamic>.from(msg));
            });
          } else {
            debugPrint('⚠️ Message already exists (duplicate): $msgId');
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _leaveRoom();
    _chatSub?.cancel();
    super.dispose();
  }

  Future<void> _joinRoom() async {
    try {
      if (socket != null && socket!.connected) {
        socket!.emit('join_chat', widget.chatId);
      } else {
        // if socket not connected yet, try to connect and then join
        socket?.on('connect', (_) {
          socket!.emit('join_chat', widget.chatId);
        });
      }
    } catch (e) {
      debugPrint('joinRoom error: $e');
    }
  }

  Future<void> _leaveRoom() async {
    try {
      socket?.emit('leave_chat', widget.chatId);
    } catch (_) {}
  }

  Future<void> _loadMessages() async {
    setState(() => _loading = true);
    try {
      final resp = await authService.dio.get('/api/chats/${widget.chatId}/messages');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final messages = List<Map<String, dynamic>>.from(data['data']);
        setState(() {
          _messages = messages;
          // ✅ Заполняем Set с ID существующих сообщений
          _messageIds.clear();
          for (final msg in messages) {
            final msgId = msg['id']?.toString();
            if (msgId != null) {
              _messageIds.add(msgId);
            }
          }
        });
        debugPrint('✅ Loaded ${messages.length} messages');
      }
    } catch (e) {
      debugPrint('❌ Error loading messages: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    try {
      final resp = await authService.dio.post('/api/chats/${widget.chatId}/messages', data: {'text': text});
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        _controller.clear();

        // ✅ ИСПРАВЛЕНИЕ: Добавляем сообщение только если оно пришло от сервера
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          final msg = Map<String, dynamic>.from(data['data']);
          final msgId = msg['id']?.toString();

          if (msgId != null && !_messageIds.contains(msgId)) {
            setState(() {
              _messages.add(msg);
              _messageIds.add(msgId);
            });
            debugPrint('✅ Message sent and added: $msgId');
          } else {
            debugPrint('⚠️ Message already exists, skipping add');
          }
        } else {
          // Если сервер не вернул сообщение, загружаем заново
          await _loadMessages();
        }
      }
    } catch (e) {
      debugPrint('❌ Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ошибка от��равки сообщения')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatTitle)),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(child: Text('Нет сообщений'))
                    : ListView.builder(
                        reverse: false,
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final m = _messages[i];
                          final fromMe = (m['from_me'] == true) || (m['sender_id'] == authService.currentUser?.id);
                          return Align(
                            alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: fromMe ? Colors.blue : Colors.grey[300],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                m['text'] ?? '',
                                style: TextStyle(color: fromMe ? Colors.white : Colors.black),
                              ),
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Сообщение...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}