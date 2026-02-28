// lib/screens/chat_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../widgets/app_avatar.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  final String? chatType;
  final Map<String, dynamic>? chatSettings;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    this.chatType,
    this.chatSettings,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _searchController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _incomingQueue = [];

  bool _loading = true;
  bool _buyLoading = false;
  bool _markingPlaced = false;
  bool _searchMode = false;

  String _searchQuery = '';

  StreamSubscription? _chatSub;
  Timer? _incomingTimer;

  final Set<String> _messageIds = {};
  final Set<String> _placedCartItemIds = {};

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _joinRoom();

    _searchController.addListener(() {
      final next = _searchController.text.trim();
      if (next == _searchQuery) return;
      setState(() => _searchQuery = next);
    });

    _controller.addListener(() {
      if (_inputFocusNode.hasFocus) {
        _scrollToBottom(animated: true);
      }
    });

    _inputFocusNode.addListener(() {
      if (_inputFocusNode.hasFocus) {
        _scrollToBottom(animated: true);
      }
    });

    _chatSub = chatEventsController.stream.listen((event) {
      final type = event['type'] as String? ?? '';
      final data = event['data'];
      if (type == 'chat:message' && data is Map) {
        final msg = data['message'] ?? data;
        final chatId = data['chatId'] ?? msg['chat_id'] ?? msg['chatId'];
        if (chatId != null && chatId.toString() == widget.chatId) {
          _enqueueIncomingMessage(Map<String, dynamic>.from(msg));
        }
        return;
      }
      if (type == 'chat:message:deleted' && data is Map) {
        final chatId = data['chatId']?.toString() ?? '';
        if (chatId != widget.chatId) return;
        final messageId = data['messageId']?.toString() ?? '';
        if (messageId.isEmpty) return;
        _removeMessageLocally(messageId);
      }
    });
  }

  @override
  void dispose() {
    _incomingTimer?.cancel();
    _chatSub?.cancel();
    _leaveRoom();

    _controller.dispose();
    _searchController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw.toLocal();
    final value = raw.toString().trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  int _compareByCreatedAt(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ad = _parseDate(a['created_at']);
    final bd = _parseDate(b['created_at']);
    if (ad == null && bd == null) return 0;
    if (ad == null) return -1;
    if (bd == null) return 1;
    return ad.compareTo(bd);
  }

  String _formatDateLabel(DateTime date) {
    String pad(int v) => v < 10 ? '0$v' : '$v';
    return '${pad(date.day)}.${pad(date.month)}.${date.year}';
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final p = _scrollController.position;
    return (p.maxScrollExtent - p.pixels) <= 120;
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  void _upsertMessage(Map<String, dynamic> msg, {bool autoScroll = false}) {
    final msgId = msg['id']?.toString();
    setState(() {
      if (msgId == null || msgId.isEmpty) {
        _messages = [..._messages, msg]..sort(_compareByCreatedAt);
      } else {
        final index = _messages.indexWhere((m) => m['id']?.toString() == msgId);
        if (index >= 0) {
          _messages[index] = {..._messages[index], ...msg};
        } else {
          _messages = [..._messages, msg];
        }
        _messages.sort(_compareByCreatedAt);
        _messageIds.add(msgId);
      }
    });

    if (autoScroll) {
      _scrollToBottom(animated: true);
    }
  }

  void _removeMessageLocally(String messageId) {
    setState(() {
      _messages = _messages
          .where((m) => m['id']?.toString() != messageId)
          .toList();
      _incomingQueue.removeWhere((m) => m['id']?.toString() == messageId);
      _messageIds.remove(messageId);
    });
  }

  void _startIncomingQueueDrain() {
    if (_incomingTimer != null) return;

    _drainIncomingMessage();
    _incomingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _drainIncomingMessage();
    });
  }

  void _drainIncomingMessage() {
    if (_incomingQueue.isEmpty) {
      _incomingTimer?.cancel();
      _incomingTimer = null;
      return;
    }

    final msg = _incomingQueue.removeAt(0);
    final fromMe = msg['sender_id'] == authService.currentUser?.id;
    final shouldScroll = _isNearBottom() || fromMe;
    _upsertMessage(msg, autoScroll: shouldScroll);

    if (_incomingQueue.isEmpty) {
      _incomingTimer?.cancel();
      _incomingTimer = null;
    }
  }

  void _enqueueIncomingMessage(Map<String, dynamic> msg) {
    final msgId = msg['id']?.toString();
    if (msgId != null && msgId.isNotEmpty) {
      if (_messageIds.contains(msgId)) {
        _upsertMessage(msg, autoScroll: false);
        return;
      }
      final existingIndex = _messages.indexWhere(
        (m) => m['id']?.toString() == msgId,
      );
      if (existingIndex >= 0) {
        _upsertMessage(msg, autoScroll: false);
        return;
      }

      final queuedIndex = _incomingQueue.indexWhere(
        (m) => m['id']?.toString() == msgId,
      );
      if (queuedIndex >= 0) {
        _incomingQueue[queuedIndex] = {..._incomingQueue[queuedIndex], ...msg};
        return;
      }
    }

    _incomingQueue.add(msg);
    _startIncomingQueueDrain();
  }

  bool _isPublicChannel() {
    if ((widget.chatType ?? '').toLowerCase().trim() != 'channel') return false;
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    final visibility = (settings['visibility'] ?? 'public')
        .toString()
        .toLowerCase()
        .trim();
    return visibility != 'private';
  }

  bool _canCompose() {
    if (_isPublicChannel()) {
      final role = authService.effectiveRole.toLowerCase().trim();
      return role == 'admin' || role == 'creator';
    }
    return true;
  }

  String? _composeBlockedReason() {
    if (!_isPublicChannel()) return null;
    if (_canCompose()) return null;
    return 'В этом публичном канале писать могут только admin и creator';
  }

  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
    if (isShiftPressed) {
      return KeyEventResult.ignored;
    }

    if (_canCompose()) {
      _send();
    }
    return KeyEventResult.handled;
  }

  Future<void> _joinRoom() async {
    try {
      if (socket != null && socket!.connected) {
        socket!.emit('join_chat', widget.chatId);
      } else {
        socket?.on('connect', (_) {
          socket?.emit('join_chat', widget.chatId);
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
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final messages = List<Map<String, dynamic>>.from(data['data'])
          ..sort(_compareByCreatedAt);
        setState(() {
          _messages = messages;
          _incomingQueue.clear();
          _messageIds
            ..clear()
            ..addAll(
              messages
                  .map((m) => m['id']?.toString())
                  .where((id) => id != null && id.isNotEmpty)
                  .cast<String>(),
            );
        });
        _incomingTimer?.cancel();
        _incomingTimer = null;
        _scrollToBottom(animated: false);
      }
    } catch (e) {
      debugPrint('Error loading messages: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyText(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: normalized));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Текст скопирован')));
  }

  Future<void> _send() async {
    if (!_canCompose()) return;

    final text = _controller.text.trim();
    if (text.isEmpty) return;

    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/messages',
        data: {'text': text},
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        _controller.clear();
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          final msg = Map<String, dynamic>.from(data['data']);
          _upsertMessage(msg, autoScroll: true);
        } else {
          await _loadMessages();
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ошибка отправки сообщения')),
      );
    }
  }

  Future<void> _buyProduct(Map<String, dynamic> meta) async {
    final productId = meta['product_id']?.toString();
    if (productId == null || productId.isEmpty) return;
    final inStock = int.tryParse((meta['quantity'] ?? '').toString()) ?? 0;
    if (inStock <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Товар закончился')));
      return;
    }
    setState(() => _buyLoading = true);
    try {
      final resp = await authService.dio.post(
        '/api/cart/add',
        data: {'product_id': productId, 'quantity': 1},
      );
      if (!mounted) return;
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Товар добавлен в корзину')),
        );
        await _loadMessages();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось добавить товар в корзину')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка покупки: ${_extractDioError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _buyLoading = false);
    }
  }

  String _extractDioError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final message = (data['error'] ?? data['message'] ?? '')
            .toString()
            .trim();
        if (message.isNotEmpty) return message;
      }
      if (e.response?.statusCode == 400) {
        return 'Запрос отклонен сервером';
      }
      return e.message ?? 'Ошибка запроса';
    }
    return e.toString();
  }

  bool _isCatalogProduct(Map<String, dynamic> message) {
    final metaMap = _metaMapOf(message['meta']);
    final kind = metaMap['kind']?.toString() ?? '';
    if (kind.isNotEmpty) return kind == 'catalog_product';
    return metaMap['product_id'] != null && metaMap['cart_item_id'] == null;
  }

  bool _isReservedOrder(Map<String, dynamic> message) {
    final metaMap = _metaMapOf(message['meta']);
    return metaMap['kind']?.toString() == 'reserved_order_item' &&
        (metaMap['reservation_id'] != null || metaMap['cart_item_id'] != null);
  }

  bool _isAdminOrCreator() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin' || role == 'creator';
  }

  bool _isCreatorRole() {
    final role = (authService.currentUser?.role ?? authService.effectiveRole)
        .toLowerCase()
        .trim();
    return role == 'creator';
  }

  Future<int?> _askShelfNumber() async {
    final controller = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Номер полки'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Введите номер полки',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(value);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _markReservedOrderPlaced(Map<String, dynamic> meta) async {
    final reservationId = meta['reservation_id']?.toString();
    final cartItemId = meta['cart_item_id']?.toString();
    if ((reservationId == null || reservationId.isEmpty) &&
        (cartItemId == null || cartItemId.isEmpty)) {
      return;
    }
    if (cartItemId != null &&
        cartItemId.isNotEmpty &&
        _placedCartItemIds.contains(cartItemId)) {
      return;
    }
    setState(() => _markingPlaced = true);
    try {
      final resp = await authService.dio.post(
        '/api/admin/orders/mark_placed',
        data: {
          if (reservationId != null && reservationId.isNotEmpty)
            'reservation_id': reservationId,
          if (cartItemId != null && cartItemId.isNotEmpty)
            'cart_item_id': cartItemId,
        },
      );
      if ((resp.statusCode == 200 || resp.statusCode == 201) && mounted) {
        setState(() {
          if (cartItemId != null && cartItemId.isNotEmpty) {
            _placedCartItemIds.add(cartItemId);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Товар отмечен как обработанный')),
        );
      }
    } catch (e) {
      int? shelfToSend;
      try {
        final responseData = (e as dynamic).response?.data;
        final code = responseData is Map
            ? responseData['code']?.toString()
            : null;
        if (code == 'SHELF_REQUIRED') {
          shelfToSend = await _askShelfNumber();
          if (shelfToSend == null || shelfToSend <= 0) {
            return;
          }
          final retry = await authService.dio.post(
            '/api/admin/orders/mark_placed',
            data: {
              if (reservationId != null && reservationId.isNotEmpty)
                'reservation_id': reservationId,
              if (cartItemId != null && cartItemId.isNotEmpty)
                'cart_item_id': cartItemId,
              'shelf_number': shelfToSend,
            },
          );
          if ((retry.statusCode == 200 || retry.statusCode == 201) && mounted) {
            setState(() {
              if (cartItemId != null && cartItemId.isNotEmpty) {
                _placedCartItemIds.add(cartItemId);
              }
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Готово. Полка: $shelfToSend')),
            );
          }
          return;
        }
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: ${_extractDioError(e)}')));
    } finally {
      if (mounted) setState(() => _markingPlaced = false);
    }
  }

  Map<String, dynamic> _metaMapOf(dynamic rawMeta) {
    if (rawMeta is Map) {
      return Map<String, dynamic>.from(rawMeta);
    }
    if (rawMeta is String && rawMeta.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  bool _messageMatchesSearch(Map<String, dynamic> message, String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    final text = (message['text'] ?? '').toString().toLowerCase();
    final meta = _metaMapOf(message['meta']);
    final blobs = [
      text,
      (meta['title'] ?? '').toString().toLowerCase(),
      (meta['description'] ?? '').toString().toLowerCase(),
      (meta['client_name'] ?? '').toString().toLowerCase(),
      (meta['product_code'] ?? '').toString().toLowerCase(),
      (meta['client_phone'] ?? '').toString().toLowerCase(),
    ];
    return blobs.any((x) => x.contains(q));
  }

  List<Map<String, dynamic>> _visibleMessages() {
    final filtered =
        _messages.where((m) => _messageMatchesSearch(m, _searchQuery)).toList()
          ..sort(_compareByCreatedAt);
    return filtered;
  }

  List<Map<String, dynamic>> _buildTimeline(
    List<Map<String, dynamic>> messages,
  ) {
    final items = <Map<String, dynamic>>[];
    String? prevDate;
    for (final message in messages) {
      final d = _parseDate(message['created_at']);
      final dateLabel = d == null ? 'Без даты' : _formatDateLabel(d);
      if (dateLabel != prevDate) {
        items.add({'type': 'date', 'label': dateLabel});
        prevDate = dateLabel;
      }
      items.add({'type': 'message', 'data': message});
    }
    return items;
  }

  Map<String, String> _extractCatalogTexts(String text) {
    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    String title = 'Товар';
    String description = '';
    if (lines.isNotEmpty) {
      title = lines.first.replaceFirst(RegExp(r'^🛒\s*'), '').trim();
      if (title.isEmpty) title = 'Товар';
    }

    if (lines.length > 1) {
      final candidate = lines[1];
      if (!candidate.toLowerCase().startsWith('id товара:') &&
          !candidate.toLowerCase().startsWith('цена:') &&
          !candidate.toLowerCase().startsWith('количество')) {
        description = candidate;
      }
    }

    return {'title': title, 'description': description};
  }

  Widget _catalogMetaBadge(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  String? _resolveImageUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    final base = authService.dio.options.baseUrl.trim();
    if (base.isEmpty) {
      return value;
    }
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  String _senderNameOf(Map<String, dynamic> message) {
    final fromMe =
        (message['from_me'] == true) ||
        (message['sender_id'] == authService.currentUser?.id);
    if (fromMe) return 'Вы';

    final senderName = (message['sender_name'] ?? '').toString().trim();
    if (senderName.isNotEmpty) return senderName;

    final senderEmail = (message['sender_email'] ?? '').toString().trim();
    if (senderEmail.isNotEmpty) return senderEmail;

    final meta = _metaMapOf(message['meta']);
    final processedByName = (meta['processed_by_name'] ?? '').toString().trim();
    if (processedByName.isNotEmpty) return processedByName;

    return 'Система';
  }

  String? _senderAvatarUrlOf(Map<String, dynamic> message) {
    return _resolveImageUrl((message['sender_avatar_url'] ?? '').toString());
  }

  double _senderAvatarFocusXOf(Map<String, dynamic> message) {
    final value = double.tryParse('${message['sender_avatar_focus_x'] ?? ''}');
    if (value == null || !value.isFinite) return 0;
    return value.clamp(-1.0, 1.0);
  }

  double _senderAvatarFocusYOf(Map<String, dynamic> message) {
    final value = double.tryParse('${message['sender_avatar_focus_y'] ?? ''}');
    if (value == null || !value.isFinite) return 0;
    return value.clamp(-1.0, 1.0);
  }

  double _senderAvatarZoomOf(Map<String, dynamic> message) {
    final value = double.tryParse('${message['sender_avatar_zoom'] ?? ''}');
    if (value == null || !value.isFinite) return 1;
    return value.clamp(1.0, 4.0);
  }

  Future<void> _editMessage(Map<String, dynamic> message) async {
    final current = (message['text'] ?? '').toString();
    final controller = TextEditingController(text: current);
    final nextText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Изменить сообщение'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (nextText == null || nextText.isEmpty || nextText == current.trim()) {
      return;
    }

    try {
      final messageId = message['id']?.toString() ?? '';
      final resp = await authService.dio.patch(
        '/api/chats/${widget.chatId}/messages/$messageId',
        data: {'text': nextText},
      );
      if (resp.data is Map && (resp.data as Map)['data'] is Map) {
        _upsertMessage(Map<String, dynamic>.from((resp.data as Map)['data']));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка редактирования: ${_extractDioError(e)}'),
        ),
      );
    }
  }

  Future<void> _deleteMessage(
    Map<String, dynamic> message, {
    required bool forAll,
  }) async {
    final actionLabel = forAll ? 'Удалить у всех' : 'Удалить у меня';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(actionLabel),
        content: Text(
          forAll
              ? 'Сообщение будет удалено у всех участников.'
              : 'Сообщение будет скрыто только у вас.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final messageId = message['id']?.toString() ?? '';
      if (messageId.isEmpty) return;
      final resp = await authService.dio.delete(
        '/api/chats/${widget.chatId}/messages/$messageId',
        data: {'scope': forAll ? 'all' : 'me'},
      );
      if (!forAll) {
        _removeMessageLocally(messageId);
      } else if (resp.data is Map && (resp.data as Map)['data'] is Map) {
        final payload = Map<String, dynamic>.from((resp.data as Map)['data']);
        final removedId = payload['message_id']?.toString() ?? messageId;
        _removeMessageLocally(removedId);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка удаления: ${_extractDioError(e)}')),
      );
    }
  }

  void _replyToMessage(String text) {
    final snippet = text.trim().replaceAll('\n', ' ');
    if (snippet.isEmpty) return;
    final bounded = snippet.length > 120
        ? '${snippet.substring(0, 120)}…'
        : snippet;
    final prefix = '↪ $bounded\n';
    final old = _controller.text;
    _controller.text = old.isEmpty ? prefix : '$old\n$prefix';
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    _inputFocusNode.requestFocus();
    _scrollToBottom(animated: true);
  }

  Future<void> _showMessageActions(
    Map<String, dynamic> message, {
    TapDownDetails? secondaryTap,
    required bool canEdit,
    required bool canDeleteForMe,
    required bool canDeleteForAll,
    required bool canReply,
    required bool canCopy,
  }) async {
    final text = (message['text'] ?? '').toString();

    Future<void> applyAction(String action) async {
      if (action == 'copy') {
        await _copyText(text);
      } else if (action == 'reply') {
        _replyToMessage(text);
      } else if (action == 'edit') {
        await _editMessage(message);
      } else if (action == 'delete_me') {
        await _deleteMessage(message, forAll: false);
      } else if (action == 'delete_all') {
        await _deleteMessage(message, forAll: true);
      } else if (action == 'copy_id') {
        final id = message['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          await _copyText(id);
        }
      }
    }

    final options = <PopupMenuEntry<String>>[];
    if (canCopy) {
      options.add(
        const PopupMenuItem(value: 'copy', child: Text('Копировать')),
      );
    }
    if (canReply) {
      options.add(const PopupMenuItem(value: 'reply', child: Text('Ответить')));
    }
    options.add(
      const PopupMenuItem(value: 'copy_id', child: Text('Копировать ID')),
    );
    if (canEdit) {
      options.add(const PopupMenuItem(value: 'edit', child: Text('Изменить')));
    }
    if (canDeleteForMe) {
      options.add(
        const PopupMenuItem(value: 'delete_me', child: Text('Удалить у меня')),
      );
    }
    if (canDeleteForAll) {
      options.add(
        const PopupMenuItem(value: 'delete_all', child: Text('Удалить у всех')),
      );
    }
    if (options.isEmpty) return;

    if (secondaryTap != null) {
      final selected = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          secondaryTap.globalPosition.dx,
          secondaryTap.globalPosition.dy,
          secondaryTap.globalPosition.dx,
          secondaryTap.globalPosition.dy,
        ),
        items: options,
      );
      if (selected != null) {
        await applyAction(selected);
      }
      return;
    }

    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: const Text('Копировать'),
                onTap: () => Navigator.of(ctx).pop('copy'),
              ),
            if (canReply)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Ответить'),
                onTap: () => Navigator.of(ctx).pop('reply'),
              ),
            ListTile(
              leading: const Icon(Icons.tag_outlined),
              title: const Text('Копировать ID'),
              onTap: () => Navigator.of(ctx).pop('copy_id'),
            ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить'),
                onTap: () => Navigator.of(ctx).pop('edit'),
              ),
            if (canDeleteForMe)
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('Удалить у меня'),
                onTap: () => Navigator.of(ctx).pop('delete_me'),
              ),
            if (canDeleteForAll)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  'Удалить у всех',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.of(ctx).pop('delete_all'),
              ),
          ],
        ),
      ),
    );

    if (selected != null) {
      await applyAction(selected);
    }
  }

  Widget _buildDateDivider(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> message) {
    final theme = Theme.of(context);
    final fromMe =
        (message['from_me'] == true) ||
        (message['sender_id'] == authService.currentUser?.id);
    final messageId = message['id']?.toString().trim() ?? '';
    final hasMessageId = messageId.isNotEmpty;
    final text = message['text']?.toString() ?? '';
    final metaMap = _metaMapOf(message['meta']);
    final isDeleted = metaMap['deleted'] == true;

    final isReservedOrder = !isDeleted && _isReservedOrder(message);
    final hasBuy = !isDeleted && !isReservedOrder && _isCatalogProduct(message);
    final imageUrl = _resolveImageUrl(metaMap['image_url']?.toString());
    final catalogTexts = _extractCatalogTexts(text);
    final productCode = metaMap['product_code']?.toString() ?? '—';
    final price = metaMap['price']?.toString() ?? '—';
    final quantity = metaMap['quantity']?.toString() ?? '—';
    final quantityInt = int.tryParse(quantity) ?? 0;
    final cartItemId = metaMap['cart_item_id']?.toString() ?? '';
    final isPlaced =
        metaMap['placed'] == true ||
        (cartItemId.isNotEmpty && _placedCartItemIds.contains(cartItemId));
    final shelf = metaMap['shelf_number']?.toString() ?? 'не назначена';
    final reservedDescription = metaMap['description']?.toString().trim() ?? '';
    final clientName = metaMap['client_name']?.toString() ?? '—';
    final clientPhone = metaMap['client_phone']?.toString() ?? '—';
    final processedByName =
        metaMap['processed_by_name']?.toString().trim() ?? '';
    final senderName = _senderNameOf(message);
    final senderAvatarUrl = _senderAvatarUrlOf(message);
    final senderAvatarFocusX = _senderAvatarFocusXOf(message);
    final senderAvatarFocusY = _senderAvatarFocusYOf(message);
    final senderAvatarZoom = _senderAvatarZoomOf(message);

    final bubbleColor = hasBuy
        ? Colors.white
        : isReservedOrder
        ? (isPlaced ? const Color(0xFFE7F5EA) : const Color(0xFFE8EAED))
        : (fromMe
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest);
    final textColor = (!hasBuy && !isReservedOrder && fromMe)
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    final isPlainMessage = !hasBuy && !isReservedOrder;
    final isCreator = _isCreatorRole();
    final canEdit = isPlainMessage && fromMe && !isDeleted;
    final canDeleteForMe = hasMessageId && (isCreator || !isDeleted);
    final canDeleteForAll =
        hasMessageId &&
        (isCreator ||
            (!isDeleted &&
                ((isPlainMessage && (fromMe || _isAdminOrCreator())) ||
                    ((hasBuy || isReservedOrder) && _isAdminOrCreator()))));
    final canReply = isPlainMessage && text.trim().isNotEmpty && !isDeleted;
    final canCopy = text.trim().isNotEmpty;
    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.72;

    final edited = metaMap['edited'] == true;

    final bubble = GestureDetector(
      onSecondaryTapDown: (details) => _showMessageActions(
        message,
        secondaryTap: details,
        canEdit: canEdit,
        canDeleteForMe: canDeleteForMe,
        canDeleteForAll: canDeleteForAll,
        canReply: canReply,
        canCopy: canCopy,
      ),
      onLongPress: () => _showMessageActions(
        message,
        canEdit: canEdit,
        canDeleteForMe: canDeleteForMe,
        canDeleteForAll: canDeleteForAll,
        canReply: canReply,
        canCopy: canCopy,
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        constraints: BoxConstraints(
          maxWidth: maxBubbleWidth > 620 ? 620 : maxBubbleWidth,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bubbleColor,
          border: Border.all(
            color: hasBuy || isReservedOrder
                ? theme.colorScheme.outlineVariant
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              senderName,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (imageUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 240,
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, error, stackTrace) => Container(
                        color: Colors.grey[200],
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (hasBuy) ...[
              Text(
                catalogTexts['title'] ?? 'Товар',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              if ((catalogTexts['description'] ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  catalogTexts['description'] ?? '',
                  style: TextStyle(color: Colors.grey[700], fontSize: 13),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _catalogMetaBadge('ID', productCode),
                  _catalogMetaBadge('Цена', '$price RUB'),
                  _catalogMetaBadge('В наличии', quantity),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.shopping_cart_checkout_outlined),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: (_buyLoading || quantityInt <= 0)
                      ? null
                      : () => _buyProduct(metaMap),
                  label: Text(
                    quantityInt <= 0
                        ? 'Нет в наличии'
                        : (_buyLoading ? 'Добавление...' : 'Купить'),
                  ),
                ),
              ),
            ] else if (isReservedOrder) ...[
              Text(
                metaMap['title']?.toString().isNotEmpty == true
                    ? metaMap['title'].toString()
                    : catalogTexts['title'] ?? 'Заказ',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              if (reservedDescription.isNotEmpty) ...[
                Text(
                  reservedDescription,
                  style: TextStyle(color: Colors.grey[700], fontSize: 13),
                ),
                const SizedBox(height: 6),
              ],
              Text('Покупатель: $clientName'),
              Text('Телефон: $clientPhone'),
              Text('Статус: ${isPlaced ? 'Обработано' : 'Ожидание обработки'}'),
              if (isPlaced)
                Text(
                  'Кто обработал: ${processedByName.isNotEmpty ? processedByName : '—'}',
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _catalogMetaBadge('ID', productCode),
                  _catalogMetaBadge('Цена', '$price RUB'),
                  _catalogMetaBadge('Куплено', quantity),
                  _catalogMetaBadge('Полка', shelf),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.inventory_2_outlined),
                  onPressed:
                      (!_isAdminOrCreator() || isPlaced || _markingPlaced)
                      ? null
                      : () => _markReservedOrderPlaced(metaMap),
                  label: Text(
                    isPlaced
                        ? 'Обработано'
                        : (_markingPlaced ? 'Сохранение...' : 'Положил'),
                  ),
                ),
              ),
            ] else ...[
              Text(
                text,
                style: TextStyle(
                  color: isDeleted ? Colors.grey[700] : textColor,
                  fontStyle: isDeleted ? FontStyle.italic : FontStyle.normal,
                ),
              ),
              if (edited && !isDeleted)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'изменено',
                    style: TextStyle(
                      color: fromMe
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment: fromMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!fromMe) ...[
            AppAvatar(
              title: senderName,
              imageUrl: senderAvatarUrl,
              focusX: senderAvatarFocusX,
              focusY: senderAvatarFocusY,
              zoom: senderAvatarZoom,
              radius: 18,
            ),
            const SizedBox(width: 10),
          ],
          Flexible(child: bubble),
          if (fromMe) ...[
            const SizedBox(width: 10),
            AppAvatar(
              title: senderName,
              imageUrl: senderAvatarUrl,
              focusX: senderAvatarFocusX,
              focusY: senderAvatarFocusY,
              zoom: senderAvatarZoom,
              radius: 18,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canCompose = _canCompose();
    final blockedReason = _composeBlockedReason();
    final visibleMessages = _visibleMessages();
    final timeline = _buildTimeline(visibleMessages);

    return Scaffold(
      appBar: AppBar(
        title: _searchMode
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Поиск по чату',
                  border: InputBorder.none,
                ),
              )
            : Text(widget.chatTitle),
        actions: [
          IconButton(
            icon: Icon(_searchMode ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                if (_searchMode) {
                  _searchController.clear();
                  _searchQuery = '';
                }
                _searchMode = !_searchMode;
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : timeline.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isEmpty
                          ? 'Нет сообщений'
                          : 'Ничего не найдено',
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: timeline.length,
                    itemBuilder: (context, i) {
                      final row = timeline[i];
                      if (row['type'] == 'date') {
                        return _buildDateDivider(
                          (row['label'] ?? 'Без даты').toString(),
                        );
                      }
                      final message = Map<String, dynamic>.from(
                        row['data'] as Map,
                      );
                      return _buildMessageItem(message);
                    },
                  ),
          ),
          if (blockedReason != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                blockedReason,
                style: TextStyle(color: Colors.grey[700], fontSize: 12),
              ),
            ),
          SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Focus(
                      onKeyEvent: _onInputKey,
                      child: TextField(
                        focusNode: _inputFocusNode,
                        controller: _controller,
                        enabled: canCompose,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: canCompose
                              ? 'Сообщение...'
                              : 'Отправка сообщений недоступна',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: canCompose ? _send : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
