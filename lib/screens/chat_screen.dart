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
        if (chatId != null && chatId.toString() == widget.chatId) {
          // append message
          setState(() {
            _messages.add(Map<String, dynamic>.from(msg));
          });
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
        setState(() => _messages = List<Map<String, dynamic>>.from(data['data']));
      }
    } catch (e) {
      // игнорируем, оставляем пустой список
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
        // optimistic: append message if server returned it
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          setState(() {
            _messages.add(Map<String, dynamic>.from(data['data']));
          });
        } else {
          await _loadMessages();
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ошибка отправки сообщения')));
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
                          decoration: BoxDecoration(color: fromMe ? Colors.blue : Colors.grey[300], borderRadius: BorderRadius.circular(8)),
                          child: Text(m['text'] ?? '', style: TextStyle(color: fromMe ? Colors.white : Colors.black)),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Row(
              children: [
                Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: TextField(controller: _controller))),
                IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
