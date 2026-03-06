// lib/screens/chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../main.dart';
import '../utils/date_time_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/submit_on_enter.dart';

class _ChatUploadFile {
  const _ChatUploadFile({required this.filename, this.path, this.bytes});

  final String filename;
  final String? path;
  final Uint8List? bytes;
}

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
  final ImagePicker _imagePicker = ImagePicker();
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final AudioPlayer _voicePlayer = AudioPlayer();

  List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _incomingQueue = [];
  final Set<String> _appearingMessageIds = {};

  bool _loading = true;
  bool _buyLoading = false;
  bool _mediaUploading = false;
  bool _markingPlaced = false;
  bool _searchMode = false;
  bool _voiceRecording = false;
  bool _voiceSending = false;
  bool _pinLoading = false;

  String _searchQuery = '';
  int _recordingSeconds = 0;
  String? _activeVoiceMessageId;
  Duration _activeVoicePosition = Duration.zero;
  Duration _activeVoiceDuration = Duration.zero;
  PlayerState _voicePlayerState = PlayerState.stopped;

  StreamSubscription? _chatSub;
  Timer? _incomingTimer;
  Timer? _readDebounceTimer;
  Timer? _voiceRecordingTimer;
  StreamSubscription<Duration>? _voicePositionSub;
  StreamSubscription<Duration>? _voiceDurationSub;
  StreamSubscription<PlayerState>? _voiceStateSub;
  StreamSubscription<void>? _voiceCompleteSub;

  final Set<String> _messageIds = {};
  final Set<String> _placedCartItemIds = {};
  final Set<String> _supportFeedbackBusyTicketIds = {};
  Map<String, dynamic>? _activePin;

  @override
  void initState() {
    super.initState();
    activeChatIdNotifier.value = widget.chatId;
    _loadMessages();
    _loadPinnedMessage();
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

    _voicePositionSub = _voicePlayer.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _activeVoicePosition = position);
    });
    _voiceDurationSub = _voicePlayer.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _activeVoiceDuration = duration);
    });
    _voiceStateSub = _voicePlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _voicePlayerState = state);
    });
    _voiceCompleteSub = _voicePlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _activeVoiceMessageId = null;
        _activeVoicePosition = Duration.zero;
        _voicePlayerState = PlayerState.completed;
      });
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
        return;
      }
      if (type == 'chat:cleared' && data is Map) {
        final chatId = data['chatId']?.toString() ?? '';
        if (chatId != widget.chatId) return;
        setState(() {
          _messages = [];
          _incomingQueue.clear();
          _messageIds.clear();
          _appearingMessageIds.clear();
        });
        return;
      }
      if (type == 'chat:message:read' && data is Map) {
        final chatId = data['chatId']?.toString() ?? '';
        if (chatId != widget.chatId) return;
        final readerId = data['readerId']?.toString() ?? '';
        final messageIds = (data['messageIds'] is List)
            ? (data['messageIds'] as List)
                  .map((e) => e?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .toSet()
            : <String>{};
        if (messageIds.isEmpty) return;
        _applyReadState(
          messageIds,
          readByMe: readerId == authService.currentUser?.id,
          readByOthers: readerId != authService.currentUser?.id,
        );
        return;
      }
      if (type == 'chat:pinned' && data is Map) {
        final chatId = data['chatId']?.toString() ?? '';
        if (chatId != widget.chatId) return;
        final pinRaw = data['pin'];
        if (pinRaw is Map) {
          setState(() => _activePin = Map<String, dynamic>.from(pinRaw));
        } else {
          setState(() => _activePin = null);
        }
      }
    });
  }

  @override
  void dispose() {
    if (activeChatIdNotifier.value == widget.chatId) {
      activeChatIdNotifier.value = null;
    }
    _incomingTimer?.cancel();
    _readDebounceTimer?.cancel();
    _voiceRecordingTimer?.cancel();
    _chatSub?.cancel();
    _voicePositionSub?.cancel();
    _voiceDurationSub?.cancel();
    _voiceStateSub?.cancel();
    _voiceCompleteSub?.cancel();
    _leaveRoom();

    unawaited(_voicePlayer.stop());
    unawaited(_voicePlayer.dispose());
    if (_voiceRecording) {
      unawaited(_voiceRecorder.stop());
    }
    unawaited(_voiceRecorder.dispose());

    _controller.dispose();
    _searchController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  DateTime? _parseDate(dynamic raw) {
    return parseDateTimeValue(raw);
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

  String _formatMessageTime(dynamic raw) {
    return formatDateTimeValue(raw);
  }

  String _generateClientMessageId() {
    final random = Random.secure();
    String hex(int length) => List.generate(
      length,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + random.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  bool _isOwnMessage(Map<String, dynamic> message) {
    final currentUserId = authService.currentUser?.id.trim() ?? '';
    if (currentUserId.isEmpty) return message['from_me'] == true;
    return (message['sender_id']?.toString().trim() ?? '') == currentUserId;
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

  Map<String, dynamic> _normalizeMessage(Map<String, dynamic> message) {
    final normalized = Map<String, dynamic>.from(message);
    final meta = _metaMapOf(normalized['meta']);
    final fromMe = _isOwnMessage(normalized);
    final localOnly = meta['local_only'] == true;
    if (fromMe && !localOnly) {
      meta['delivery_status'] = normalized['read_by_others'] == true
          ? 'read'
          : 'sent';
    }
    normalized['meta'] = meta;
    return normalized;
  }

  void _upsertMessage(Map<String, dynamic> msg, {bool autoScroll = false}) {
    final normalized = _normalizeMessage(msg);
    final msgId = normalized['id']?.toString();
    final clientMsgId = normalized['client_msg_id']?.toString() ?? '';
    final meta = _metaMapOf(normalized['meta']);
    final localOnly = meta['local_only'] == true;
    var inserted = false;
    setState(() {
      if (msgId == null || msgId.isEmpty) {
        inserted = true;
        _messages = [..._messages, normalized]..sort(_compareByCreatedAt);
      } else {
        var index = _messages.indexWhere((m) => m['id']?.toString() == msgId);
        if (index < 0 && clientMsgId.isNotEmpty) {
          index = _messages.indexWhere(
            (m) => (m['client_msg_id']?.toString() ?? '') == clientMsgId,
          );
        }
        if (index >= 0) {
          final previousId = _messages[index]['id']?.toString();
          _messages[index] = {..._messages[index], ...normalized};
          if (previousId != null &&
              previousId.isNotEmpty &&
              previousId != msgId &&
              previousId.startsWith('temp-')) {
            _messageIds.remove(previousId);
          }
        } else {
          inserted = true;
          _messages = [..._messages, normalized];
        }
        _messages.sort(_compareByCreatedAt);
        if (!localOnly) {
          _messageIds.add(msgId);
        }
      }
    });

    if (inserted && msgId != null && msgId.isNotEmpty) {
      _markMessageAppearing(msgId);
    }

    if (autoScroll) {
      _scrollToBottom(animated: true);
    }
  }

  void _updateCatalogProductLocally(
    String productId, {
    required int quantity,
    String? price,
    String? title,
    String? description,
    String? imageUrl,
  }) {
    if (productId.trim().isEmpty) return;
    setState(() {
      _messages = _messages.map((message) {
        final meta = _metaMapOf(message['meta']);
        final kind = meta['kind']?.toString() ?? '';
        final currentProductId = meta['product_id']?.toString() ?? '';
        if (kind != 'catalog_product' || currentProductId != productId) {
          return message;
        }

        final nextMeta = Map<String, dynamic>.from(meta)
          ..['quantity'] = quantity;
        if (price != null && price.trim().isNotEmpty) {
          nextMeta['price'] = price;
        }
        if (imageUrl != null && imageUrl.trim().isNotEmpty) {
          nextMeta['image_url'] = imageUrl;
        }

        return {
          ...message,
          if (title != null && title.trim().isNotEmpty) 'text': message['text'],
          'meta': nextMeta,
        };
      }).toList();
    });
  }

  void _removeMessageLocally(String messageId) {
    setState(() {
      _messages = _messages
          .where((m) => m['id']?.toString() != messageId)
          .toList();
      _incomingQueue.removeWhere((m) => m['id']?.toString() == messageId);
      _messageIds.remove(messageId);
      _appearingMessageIds.remove(messageId);
    });
  }

  void _markMessageAppearing(String messageId) {
    if (messageId.isEmpty) return;
    setState(() => _appearingMessageIds.add(messageId));
    Future.delayed(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      setState(() => _appearingMessageIds.remove(messageId));
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
    final fromMe = _isOwnMessage(msg);
    final shouldScroll = _isNearBottom() || fromMe;
    _upsertMessage(msg, autoScroll: shouldScroll);
    if (!fromMe) {
      _scheduleReadSync();
    }

    if (_incomingQueue.isEmpty) {
      _incomingTimer?.cancel();
      _incomingTimer = null;
    }
  }

  void _applyReadState(
    Set<String> messageIds, {
    bool readByMe = false,
    bool readByOthers = false,
  }) {
    if (messageIds.isEmpty) return;
    setState(() {
      _messages = _messages.map((message) {
        final id = message['id']?.toString() ?? '';
        if (!messageIds.contains(id)) return message;
        final updated = Map<String, dynamic>.from(message);
        final meta = _metaMapOf(updated['meta']);
        if (readByMe) {
          updated['is_read_by_me'] = true;
        }
        if (readByOthers) {
          updated['read_by_others'] = true;
          meta['delivery_status'] = 'read';
          final currentReadCount =
              int.tryParse('${updated['read_count'] ?? 0}') ?? 0;
          updated['read_count'] = currentReadCount + 1;
        }
        updated['meta'] = meta;
        return updated;
      }).toList();
    });
  }

  void _scheduleReadSync() {
    _readDebounceTimer?.cancel();
    _readDebounceTimer = Timer(const Duration(milliseconds: 220), () {
      unawaited(_markChatAsRead());
    });
  }

  bool _canPinMessages() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin' || role == 'tenant' || role == 'creator';
  }

  Future<void> _loadPinnedMessage() async {
    if (_pinLoading) return;
    _pinLoading = true;
    try {
      final resp = await authService.dio.get('/api/chats/${widget.chatId}/pin');
      final data = resp.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true) {
        final raw = data['data'];
        setState(() {
          _activePin = raw is Map ? Map<String, dynamic>.from(raw) : null;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _activePin = null);
    } finally {
      _pinLoading = false;
    }
  }

  Future<void> _pinMessage(String messageId) async {
    if (!_canPinMessages() || messageId.trim().isEmpty) return;
    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/pin/$messageId',
      );
      final data = resp.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true) {
        final raw = data['data'];
        setState(() {
          _activePin = raw is Map ? Map<String, dynamic>.from(raw) : null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка закрепления: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _unpinMessage() async {
    if (!_canPinMessages()) return;
    try {
      await authService.dio.delete('/api/chats/${widget.chatId}/pin');
      if (!mounted) return;
      setState(() => _activePin = null);
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка открепления: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  String _pinPreviewText() {
    final pin = _activePin;
    if (pin == null) return '';
    final messageRaw = pin['message'];
    if (messageRaw is Map) {
      final message = Map<String, dynamic>.from(messageRaw);
      final text = (message['text'] ?? '').toString().trim();
      if (text.isNotEmpty) return text;
      final meta = _metaMapOf(message['meta']);
      final title = (meta['title'] ?? '').toString().trim();
      if (title.isNotEmpty) return title;
      if ((meta['image_url'] ?? '').toString().trim().isNotEmpty) return 'Фото';
      if ((meta['voice_url'] ?? '').toString().trim().isNotEmpty) {
        return 'Голосовое сообщение';
      }
    }
    return 'Закрепленное сообщение';
  }

  bool _isMessagePinned(String messageId) {
    final pin = _activePin;
    if (pin == null) return false;
    return (pin['message_id'] ?? '').toString() == messageId;
  }

  Future<void> _markChatAsRead() async {
    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/read',
      );
      final data = resp.data;
      if (data is Map && data['data'] is Map) {
        final ids = ((data['data']['message_ids'] ?? const []) as List)
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toSet();
        _applyReadState(ids, readByMe: true);
      }
    } catch (_) {}
  }

  void _enqueueIncomingMessage(Map<String, dynamic> msg) {
    if (_isHiddenForAll(msg)) {
      final messageId = msg['id']?.toString() ?? '';
      if (messageId.isNotEmpty) {
        _removeMessageLocally(messageId);
      }
      return;
    }

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

  bool _isHiddenForAll(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final raw = meta['hidden_for_all'];
    if (raw is bool) return raw;
    final normalized = raw?.toString().toLowerCase().trim() ?? '';
    return normalized == 'true' || normalized == '1';
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
    final role = authService.effectiveRole.toLowerCase().trim();
    if (role == 'client') {
      if (_isPublicChannel()) return false;
      if ((widget.chatType ?? '').toLowerCase().trim() == 'channel') {
        return false;
      }
      return true;
    }
    if (_isPublicChannel()) {
      return role == 'admin' || role == 'tenant' || role == 'creator';
    }
    return true;
  }

  String? _composeBlockedReason() {
    if (_canCompose()) return null;
    if (_isPublicChannel()) {
      return 'В этом публичном канале писать может только администрация';
    }
    return 'В этом чате отправка сообщений недоступна';
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
          _appearingMessageIds.clear();
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
        _scheduleReadSync();
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
    showAppNotice(
      context,
      'Текст скопирован',
      tone: AppNoticeTone.success,
      duration: const Duration(milliseconds: 1100),
    );
  }

  void _openImagePreview(String imageUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.7,
              maxScale: 4,
              child: AspectRatio(
                aspectRatio: 1,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, error, stackTrace) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined, size: 40),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _cameraSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get _preferFilePickerForImages {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<MultipartFile> _multipartFromUpload(_ChatUploadFile file) async {
    if (!kIsWeb && file.path != null && file.path!.trim().isNotEmpty) {
      return MultipartFile.fromFile(file.path!, filename: file.filename);
    }
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Не удалось прочитать файл');
    }
    return MultipartFile.fromBytes(bytes, filename: file.filename);
  }

  Future<_ChatUploadFile?> _pickImageUpload(ImageSource source) async {
    if (source == ImageSource.gallery && _preferFilePickerForImages) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: kIsWeb,
      );
      final picked = result?.files.single;
      if (picked == null) return null;
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null || bytes.isEmpty) return null;
        return _ChatUploadFile(
          filename: picked.name.isNotEmpty ? picked.name : 'image.jpg',
          bytes: bytes,
        );
      }
      final path = picked.path;
      if (path == null || path.trim().isEmpty) return null;
      return _ChatUploadFile(
        filename: picked.name.isNotEmpty ? picked.name : path.split('/').last,
        path: path,
      );
    }

    final picked = await _imagePicker.pickImage(
      source: source,
      imageQuality: 88,
      maxWidth: 2200,
    );
    if (picked == null) return null;
    if (kIsWeb) {
      final bytes = await picked.readAsBytes();
      return _ChatUploadFile(
        filename: picked.name.isNotEmpty ? picked.name : 'image.jpg',
        bytes: bytes,
      );
    }
    return _ChatUploadFile(
      filename: picked.name.isNotEmpty
          ? picked.name
          : picked.path.split('/').last,
      path: picked.path,
    );
  }

  Future<_ChatUploadFile?> _pickVoiceUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
      withData: kIsWeb,
    );
    final picked = result?.files.single;
    if (picked == null) return null;
    if (kIsWeb) {
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) return null;
      return _ChatUploadFile(
        filename: picked.name.isNotEmpty ? picked.name : 'voice-message.webm',
        bytes: bytes,
      );
    }
    final path = picked.path;
    if (path == null || path.trim().isEmpty) return null;
    return _ChatUploadFile(
      filename: picked.name.isNotEmpty ? picked.name : path.split('/').last,
      path: path,
    );
  }

  Future<void> _sendMediaMessage({
    required _ChatUploadFile upload,
    required String attachmentType,
    int? durationMs,
  }) async {
    if (!_canCompose()) return;
    final clientMsgId = _generateClientMessageId();
    final caption = attachmentType == 'image' ? _controller.text.trim() : '';
    final previousText = _controller.text;
    setState(() {
      _mediaUploading = attachmentType == 'image';
      _voiceSending = attachmentType == 'voice';
    });
    try {
      final form = FormData.fromMap({
        if (attachmentType == 'image')
          'image': await _multipartFromUpload(upload),
        if (attachmentType == 'voice')
          'voice': await _multipartFromUpload(upload),
        'client_msg_id': clientMsgId,
        if (caption.isNotEmpty) 'text': caption,
        if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
      });
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/messages/media',
        data: form,
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          if (attachmentType == 'image') {
            _controller.clear();
          }
          _upsertMessage(
            Map<String, dynamic>.from(data['data']),
            autoScroll: true,
          );
          await playAppSound(AppUiSound.sent);
          return;
        }
      }
      throw Exception('Сервер не принял вложение');
    } catch (e) {
      if (!mounted) return;
      if (attachmentType == 'image') {
        _controller.text = previousText;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
      }
      showAppNotice(
        context,
        attachmentType == 'image'
            ? 'Не удалось отправить изображение'
            : 'Не удалось отправить голосовое сообщение',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('sendMediaMessage error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _mediaUploading = false;
          _voiceSending = false;
        });
      }
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    if (!_canCompose() || _mediaUploading || _voiceSending || _voiceRecording) {
      return;
    }
    try {
      final upload = await _pickImageUpload(source);
      if (upload == null) return;
      await _sendMediaMessage(upload: upload, attachmentType: 'image');
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось выбрать изображение',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('pickAndSendImage error: $e');
    }
  }

  Future<void> _openAttachmentSheet() async {
    if (!_canCompose() || _mediaUploading || _voiceSending || _voiceRecording) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_cameraSupported)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Сделать фото'),
                onTap: () {
                  Navigator.of(context).pop();
                  Future<void>.delayed(
                    const Duration(milliseconds: 120),
                    () => _pickAndSendImage(ImageSource.camera),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(
                _preferFilePickerForImages
                    ? 'Выбрать фото с устройства'
                    : 'Выбрать из галереи',
              ),
              onTap: () {
                Navigator.of(context).pop();
                Future<void>.delayed(
                  const Duration(milliseconds: 120),
                  () => _pickAndSendImage(ImageSource.gallery),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDurationLabel(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes < 10 ? '0$minutes' : '$minutes';
    final ss = seconds < 10 ? '0$seconds' : '$seconds';
    return '$mm:$ss';
  }

  Future<void> _startVoiceRecording() async {
    if (!_canCompose() || _voiceSending || _mediaUploading || _voiceRecording) {
      return;
    }
    try {
      final allowed = await _voiceRecorder.hasPermission();
      if (!allowed) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Нет доступа к микрофону',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
        return;
      }

      RecordConfig config;
      String? outputPath;
      if (kIsWeb) {
        final upload = await _pickVoiceUpload();
        if (upload == null) return;
        await _sendMediaMessage(upload: upload, attachmentType: 'voice');
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final useAac =
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS;
      final extension = useAac ? 'm4a' : 'wav';
      outputPath =
          '${tempDir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.$extension';
      config = RecordConfig(
        encoder: useAac ? AudioEncoder.aacLc : AudioEncoder.wav,
        bitRate: useAac ? 128000 : 1411200,
        sampleRate: 44100,
      );

      await _voiceRecorder.start(config, path: outputPath);
      _voiceRecordingTimer?.cancel();
      setState(() {
        _voiceRecording = true;
        _recordingSeconds = 0;
      });
      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordingSeconds += 1);
      });
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось начать запись',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('startVoiceRecording error: $e');
    }
  }

  Future<void> _stopVoiceRecordingAndSend() async {
    if (!_voiceRecording) return;
    final durationMs = _recordingSeconds * 1000;
    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;
    setState(() {
      _voiceRecording = false;
      _recordingSeconds = 0;
    });
    try {
      final recordedPath = await _voiceRecorder.stop();
      if (recordedPath == null || recordedPath.trim().isEmpty) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Запись не получена',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
        return;
      }
      await _sendMediaMessage(
        upload: _ChatUploadFile(
          filename: recordedPath.split('/').last,
          path: recordedPath,
        ),
        attachmentType: 'voice',
        durationMs: durationMs,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось отправить голосовое сообщение',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('stopVoiceRecordingAndSend error: $e');
    }
  }

  Future<void> _toggleVoiceComposerAction() async {
    if (kIsWeb) {
      if (_mediaUploading || _voiceSending) return;
      final upload = await _pickVoiceUpload();
      if (upload == null) return;
      await _sendMediaMessage(upload: upload, attachmentType: 'voice');
      return;
    }
    if (_voiceRecording) {
      await _stopVoiceRecordingAndSend();
      return;
    }
    await _startVoiceRecording();
  }

  Future<void> _toggleVoicePlayback(String messageId, String voiceUrl) async {
    if (messageId.isEmpty || voiceUrl.trim().isEmpty) return;
    try {
      final isCurrent = _activeVoiceMessageId == messageId;
      if (isCurrent && _voicePlayerState == PlayerState.playing) {
        await _voicePlayer.pause();
        return;
      }
      if (isCurrent && _voicePlayerState == PlayerState.paused) {
        await _voicePlayer.resume();
        return;
      }

      await _voicePlayer.stop();
      setState(() {
        _activeVoiceMessageId = messageId;
        _activeVoicePosition = Duration.zero;
        _activeVoiceDuration = Duration.zero;
      });
      await _voicePlayer.play(UrlSource(voiceUrl));
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось воспроизвести голосовое',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('toggleVoicePlayback error: $e');
    }
  }

  Future<void> _send() async {
    if (!_canCompose() || _mediaUploading || _voiceSending || _voiceRecording) {
      return;
    }

    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final currentUser = authService.currentUser;
    final clientMsgId = _generateClientMessageId();
    final optimisticMessage = <String, dynamic>{
      'id': 'temp-$clientMsgId',
      'client_msg_id': clientMsgId,
      'chat_id': widget.chatId,
      'sender_id': currentUser?.id,
      'sender_name': currentUser?.name?.trim().isNotEmpty == true
          ? currentUser!.name!.trim()
          : 'Вы',
      'text': text,
      'created_at': DateTime.now().toIso8601String(),
      'from_me': true,
      'read_by_others': false,
      'read_count': 0,
      'meta': {'delivery_status': 'sending', 'local_only': true},
    };
    _controller.clear();
    _upsertMessage(optimisticMessage, autoScroll: true);

    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/messages',
        data: {'text': text, 'client_msg_id': clientMsgId},
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          final msg = Map<String, dynamic>.from(data['data']);
          _upsertMessage(msg, autoScroll: true);
        } else {
          await _loadMessages();
        }
        await playAppSound(AppUiSound.sent);
      }
    } catch (e) {
      final failed = Map<String, dynamic>.from(optimisticMessage);
      failed['meta'] = {
        ..._metaMapOf(optimisticMessage['meta']),
        'delivery_status': 'error',
        'local_only': true,
      };
      _upsertMessage(failed, autoScroll: true);
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка отправки сообщения',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _buyProduct(Map<String, dynamic> meta) async {
    final productId = meta['product_id']?.toString();
    if (productId == null || productId.isEmpty) return;
    final inStock = int.tryParse((meta['quantity'] ?? '').toString()) ?? 0;
    if (inStock <= 0) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Товар закончился',
        tone: AppNoticeTone.warning,
        duration: const Duration(seconds: 2),
      );
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
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final payload = Map<String, dynamic>.from(data['data'] as Map);
          final product = payload['product'];
          if (product is Map) {
            final productMap = Map<String, dynamic>.from(product);
            final nextQuantity =
                int.tryParse('${productMap['quantity'] ?? 0}') ?? 0;
            _updateCatalogProductLocally(
              productId,
              quantity: nextQuantity,
              price: productMap['price']?.toString(),
              title: productMap['title']?.toString(),
              description: productMap['description']?.toString(),
              imageUrl: productMap['image_url']?.toString(),
            );
          }
        }
        showAppNotice(
          context,
          'Товар добавлен в корзину',
          tone: AppNoticeTone.success,
          duration: const Duration(milliseconds: 1300),
        );
        await playAppSound(AppUiSound.success);
      } else {
        showAppNotice(
          context,
          'Не удалось добавить товар в корзину',
          tone: AppNoticeTone.error,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка покупки: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
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

  bool _isDeliveryOffer(Map<String, dynamic> message) {
    final metaMap = _metaMapOf(message['meta']);
    return metaMap['kind']?.toString() == 'delivery_offer';
  }

  bool _isSupportFeedbackPrompt(Map<String, dynamic> message) {
    final metaMap = _metaMapOf(message['meta']);
    return metaMap['kind']?.toString() == 'support_feedback_prompt';
  }

  bool _isAdminOrCreator() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin' || role == 'tenant' || role == 'creator';
  }

  bool _isClientRole() {
    return authService.effectiveRole.toLowerCase().trim() == 'client';
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
      builder: (ctx) {
        final width = MediaQuery.of(ctx).size.width;
        final dialogWidth = width < 420 ? width * 0.9 : 360.0;
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          title: const Text('Номер полки'),
          content: SizedBox(
            width: dialogWidth,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: withInputLanguageBadge(
                const InputDecoration(
                  hintText: 'Введите номер полки',
                  border: OutlineInputBorder(),
                ),
                controller: controller,
              ),
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
        );
      },
    );
    return result;
  }

  Future<void> _respondToDeliveryOffer(
    Map<String, dynamic> meta, {
    required bool accepted,
  }) async {
    final customerId = (meta['delivery_customer_id'] ?? '').toString().trim();
    if (customerId.isEmpty) return;

    String addressText = '';
    String preferredTimeFrom = '';
    String preferredTimeTo = '';
    if (accepted) {
      final addressCtrl = TextEditingController(
        text: (meta['address_text'] ?? '').toString(),
      );
      final afterCtrl = TextEditingController(
        text: (meta['preferred_time_from'] ?? '').toString(),
      );
      final beforeCtrl = TextEditingController(
        text: (meta['preferred_time_to'] ?? '').toString(),
      );
      final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Адрес доставки'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: addressCtrl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      hintText: 'Самара, улица, дом, подъезд',
                      border: OutlineInputBorder(),
                    ),
                    controller: addressCtrl,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: afterCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'После',
                            hintText: '10:00',
                            border: OutlineInputBorder(),
                          ),
                          controller: afterCtrl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: beforeCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'До',
                            hintText: '16:00',
                            border: OutlineInputBorder(),
                          ),
                          controller: beforeCtrl,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop({
                'address_text': addressCtrl.text.trim(),
                'preferred_time_from': afterCtrl.text.trim(),
                'preferred_time_to': beforeCtrl.text.trim(),
              }),
              child: const Text('Отправить'),
            ),
          ],
        ),
      );
      if (result == null || (result['address_text'] ?? '').trim().isEmpty) {
        return;
      }
      addressText = (result['address_text'] ?? '').trim();
      preferredTimeFrom = (result['preferred_time_from'] ?? '').trim();
      preferredTimeTo = (result['preferred_time_to'] ?? '').trim();
    }

    try {
      await authService.dio.post(
        '/api/delivery/offers/$customerId/respond',
        data: {
          'accepted': accepted,
          if (accepted) 'address_text': addressText,
          if (accepted && preferredTimeFrom.isNotEmpty)
            'preferred_time_from': preferredTimeFrom,
          if (accepted && preferredTimeTo.isNotEmpty)
            'preferred_time_to': preferredTimeTo,
        },
      );
      if (!mounted) return;
      showAppNotice(
        context,
        accepted ? 'Адрес доставки отправлен' : 'Отказ от доставки сохранен',
        tone: AppNoticeTone.success,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка доставки: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _respondToSupportFeedback(
    Map<String, dynamic> meta, {
    required bool resolved,
  }) async {
    final ticketId = (meta['support_ticket_id'] ?? '').toString().trim();
    if (ticketId.isEmpty) return;
    if (_supportFeedbackBusyTicketIds.contains(ticketId)) return;

    setState(() => _supportFeedbackBusyTicketIds.add(ticketId));
    try {
      await authService.dio.post(
        '/api/support/tickets/$ticketId/feedback',
        data: {'resolved': resolved},
      );
      if (!mounted) return;
      showAppNotice(
        context,
        resolved ? 'Вопрос закрыт и отправлен в архив' : 'Вопрос снова открыт',
        tone: AppNoticeTone.success,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка поддержки: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
    } finally {
      if (mounted) {
        setState(() => _supportFeedbackBusyTicketIds.remove(ticketId));
      } else {
        _supportFeedbackBusyTicketIds.remove(ticketId);
      }
    }
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
        showAppNotice(
          context,
          'Товар отмечен как обработанный',
          tone: AppNoticeTone.success,
          duration: const Duration(milliseconds: 1300),
        );
        await playAppSound(AppUiSound.success);
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
            showAppNotice(
              context,
              'Готово. Полка: $shelfToSend',
              tone: AppNoticeTone.success,
            );
            await playAppSound(AppUiSound.success);
          }
          return;
        }
      } catch (_) {}
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
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

  Widget _catalogMetaBadge(
    ThemeData theme,
    String label,
    String value, {
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: foregroundColor ?? theme.colorScheme.onSecondaryContainer,
        ),
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

  String _attachmentTypeOf(Map<String, dynamic> meta) {
    return (meta['attachment_type'] ?? '').toString().trim().toLowerCase();
  }

  String _captionTextOf(
    Map<String, dynamic> message,
    Map<String, dynamic> meta,
  ) {
    final caption = (meta['caption'] ?? '').toString().trim();
    if (caption.isNotEmpty) return caption;
    final text = (message['text'] ?? '').toString().trim();
    if (text.toLowerCase() == 'фото' ||
        text.toLowerCase() == 'голосовое сообщение') {
      return '';
    }
    return text;
  }

  String? _voiceUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(meta['voice_url']?.toString());
  }

  int _voiceDurationMsOf(Map<String, dynamic> meta) {
    return int.tryParse('${meta['voice_duration_ms'] ?? 0}') ?? 0;
  }

  String _senderNameOf(Map<String, dynamic> message) {
    final fromMe = _isOwnMessage(message);
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

  String _deliveryStatusOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final forced = (meta['delivery_status'] ?? '').toString().trim();
    if (forced.isNotEmpty) return forced;
    if (message['read_by_others'] == true) return 'read';
    return 'sent';
  }

  Widget _buildDeliveryStatusIcon(
    ThemeData theme,
    String status, {
    required bool fromMe,
  }) {
    if (!fromMe) return const SizedBox.shrink();

    final (icon, color) = switch (status) {
      'sending' => (
        Icons.schedule_rounded,
        theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.78),
      ),
      'read' => (Icons.done_all_rounded, theme.colorScheme.primary),
      'error' => (Icons.error_outline_rounded, theme.colorScheme.error),
      _ => (
        Icons.done_rounded,
        theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.86),
      ),
    };

    return Icon(icon, size: 16, color: color);
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
          decoration: withInputLanguageBadge(
            const InputDecoration(border: OutlineInputBorder()),
            controller: controller,
          ),
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
      showAppNotice(
        context,
        'Ошибка редактирования: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
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
      showAppNotice(
        context,
        'Ошибка удаления: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _deleteAllMessagesInChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('УДАЛИТЬ ВСЁ!'),
        content: Text(
          'Будут удалены все сообщения в чате "${widget.chatTitle}". Это действие необратимо.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'УДАЛИТЬ ВСЁ!',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await authService.dio.delete('/api/chats/${widget.chatId}/messages');
      if (!mounted) return;
      setState(() {
        _messages = [];
        _incomingQueue.clear();
        _messageIds.clear();
        _appearingMessageIds.clear();
      });
      showAppNotice(
        context,
        'Все сообщения удалены',
        tone: AppNoticeTone.warning,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка очистки чата: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
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
    required bool canDeleteEntireChat,
    required bool canPin,
    required bool isPinned,
    required bool canReply,
    required bool canCopy,
    required bool canCopyId,
    required bool canOpenImage,
  }) async {
    final text = (message['text'] ?? '').toString();
    final imageUrl = _resolveImageUrl(
      _metaMapOf(message['meta'])['image_url']?.toString(),
    );

    Future<void> applyAction(String action) async {
      if (action == 'copy') {
        await _copyText(text);
      } else if (action == 'open_image') {
        if (imageUrl != null) {
          _openImagePreview(imageUrl);
        }
      } else if (action == 'reply') {
        _replyToMessage(text);
      } else if (action == 'edit') {
        await _editMessage(message);
      } else if (action == 'delete_me') {
        await _deleteMessage(message, forAll: false);
      } else if (action == 'delete_all') {
        await _deleteMessage(message, forAll: true);
      } else if (action == 'delete_chat') {
        await _deleteAllMessagesInChat();
      } else if (action == 'pin' && canPin) {
        final messageId = message['id']?.toString() ?? '';
        if (messageId.isNotEmpty) {
          await _pinMessage(messageId);
        }
      } else if (action == 'unpin' && canPin) {
        await _unpinMessage();
      } else if (action == 'copy_id' && canCopyId) {
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
    if (canPin) {
      options.add(
        PopupMenuItem(
          value: isPinned ? 'unpin' : 'pin',
          child: Text(isPinned ? 'Открепить' : 'Закрепить'),
        ),
      );
    }
    if (canOpenImage) {
      options.add(
        const PopupMenuItem(value: 'open_image', child: Text('Открыть фото')),
      );
    }
    if (canCopyId) {
      options.add(
        const PopupMenuItem(value: 'copy_id', child: Text('Копировать ID')),
      );
    }
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
    if (canDeleteEntireChat) {
      options.add(
        const PopupMenuItem(
          value: 'delete_chat',
          child: Text('УДАЛИТЬ ВСЁ!', style: TextStyle(color: Colors.red)),
        ),
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
            if (canPin)
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(isPinned ? 'Открепить' : 'Закрепить'),
                onTap: () => Navigator.of(ctx).pop(isPinned ? 'unpin' : 'pin'),
              ),
            if (canOpenImage)
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Открыть фото'),
                onTap: () => Navigator.of(ctx).pop('open_image'),
              ),
            if (canCopyId)
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
            if (canDeleteEntireChat)
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.red,
                ),
                title: const Text(
                  'УДАЛИТЬ ВСЁ!',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.of(ctx).pop('delete_chat'),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceAttachment(
    ThemeData theme,
    Map<String, dynamic> message,
    Map<String, dynamic> meta, {
    required Color textColor,
  }) {
    final messageId = message['id']?.toString().trim() ?? '';
    final voiceUrl = _voiceUrlOf(meta);
    final durationMs = _voiceDurationMsOf(meta);
    final fallbackDuration = Duration(
      milliseconds: durationMs > 0 ? durationMs : 0,
    );
    final isActive = _activeVoiceMessageId == messageId;
    final isPlaying = isActive && _voicePlayerState == PlayerState.playing;
    final totalDuration = isActive && _activeVoiceDuration > Duration.zero
        ? _activeVoiceDuration
        : fallbackDuration;
    final currentPosition = isActive ? _activeVoicePosition : Duration.zero;
    final progress = totalDuration.inMilliseconds > 0
        ? (currentPosition.inMilliseconds / totalDuration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble()
        : 0.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: voiceUrl == null
              ? null
              : () => _toggleVoicePlayback(messageId, voiceUrl),
          child: Ink(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: progress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isActive && currentPosition > Duration.zero
                        ? _formatDurationLabel(currentPosition)
                        : _formatDurationLabel(totalDuration),
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Голосовое',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> message) {
    final theme = Theme.of(context);
    final fromMe = _isOwnMessage(message);
    final messageId = message['id']?.toString().trim() ?? '';
    final hasMessageId = messageId.isNotEmpty;
    final text = message['text']?.toString() ?? '';
    final metaMap = _metaMapOf(message['meta']);
    final isDeleted = metaMap['deleted'] == true;
    final attachmentType = _attachmentTypeOf(metaMap);

    final isReservedOrder = !isDeleted && _isReservedOrder(message);
    final hasBuy = !isDeleted && !isReservedOrder && _isCatalogProduct(message);
    final isDeliveryOffer =
        !isDeleted && !hasBuy && !isReservedOrder && _isDeliveryOffer(message);
    final isSupportFeedback =
        !isDeleted &&
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        _isSupportFeedbackPrompt(message);
    final isImageMessage =
        !isDeleted &&
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        attachmentType == 'image';
    final isVoiceMessage =
        !isDeleted &&
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        attachmentType == 'voice';
    final imageUrl = _resolveImageUrl(metaMap['image_url']?.toString());
    final captionText = _captionTextOf(message, metaMap);
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
    final offerStatus = (metaMap['offer_status'] ?? 'pending')
        .toString()
        .trim();
    final offerDeliveryLabel = (metaMap['delivery_label'] ?? 'Доставка')
        .toString();
    final offerDeliveryDate = formatDateTimeValue(
      metaMap['delivery_date'],
      fallback: '',
    );
    final offerPhone = (metaMap['customer_phone'] ?? '').toString().trim();
    final offerProcessedSum = (metaMap['processed_sum'] ?? 0).toString();
    final offerAddress = (metaMap['address_text'] ?? '').toString().trim();
    final offerPreferredAfter = (metaMap['preferred_time_from'] ?? '')
        .toString()
        .trim();
    final offerPreferredBefore = (metaMap['preferred_time_to'] ?? '')
        .toString()
        .trim();
    final supportTicketId = (metaMap['support_ticket_id'] ?? '')
        .toString()
        .trim();
    final supportFeedbackStatus = (metaMap['feedback_status'] ?? 'pending')
        .toString()
        .toLowerCase()
        .trim();
    final supportFeedbackBusy =
        supportTicketId.isNotEmpty &&
        _supportFeedbackBusyTicketIds.contains(supportTicketId);

    final bubbleColor = hasBuy
        ? theme.colorScheme.surfaceContainerLow
        : isReservedOrder
        ? (isPlaced
              ? const Color(0xFF5E8F6B).withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.34 : 0.18,
                )
              : theme.colorScheme.surfaceContainerHigh)
        : isDeliveryOffer
        ? theme.colorScheme.surfaceContainerHigh
        : (fromMe
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest);
    final textColor = (!hasBuy && !isReservedOrder && fromMe)
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    final isPlainMessage =
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        !isImageMessage &&
        !isVoiceMessage;
    final isCreator = _isCreatorRole();
    final isClient = _isClientRole();
    final canEdit = isPlainMessage && fromMe && !isDeleted;
    final canDeleteForMe = hasMessageId && (isCreator || !isDeleted);
    final canDeleteForAll =
        hasMessageId &&
        (isCreator ||
            (!isDeleted &&
                ((isPlainMessage && (fromMe || _isAdminOrCreator())) ||
                    ((hasBuy || isReservedOrder) && _isAdminOrCreator()))));
    final canDeleteEntireChat = isCreator;
    final canPin = _canPinMessages() && hasMessageId && !isDeleted;
    final isPinned = hasMessageId && _isMessagePinned(messageId);
    final canReply =
        !isClient && isPlainMessage && text.trim().isNotEmpty && !isDeleted;
    final canCopy =
        (isPlainMessage && text.trim().isNotEmpty) ||
        (isImageMessage && captionText.isNotEmpty);
    final canCopyId = !isClient;
    final canOpenImage = imageUrl != null;
    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.72;
    final showChatIdentity = !hasBuy && !isReservedOrder;
    final timeLabel = _formatMessageTime(message['created_at']);
    final deliveryStatus = fromMe && showChatIdentity
        ? _deliveryStatusOf(message)
        : '';

    final edited = metaMap['edited'] == true;
    Widget buildMessageImage({double? width}) {
      if (imageUrl == null) return const SizedBox.shrink();
      return GestureDetector(
        onTap: () => _openImagePreview(imageUrl),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: width ?? 240,
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) => Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final bubble = GestureDetector(
      onSecondaryTapDown: (details) => _showMessageActions(
        message,
        secondaryTap: details,
        canEdit: canEdit,
        canDeleteForMe: canDeleteForMe,
        canDeleteForAll: canDeleteForAll,
        canDeleteEntireChat: canDeleteEntireChat,
        canPin: canPin,
        isPinned: isPinned,
        canReply: canReply,
        canCopy: canCopy,
        canCopyId: canCopyId,
        canOpenImage: canOpenImage,
      ),
      onLongPress: () => _showMessageActions(
        message,
        canEdit: canEdit,
        canDeleteForMe: canDeleteForMe,
        canDeleteForAll: canDeleteForAll,
        canDeleteEntireChat: canDeleteEntireChat,
        canPin: canPin,
        isPinned: isPinned,
        canReply: canReply,
        canCopy: canCopy,
        canCopyId: canCopyId,
        canOpenImage: canOpenImage,
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
            if (showChatIdentity) ...[
              Text(
                senderName,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (isDeliveryOffer) ...[
              Text(
                offerDeliveryLabel,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              if (offerDeliveryDate.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Плановая дата: $offerDeliveryDate',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _catalogMetaBadge(
                    theme,
                    'Телефон',
                    offerPhone.isEmpty ? '—' : offerPhone,
                  ),
                  _catalogMetaBadge(
                    theme,
                    'Обработано',
                    '$offerProcessedSum RUB',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                text,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (offerAddress.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Адрес: $offerAddress'),
              ],
              if (offerPreferredAfter.isNotEmpty ||
                  offerPreferredBefore.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Пожелание по времени: ${[if (offerPreferredAfter.isNotEmpty) 'после $offerPreferredAfter', if (offerPreferredBefore.isNotEmpty) 'до $offerPreferredBefore'].join(', ')}',
                ),
              ],
              const SizedBox(height: 10),
              if (offerStatus == 'pending') ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () =>
                          _respondToDeliveryOffer(metaMap, accepted: true),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Да, согласен'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _respondToDeliveryOffer(metaMap, accepted: false),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Нет'),
                    ),
                  ],
                ),
              ] else ...[
                _catalogMetaBadge(
                  theme,
                  'Ответ',
                  offerStatus == 'accepted'
                      ? 'Подтверждено'
                      : offerStatus == 'declined'
                      ? 'Отказ'
                      : 'Ожидаем ответ',
                ),
              ],
            ] else if (isSupportFeedback) ...[
              Text(
                text,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              if (_isClientRole() && supportFeedbackStatus == 'pending') ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: supportFeedbackBusy
                          ? null
                          : () => _respondToSupportFeedback(
                              metaMap,
                              resolved: true,
                            ),
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(
                        supportFeedbackBusy ? 'Сохранение...' : 'Да, решили',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: supportFeedbackBusy
                          ? null
                          : () => _respondToSupportFeedback(
                              metaMap,
                              resolved: false,
                            ),
                      icon: const Icon(Icons.refresh_outlined),
                      label: const Text('Нет, ещё вопрос'),
                    ),
                  ],
                ),
              ] else ...[
                _catalogMetaBadge(
                  theme,
                  'Статус',
                  supportFeedbackStatus == 'resolved'
                      ? 'Закрыт'
                      : supportFeedbackStatus == 'reopened'
                      ? 'Открыт повторно'
                      : 'Ожидаем ответ клиента',
                ),
              ],
            ] else if (hasBuy) ...[
              if (imageUrl != null) ...[
                buildMessageImage(width: double.infinity),
                const SizedBox(height: 12),
              ],
              Text(
                catalogTexts['title'] ?? 'Товар',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              if ((catalogTexts['description'] ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  catalogTexts['description'] ?? '',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _catalogMetaBadge(theme, 'Цена', '$price RUB'),
                  _catalogMetaBadge(theme, 'В наличии', quantity),
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
              if (imageUrl != null) ...[
                buildMessageImage(width: double.infinity),
                const SizedBox(height: 12),
              ],
              Text(
                metaMap['title']?.toString().isNotEmpty == true
                    ? metaMap['title'].toString()
                    : catalogTexts['title'] ?? 'Заказ',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              if (reservedDescription.isNotEmpty) ...[
                Text(
                  reservedDescription,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
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
                  _catalogMetaBadge(theme, 'ID', productCode),
                  _catalogMetaBadge(theme, 'Цена', '$price RUB'),
                  _catalogMetaBadge(theme, 'Куплено', quantity),
                  _catalogMetaBadge(theme, 'Полка', shelf),
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
              if (isVoiceMessage) ...[
                _buildVoiceAttachment(
                  theme,
                  message,
                  metaMap,
                  textColor: textColor,
                ),
                if (captionText.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(captionText, style: TextStyle(color: textColor)),
                ],
              ] else ...[
                if (imageUrl != null) ...[
                  buildMessageImage(),
                  if (captionText.isNotEmpty || isPlainMessage)
                    const SizedBox(height: 10),
                ],
                if (isPlainMessage || captionText.isNotEmpty)
                  Text(
                    isPlainMessage ? text : captionText,
                    style: TextStyle(
                      color: isDeleted
                          ? theme.colorScheme.onSurfaceVariant
                          : textColor,
                      fontStyle: isDeleted
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
              ],
              if (edited && !isDeleted && isPlainMessage)
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
              if (timeLabel.isNotEmpty) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        timeLabel,
                        style: TextStyle(
                          color: fromMe
                              ? theme.colorScheme.onPrimaryContainer.withValues(
                                  alpha: 0.76,
                                )
                              : theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (fromMe) ...[
                        const SizedBox(width: 4),
                        _buildDeliveryStatusIcon(
                          theme,
                          deliveryStatus,
                          fromMe: fromMe,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );

    final showAvatar = !hasBuy && !isReservedOrder;

    final isAppearing =
        messageId.isNotEmpty && _appearingMessageIds.contains(messageId);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: isAppearing ? 0 : 1, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final dx = fromMe ? 18 * (1 - value) : -28 * (1 - value);
        final dy = 10 * (1 - value);
        return Opacity(
          opacity: value.clamp(0, 1),
          child: Transform.translate(offset: Offset(dx, dy), child: child),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          mainAxisAlignment: fromMe
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!fromMe && showAvatar) ...[
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
            if (fromMe && showAvatar) ...[
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
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    hintText: 'Поиск по чату',
                    border: InputBorder.none,
                  ),
                  controller: _searchController,
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
          if (_activePin != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.push_pin,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pinPreviewText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (_canPinMessages())
                    IconButton(
                      tooltip: 'Открепить',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _unpinMessage,
                    ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const PhoenixLoadingView(
                    title: 'Загрузка чата',
                    subtitle: 'Подтягиваем сообщения и медиа',
                  )
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
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
          if (_voiceRecording)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.mic_rounded,
                    color: Theme.of(context).colorScheme.error,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Запись голосового: ${_formatDurationLabel(Duration(seconds: _recordingSeconds))}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: _mediaUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                  onPressed:
                      canCompose &&
                          !_mediaUploading &&
                          !_voiceSending &&
                          !_voiceRecording
                      ? _openAttachmentSheet
                      : null,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SubmitOnEnter(
                      controller: _controller,
                      enabled: canCompose && !_voiceRecording,
                      onSubmit: _send,
                      child: TextField(
                        focusNode: _inputFocusNode,
                        controller: _controller,
                        enabled: canCompose && !_voiceRecording,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: withInputLanguageBadge(
                          InputDecoration(
                            hintText: _voiceRecording
                                ? 'Говорите... повторное нажатие отправит голосовое'
                                : canCompose
                                ? 'Сообщение...'
                                : 'Отправка сообщений недоступна',
                            border: const OutlineInputBorder(),
                          ),
                          controller: _controller,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: _voiceSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _controller.text.trim().isNotEmpty
                              ? Icons.send
                              : (_voiceRecording
                                    ? Icons.stop_circle_outlined
                                    : Icons.mic_none_rounded),
                        ),
                  onPressed: !canCompose || _mediaUploading
                      ? null
                      : (_controller.text.trim().isNotEmpty
                            ? _send
                            : _toggleVoiceComposerAction),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
