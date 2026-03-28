// lib/screens/chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart' as cam;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart' as vp;

import '../main.dart';
import '../services/web_media_capture_permission_service.dart';
import '../src/utils/media_url.dart';
import '../utils/date_time_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/adaptive_network_image.dart';
import '../widgets/inline_video_note_orb.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/submit_on_enter.dart';

class _ChatUploadFile {
  const _ChatUploadFile({
    required this.filename,
    this.path,
    this.bytes,
    this.mimeType,
  });

  final String filename;
  final String? path;
  final Uint8List? bytes;
  final String? mimeType;
}

enum _ComposerMediaMode { voice, camera }

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
  bool _voiceRecordingLocked = false;
  bool _videoRecording = false;
  bool _videoRecordingLocked = false;
  _ComposerMediaMode _composerMediaMode = _ComposerMediaMode.voice;
  bool _composerMediaPressActive = false;
  bool _composerHoldActionTriggered = false;
  bool _voiceStartInProgress = false;
  bool _videoStartInProgress = false;
  bool _pinLoading = false;
  bool _hasDraftText = false;
  bool _offlineSyncBusy = false;
  int _offlineQueuedCount = 0;

  String _searchQuery = '';
  List<String> _searchResultIds = const [];
  int _searchResultIndex = -1;
  int _recordingSeconds = 0;
  int _videoRecordingSeconds = 0;
  String _activeVoiceUploadExtension = 'm4a';
  String? _activeVoiceMessageId;
  Duration _activeVoicePosition = Duration.zero;
  Duration _activeVoiceDuration = Duration.zero;
  PlayerState _voicePlayerState = PlayerState.stopped;
  List<cam.CameraDescription> _availableCameras = const [];
  cam.CameraController? _videoCameraController;
  Future<bool>? _videoCameraReadyFuture;
  vp.VideoPlayerController? _inlineVideoNoteController;
  Object? _lastVideoCameraError;
  String? _activeVideoNoteMessageId;
  bool _inlineVideoNoteInitializing = false;

  StreamSubscription? _chatSub;
  Timer? _incomingTimer;
  Timer? _readDebounceTimer;
  Timer? _voiceRecordingTimer;
  Timer? _videoRecordingTimer;
  Timer? _offlineQueueRefreshTimer;
  Timer? _composerMediaHoldTimer;
  StreamSubscription<Duration>? _voicePositionSub;
  StreamSubscription<Duration>? _voiceDurationSub;
  StreamSubscription<PlayerState>? _voiceStateSub;
  StreamSubscription<void>? _voiceCompleteSub;
  DateTime? _voiceRecordingStartedAt;
  DateTime? _videoRecordingStartedAt;
  Offset? _composerPressStartGlobal;
  double _recordingDragDx = 0;
  double _recordingDragDy = 0;
  double _videoRecordingDragDx = 0;
  double _videoRecordingDragDy = 0;
  bool _microphonePermissionAsked = false;
  bool _microphonePermissionGranted = false;
  bool _microphonePermissionDenied = false;
  Future<List<({RecordConfig config, String extension, String label})>>?
  _webVoiceConfigsFuture;

  final Set<String> _messageIds = {};
  final Set<String> _placedCartItemIds = {};
  final Set<String> _supportFeedbackBusyTicketIds = {};
  final Map<String, GlobalKey> _messageItemKeys = {};
  Map<String, dynamic>? _activePin;
  final List<String> _recentReactionEmojis = <String>[];
  final List<String> _recentComposerEmojis = <String>[];

  static const List<String> _quickReactions = <String>[
    '👍',
    '🎉',
    '❤️',
    '👎',
    '🔥',
    '🥰',
    '👏',
    '😂',
    '😎',
    '🤝',
    '😢',
  ];
  static const List<String> _composerEmojiPalette = <String>[
    '🙂',
    '😀',
    '😁',
    '😅',
    '😂',
    '😊',
    '😍',
    '😘',
    '🤔',
    '😎',
    '😭',
    '😡',
    '👍',
    '👎',
    '👏',
    '🔥',
    '❤️',
    '💯',
    '✅',
    '🙏',
    '🎉',
    '🤝',
    '👀',
    '⭐',
  ];

  @override
  void initState() {
    super.initState();
    activeChatIdNotifier.value = widget.chatId;
    _loadMessages();
    _loadPinnedMessage();
    _joinRoom();
    unawaited(_refreshOfflineQueueCount());
    _offlineQueueRefreshTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(_refreshOfflineQueueCount()),
    );

    _searchController.addListener(() {
      final next = _searchController.text.trim();
      if (next == _searchQuery) return;
      setState(() => _searchQuery = next);
      _recomputeSearchResults(keepCurrent: false);
    });

    _hasDraftText = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final nextHasDraft = _controller.text.trim().isNotEmpty;
      if (nextHasDraft != _hasDraftText && mounted) {
        setState(() => _hasDraftText = nextHasDraft);
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
      if (type == 'chat:deleted' && data is Map) {
        final chatId = data['chatId']?.toString() ?? '';
        if (chatId != widget.chatId) return;
        if (!mounted) return;
        final reason = data['reason']?.toString() ?? '';
        if (reason == 'support_archived') {
          showAppNotice(
            context,
            'Диалог закончен',
            tone: AppNoticeTone.info,
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).maybePop();
        });
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
          _messageItemKeys.clear();
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
        return;
      }
      if (type == 'cart:offline-sync') {
        unawaited(_refreshOfflineQueueCount());
        unawaited(_loadMessages());
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
    _videoRecordingTimer?.cancel();
    _offlineQueueRefreshTimer?.cancel();
    _composerMediaHoldTimer?.cancel();
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
    if (_videoCameraController != null) {
      if (_videoCameraController!.value.isRecordingVideo) {
        unawaited(_videoCameraController!.stopVideoRecording());
      }
      unawaited(_videoCameraController!.dispose());
    }
    unawaited(_stopInlineVideoNotePlayback(notify: false));

    _controller.dispose();
    _searchController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _messageItemKeys.clear();
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
    _recomputeSearchResults();

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
      _messageItemKeys.remove(messageId);
      _appearingMessageIds.remove(messageId);
    });
    _recomputeSearchResults();
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

  GlobalKey _messageKeyFor(String messageId) {
    return _messageItemKeys.putIfAbsent(messageId, GlobalKey.new);
  }

  Future<BuildContext?> _resolveMessageContextWithScroll(
    String messageId,
  ) async {
    BuildContext? context = _messageItemKeys[messageId]?.currentContext;
    if (context != null && context.mounted) return context;
    if (!_scrollController.hasClients) return null;

    final visibleMessages = _visibleMessages();
    if (visibleMessages.isEmpty) return null;
    final timeline = _buildTimeline(visibleMessages);
    final messageRowIndex = timeline.indexWhere((row) {
      if (row['type'] != 'message') return false;
      final rowMessage = row['data'];
      if (rowMessage is! Map) return false;
      return (rowMessage['id'] ?? '').toString() == messageId;
    });
    if (messageRowIndex < 0) return null;

    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) {
      return _messageItemKeys[messageId]?.currentContext;
    }

    final targetFraction = timeline.length <= 1
        ? 0.0
        : (messageRowIndex / (timeline.length - 1)).clamp(0.0, 1.0);
    final estimatedOffset = maxExtent * targetFraction;
    final deltas = <double>[0, -0.06, 0.06, -0.14, 0.14, -0.25, 0.25];

    final offsets = <double>[];
    for (final delta in deltas) {
      final candidate = (estimatedOffset + maxExtent * delta)
          .clamp(0.0, maxExtent)
          .toDouble();
      if (!offsets.any((x) => (x - candidate).abs() < 2)) {
        offsets.add(candidate);
      }
    }
    for (final fallback in <double>[0.0, maxExtent, maxExtent * 0.5]) {
      final candidate = fallback.clamp(0.0, maxExtent).toDouble();
      if (!offsets.any((x) => (x - candidate).abs() < 2)) {
        offsets.add(candidate);
      }
    }

    for (final offset in offsets) {
      if (!_scrollController.hasClients) break;
      _scrollController.jumpTo(offset);
      await Future<void>.delayed(const Duration(milliseconds: 34));
      if (!mounted) return null;
      context = _messageItemKeys[messageId]?.currentContext;
      if (context != null && context.mounted) {
        return context;
      }
    }

    // Fallback sweep for long chats where message tile heights vary a lot.
    for (var i = 0; i <= 16; i++) {
      if (!_scrollController.hasClients) break;
      final fraction = i / 16;
      final offset = (maxExtent * fraction).clamp(0.0, maxExtent).toDouble();
      _scrollController.jumpTo(offset);
      await Future<void>.delayed(const Duration(milliseconds: 28));
      if (!mounted) return null;
      context = _messageItemKeys[messageId]?.currentContext;
      if (context != null && context.mounted) {
        return context;
      }
    }

    return _messageItemKeys[messageId]?.currentContext;
  }

  Future<void> _jumpToPinnedMessage() async {
    final pin = _activePin;
    if (pin == null) return;
    final messageId = (pin['message_id'] ?? '').toString().trim();
    if (messageId.isEmpty) return;

    if (_searchMode || _searchQuery.isNotEmpty) {
      setState(() {
        _searchMode = false;
        _searchController.clear();
        _searchQuery = '';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;

    BuildContext? targetContext = await _resolveMessageContextWithScroll(
      messageId,
    );
    if (targetContext == null) {
      try {
        final resp = await authService.dio.get(
          '/api/chats/${widget.chatId}/messages/$messageId',
        );
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          _upsertMessage(
            Map<String, dynamic>.from(data['data']),
            autoScroll: false,
          );
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (!mounted) return;
          targetContext = await _resolveMessageContextWithScroll(messageId);
        }
      } catch (_) {}
    }

    if (targetContext == null) {
      showGlobalAppNotice(
        'Не удалось перейти: сообщение недоступно',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    if (!targetContext.mounted) return;

    await Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 260),
      alignment: 0.12,
      curve: Curves.easeOutCubic,
    );
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

  bool _isSupportTicketChat() {
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    return kind == 'support_ticket' || settings['support_ticket'] == true;
  }

  bool _isArchivedSupportTicketChat() {
    if (!_isSupportTicketChat()) return false;
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    if (settings['support_archived'] == true) return true;
    final status = (settings['support_ticket_status'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    return status == 'archived';
  }

  bool _isDirectMessageChat() {
    if ((widget.chatType ?? '').toLowerCase().trim() != 'private') return false;
    if (_isSupportTicketChat()) return false;
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    if (kind == 'direct_message') return true;
    return kind.isEmpty;
  }

  bool _canCompose() {
    if (_isArchivedSupportTicketChat()) {
      return false;
    }
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
    if (_isArchivedSupportTicketChat()) {
      return 'Диалог закончен. История доступна только для просмотра.';
    }
    if (_isPublicChannel()) {
      return 'В этом публичном канале писать может только администрация';
    }
    return 'В этом чате отправка сообщений недоступна';
  }

  Future<void> _refreshOfflineQueueCount() async {
    if (!mounted) return;
    if (!_isClientRole()) {
      if (_offlineQueuedCount != 0) {
        setState(() => _offlineQueuedCount = 0);
      }
      return;
    }
    final userId = authService.currentUser?.id.trim() ?? '';
    if (userId.isEmpty) return;
    try {
      final nextCount = await offlinePurchaseQueueService.countForUser(
        userId,
        tenantCode: authService.currentUser?.tenantCode,
      );
      if (!mounted) return;
      if (nextCount != _offlineQueuedCount) {
        setState(() => _offlineQueuedCount = nextCount);
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _syncOfflinePurchasesNow() async {
    if (_offlineSyncBusy || !_isClientRole()) return;
    final user = authService.currentUser;
    final userId = user?.id.trim() ?? '';
    if (userId.isEmpty) return;
    setState(() => _offlineSyncBusy = true);
    try {
      final result = await offlinePurchaseQueueService.flushQueuedPurchases(
        dio: authService.dio,
        userId: userId,
        tenantCode: user?.tenantCode,
      );
      await _refreshOfflineQueueCount();
      if (!mounted) return;
      if (result.confirmed > 0) {
        showAppNotice(
          context,
          'Подтверждено оффлайн-покупок: ${result.confirmed}',
          tone: AppNoticeTone.success,
          duration: const Duration(seconds: 2),
        );
      } else if (result.rejected > 0) {
        showAppNotice(
          context,
          'Отклонено оффлайн-покупок: ${result.rejected}',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
      } else {
        showAppNotice(
          context,
          'Новых синхронизаций пока нет',
          duration: const Duration(seconds: 2),
        );
      }
      if (result.confirmed > 0 || result.rejected > 0) {
        await _loadMessages();
      }
    } catch (_) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось синхронизировать оффлайн-покупки',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
    } finally {
      if (mounted) setState(() => _offlineSyncBusy = false);
    }
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
          _messageItemKeys.removeWhere((id, _) => !_messageIds.contains(id));
        });
        _incomingTimer?.cancel();
        _incomingTimer = null;
        _recomputeSearchResults(keepCurrent: false);
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
                child: AdaptiveNetworkImage(
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
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get _anyComposerRecording => _voiceRecording || _videoRecording;

  bool get _anyRecorderStarting =>
      _voiceStartInProgress || _videoStartInProgress;

  double _normalizedProgress(double value, double threshold) {
    if (threshold <= 0) return 0;
    return (value / threshold).clamp(0.0, 1.0).toDouble();
  }

  bool get _preferFilePickerForImages {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<MultipartFile> _multipartFromUpload(
    _ChatUploadFile file, {
    DioMediaType? contentType,
  }) async {
    final resolvedContentType =
        contentType ?? _mediaTypeFromMimeString(file.mimeType);
    if (!kIsWeb && file.path != null && file.path!.trim().isNotEmpty) {
      return MultipartFile.fromFile(
        file.path!,
        filename: file.filename,
        contentType: resolvedContentType,
      );
    }
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Не удалось прочитать файл');
    }
    return MultipartFile.fromBytes(
      bytes,
      filename: file.filename,
      contentType: resolvedContentType,
    );
  }

  DioMediaType? _mediaTypeFromMimeString(String? mimeRaw) {
    final mime = (mimeRaw ?? '').trim().toLowerCase();
    if (mime.isEmpty || !mime.contains('/')) return null;
    final parts = mime.split('/');
    final type = parts.first.trim();
    final subtype = parts.sublist(1).join('/').split(';').first.trim();
    if (type.isEmpty || subtype.isEmpty) return null;
    return DioMediaType(type, subtype);
  }

  DioMediaType? _voiceContentTypeForUpload(_ChatUploadFile upload) {
    final mimeType = _mediaTypeFromMimeString(upload.mimeType);
    if (mimeType != null) return mimeType;
    final name = upload.filename.toLowerCase().trim();
    if (name.endsWith('.m4a') || name.endsWith('.mp4')) {
      return DioMediaType('audio', 'mp4');
    }
    if (name.endsWith('.aac')) {
      return DioMediaType('audio', 'aac');
    }
    if (name.endsWith('.wav')) {
      return DioMediaType('audio', 'wav');
    }
    if (name.endsWith('.mp3')) {
      return DioMediaType('audio', 'mpeg');
    }
    if (name.endsWith('.ogg') || name.endsWith('.opus')) {
      return DioMediaType('audio', 'ogg');
    }
    if (name.endsWith('.webm')) {
      return DioMediaType('audio', 'webm');
    }
    return DioMediaType('application', 'octet-stream');
  }

  DioMediaType? _videoContentTypeForUpload(_ChatUploadFile upload) {
    final mimeType = _mediaTypeFromMimeString(upload.mimeType);
    if (mimeType != null) return mimeType;
    final name = upload.filename.toLowerCase().trim();
    if (name.endsWith('.mp4') || name.endsWith('.m4v')) {
      return DioMediaType('video', 'mp4');
    }
    if (name.endsWith('.webm')) {
      return DioMediaType('video', 'webm');
    }
    if (name.endsWith('.mov')) {
      return DioMediaType('video', 'quicktime');
    }
    return DioMediaType('application', 'octet-stream');
  }

  String _videoExtensionForMime(String? mimeRaw) {
    final mime = (mimeRaw ?? '').trim().toLowerCase();
    if (mime.contains('webm')) return 'webm';
    if (mime.contains('quicktime') || mime.contains('mov')) return 'mov';
    return 'mp4';
  }

  Future<List<({RecordConfig config, String extension, String label})>>
  _resolveWebVoiceRecordConfigs() {
    final cached = _webVoiceConfigsFuture;
    if (cached != null) return cached;
    final future = _computeWebVoiceRecordConfigs();
    _webVoiceConfigsFuture = future;
    return future;
  }

  Future<List<({RecordConfig config, String extension, String label})>>
  _computeWebVoiceRecordConfigs() async {
    final candidates =
        <({RecordConfig config, String extension, String label})>[];

    Future<bool> supports(AudioEncoder encoder) async {
      try {
        return await _voiceRecorder.isEncoderSupported(encoder);
      } catch (e) {
        debugPrint('voice isEncoderSupported($encoder) error: $e');
        return false;
      }
    }

    if (await supports(AudioEncoder.aacLc)) {
      candidates.add((
        config: const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        extension: 'm4a',
        label: 'aac',
      ));
    }

    if (await supports(AudioEncoder.opus)) {
      candidates.add((
        config: const RecordConfig(
          encoder: AudioEncoder.opus,
          bitRate: 128000,
          sampleRate: 48000,
        ),
        extension: 'webm',
        label: 'opus',
      ));
    }

    if (await supports(AudioEncoder.wav)) {
      candidates.add((
        config: const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 44100,
          bitRate: 1411200,
        ),
        extension: 'wav',
        label: 'wav',
      ));
    }

    candidates.add((
      config: const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        bitRate: 1411200,
      ),
      extension: 'wav',
      label: 'pcm16',
    ));
    return candidates;
  }

  String _recordingErrorHint(Object e) {
    final raw = e.toString();
    final text = raw.toLowerCase();
    if (text.contains('permission') ||
        text.contains('notallowed') ||
        text.contains('microphone')) {
      return 'разрешите доступ к микрофону в браузере';
    }
    if (text.contains('notfound') || text.contains('device')) {
      return 'микрофон не найден';
    }
    if (text.contains('security') || text.contains('https')) {
      return 'запись доступна только по HTTPS';
    }
    return 'попробуйте перезагрузить страницу и повторить';
  }

  String _cameraErrorHint(Object? error) {
    final text = '${error ?? ''}'.toLowerCase();
    if (text.contains('permission') ||
        text.contains('notallowed') ||
        text.contains('denied') ||
        text.contains('security')) {
      return 'разрешите доступ к камере в браузере';
    }
    if (text.contains('notfound') || text.contains('device')) {
      return 'камера не найдена';
    }
    if (text.contains('https')) {
      return 'камера доступна только по HTTPS';
    }
    if (text.contains('unsupported') || text.contains('notsupported')) {
      return 'браузер не поддерживает запись камеры';
    }
    return 'попробуйте перезагрузить страницу и повторить';
  }

  bool _isLikelyMicrophonePermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission') ||
        text.contains('notallowed') ||
        text.contains('microphone') ||
        text.contains('denied') ||
        text.contains('security');
  }

  bool _applyWebCapturePermissionState(WebMediaCaptureAccessState state) {
    switch (state) {
      case WebMediaCaptureAccessState.grantedAudioOnly:
      case WebMediaCaptureAccessState.grantedAudioVideo:
        _microphonePermissionAsked = true;
        _microphonePermissionGranted = true;
        _microphonePermissionDenied = false;
        return true;
      case WebMediaCaptureAccessState.denied:
        _microphonePermissionAsked = true;
        _microphonePermissionGranted = false;
        _microphonePermissionDenied = true;
        return false;
      case WebMediaCaptureAccessState.defaultState:
      case WebMediaCaptureAccessState.unsupported:
        return false;
    }
  }

  Future<bool> _ensureMicrophonePermission() async {
    if (_microphonePermissionGranted) return true;
    if (_microphonePermissionDenied) return false;

    if (kIsWeb) {
      try {
        final access =
            await WebMediaCapturePermissionService.requestPreferredAccess(
              includeVideo: _cameraSupported,
              allowAudioOnlyFallback: true,
            );
        if (_applyWebCapturePermissionState(access)) {
          return true;
        }
        if (access == WebMediaCaptureAccessState.denied) {
          return false;
        }
      } catch (e) {
        debugPrint('web media capture permission fallback: $e');
      }

      try {
        final status = await _voiceRecorder.hasPermission(request: false);
        if (status) {
          _microphonePermissionGranted = true;
          _microphonePermissionAsked = true;
          _microphonePermissionDenied = false;
          return true;
        }
      } catch (e) {
        // Some WebKit variants may not support permissions.query.
        debugPrint('voice hasPermission(request:false) web fallback: $e');
      }

      if (_microphonePermissionAsked) {
        // Avoid repeated permission prompts each attempt.
        return false;
      }

      _microphonePermissionAsked = true;
      try {
        final granted = await _voiceRecorder.hasPermission();
        _microphonePermissionGranted = granted;
        _microphonePermissionDenied = !granted;
        return granted;
      } catch (e) {
        // Let start() try to request access as last fallback on browsers.
        debugPrint('voice hasPermission() web fallback start-only: $e');
        return true;
      }
    }

    if (_microphonePermissionAsked) {
      return false;
    }
    _microphonePermissionAsked = true;
    try {
      final granted = await _voiceRecorder.hasPermission();
      _microphonePermissionGranted = granted;
      _microphonePermissionDenied = !granted;
      return granted;
    } catch (e) {
      debugPrint('voice hasPermission native error: $e');
      _microphonePermissionDenied = true;
      return false;
    }
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

    final picked = await _imagePicker.pickImage(source: source);
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

  Future<void> _sendMediaMessage({
    required _ChatUploadFile upload,
    required String attachmentType,
    int? durationMs,
  }) async {
    if (!_canCompose()) return;
    final clientMsgId = _generateClientMessageId();
    final caption = attachmentType == 'image' || attachmentType == 'video'
        ? _controller.text.trim()
        : '';
    final previousText = _controller.text;
    setState(() {
      _mediaUploading = attachmentType == 'image' || attachmentType == 'video';
      _voiceSending = attachmentType == 'voice';
    });
    try {
      final form = FormData.fromMap({
        if (attachmentType == 'image')
          'image': await _multipartFromUpload(upload),
        if (attachmentType == 'voice')
          'voice': await _multipartFromUpload(
            upload,
            contentType: _voiceContentTypeForUpload(upload),
          ),
        if (attachmentType == 'video')
          'video': await _multipartFromUpload(
            upload,
            contentType: _videoContentTypeForUpload(upload),
          ),
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
          if (attachmentType == 'image' || attachmentType == 'video') {
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
            ? 'Не удалось отправить изображение: ${_extractDioError(e)}'
            : attachmentType == 'video'
            ? 'Не удалось отправить видео: ${_extractDioError(e)}'
            : 'Не удалось отправить голосовое сообщение: ${_extractDioError(e)}',
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

  void _rememberRecentEmoji(List<String> target, String emoji) {
    final normalized = emoji.trim();
    if (normalized.isEmpty) return;
    target.removeWhere((value) => value == normalized);
    target.insert(0, normalized);
    const maxRecent = 8;
    if (target.length > maxRecent) {
      target.removeRange(maxRecent, target.length);
    }
  }

  List<String> _mergeEmojiChoices(
    List<String> primary,
    List<String> fallback, {
    required int maxCount,
  }) {
    final out = <String>[];
    for (final emoji in [...primary, ...fallback]) {
      final normalized = emoji.trim();
      if (normalized.isEmpty || out.contains(normalized)) continue;
      out.add(normalized);
      if (out.length >= maxCount) break;
    }
    return out;
  }

  List<String> _reactionPickerEmojis() {
    return _mergeEmojiChoices(
      _recentReactionEmojis,
      _quickReactions,
      maxCount: 9,
    );
  }

  List<String> _composerPickerEmojis() {
    return _mergeEmojiChoices(
      _recentComposerEmojis,
      _composerEmojiPalette,
      maxCount: 28,
    );
  }

  void _insertComposerEmoji(String emoji) {
    final value = _controller.value;
    final normalized = emoji.trim();
    if (normalized.isEmpty) return;
    final start = max(0, value.selection.start);
    final end = max(0, value.selection.end);
    final left = value.text.substring(0, min(start, value.text.length));
    final right = value.text.substring(min(end, value.text.length));
    final nextText = '$left$normalized$right';
    final nextOffset = (left.length + normalized.length).clamp(
      0,
      nextText.length,
    );
    _controller.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
      composing: TextRange.empty,
    );
    _rememberRecentEmoji(_recentComposerEmojis, normalized);
    _inputFocusNode.requestFocus();
  }

  Future<void> _openComposerEmojiPicker() async {
    if (!_canCompose() || _voiceRecording) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final options = _composerPickerEmojis();
        final recent = _recentComposerEmojis;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Эмодзи',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (recent.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Недавние',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: recent
                          .map(
                            (emoji) => Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: () => Navigator.of(ctx).pop(emoji),
                                child: Ink(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 26),
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    itemCount: options.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 7,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          childAspectRatio: 1,
                        ),
                    itemBuilder: (context, index) {
                      final emoji = options[index];
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => Navigator.of(ctx).pop(emoji),
                        child: Center(
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() => _insertComposerEmoji(selected));
  }

  Future<void> _startVoiceRecording({bool autoStopIfNotPressed = true}) async {
    if (!_canCompose() ||
        _voiceSending ||
        _mediaUploading ||
        _voiceRecording ||
        _voiceStartInProgress) {
      return;
    }
    _voiceStartInProgress = true;
    try {
      final allowed = await _ensureMicrophonePermission();
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

      if (kIsWeb) {
        final webConfigs = await _resolveWebVoiceRecordConfigs();
        Object? lastStartError;
        bool started = false;
        for (final candidate in webConfigs) {
          final candidatePath =
              'voice-${DateTime.now().millisecondsSinceEpoch}.${candidate.extension}';
          try {
            await _voiceRecorder.start(candidate.config, path: candidatePath);
            _activeVoiceUploadExtension = candidate.extension;
            started = true;
            break;
          } catch (e) {
            lastStartError = e;
            debugPrint('voice start candidate ${candidate.label} failed: $e');
          }
        }
        if (!started) {
          throw lastStartError ?? Exception('Voice recorder start failed');
        }
      } else {
        final tempDir = await getTemporaryDirectory();
        final useAac =
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS;
        _activeVoiceUploadExtension = useAac ? 'm4a' : 'wav';
        final outputPath =
            '${tempDir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.$_activeVoiceUploadExtension';
        final config = RecordConfig(
          encoder: useAac ? AudioEncoder.aacLc : AudioEncoder.wav,
          bitRate: useAac ? 128000 : 1411200,
          sampleRate: 44100,
        );
        await _voiceRecorder.start(config, path: outputPath);
      }
      _voiceRecordingTimer?.cancel();
      setState(() {
        _voiceRecording = true;
        _voiceRecordingLocked = false;
        _recordingSeconds = 0;
        _recordingDragDx = 0;
        _recordingDragDy = 0;
      });
      _voiceRecordingStartedAt = DateTime.now();
      _microphonePermissionGranted = true;
      _microphonePermissionDenied = false;
      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordingSeconds += 1);
      });
      if (autoStopIfNotPressed && !_composerMediaPressActive) {
        await _stopVoiceRecordingAndSend();
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось начать запись: ${_recordingErrorHint(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      if (_isLikelyMicrophonePermissionError(e)) {
        _microphonePermissionDenied = true;
      }
      debugPrint('startVoiceRecording error: $e');
    } finally {
      _voiceStartInProgress = false;
    }
  }

  Future<Uint8List?> _readWebBlobBytes(String blobUrl) async {
    if (!kIsWeb) return null;
    final url = blobUrl.trim();
    if (url.isEmpty) return null;
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 60),
      Duration(milliseconds: 160),
      Duration(milliseconds: 320),
    ];
    for (var attempt = 0; attempt < retryDelays.length; attempt++) {
      final delay = retryDelays[attempt];
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      try {
        final bytes = await XFile(url).readAsBytes();
        if (bytes.isNotEmpty) {
          return bytes;
        }
      } catch (e) {
        debugPrint('readWebBlobBytes XFile attempt ${attempt + 1} error: $e');
      }
      try {
        final resp = await Dio().get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final data = resp.data;
        if (data != null && data.isNotEmpty) {
          return Uint8List.fromList(data);
        }
      } catch (e) {
        debugPrint('readWebBlobBytes Dio attempt ${attempt + 1} error: $e');
      }
    }
    return null;
  }

  cam.CameraDescription? _preferredFrontCamera() {
    if (_availableCameras.isEmpty) return null;
    for (final camera in _availableCameras) {
      if (camera.lensDirection == cam.CameraLensDirection.front) {
        return camera;
      }
    }
    return _availableCameras.first;
  }

  Future<bool> _ensureVideoCameraReady() async {
    final pending = _videoCameraReadyFuture;
    if (pending != null) {
      return pending;
    }
    final future = _initializeVideoCameraController();
    _videoCameraReadyFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_videoCameraReadyFuture, future)) {
        _videoCameraReadyFuture = null;
      }
    }
  }

  Future<bool> _initializeVideoCameraController() async {
    if (!_cameraSupported) return false;
    try {
      if (_availableCameras.isEmpty) {
        _availableCameras = await cam.availableCameras();
      }
      final cameras = _availableCameras;
      if (cameras.isEmpty) {
        _lastVideoCameraError = StateError('no camera devices found');
        return false;
      }

      final preferred = _preferredFrontCamera();
      final current = _videoCameraController;
      if (preferred != null &&
          current != null &&
          current.value.isInitialized &&
          current.description.name == preferred.name) {
        _lastVideoCameraError = null;
        return true;
      }

      final attemptQueue = <cam.CameraDescription>[
        ...?preferred == null ? null : [preferred],
        ...cameras.where((camera) => camera.name != preferred?.name),
      ];

      Object? lastError;
      for (final candidate in attemptQueue) {
        try {
          final next = cam.CameraController(
            candidate,
            cam.ResolutionPreset.medium,
            enableAudio: true,
          );
          await next.initialize();
          try {
            await next.lockCaptureOrientation(DeviceOrientation.portraitUp);
          } catch (_) {}
          try {
            await next.setFlashMode(cam.FlashMode.off);
          } catch (_) {}
          final previous = _videoCameraController;
          _videoCameraController = next;
          _lastVideoCameraError = null;
          if (previous != null) {
            await previous.dispose();
          }
          return true;
        } catch (e) {
          lastError = e;
          debugPrint(
            'ensureVideoCameraReady candidate ${candidate.name} failed: $e',
          );
        }
      }
      _lastVideoCameraError = lastError;
      return false;
    } catch (e) {
      _lastVideoCameraError = e;
      debugPrint('ensureVideoCameraReady error: $e');
      return false;
    }
  }

  Future<void> _startVideoCircleRecording({
    bool autoStopIfNotPressed = true,
  }) async {
    if (!_canCompose() ||
        _mediaUploading ||
        _voiceSending ||
        _voiceRecording ||
        _videoRecording ||
        _videoStartInProgress) {
      return;
    }
    _videoStartInProgress = true;
    try {
      if (kIsWeb) {
        final access =
            await WebMediaCapturePermissionService.requestPreferredAccess(
              includeVideo: true,
              allowAudioOnlyFallback: false,
            );
        final granted = _applyWebCapturePermissionState(access);
        if (!granted || access != WebMediaCaptureAccessState.grantedAudioVideo) {
          if (!mounted) return;
          showAppNotice(
            context,
            access == WebMediaCaptureAccessState.grantedAudioOnly
                ? 'Для видеокружка нужен доступ к фронтальной камере'
                : 'Нет доступа к камере и микрофону',
            tone: AppNoticeTone.warning,
            duration: const Duration(seconds: 2),
          );
          return;
        }
      } else {
        final micAllowed = await _ensureMicrophonePermission();
        if (!micAllowed) {
          if (!mounted) return;
          showAppNotice(
            context,
            'Нет доступа к микрофону',
            tone: AppNoticeTone.warning,
            duration: const Duration(seconds: 2),
          );
          return;
        }
      }
      final cameraReady = await _ensureVideoCameraReady();
      if (!cameraReady || _videoCameraController == null) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Не удалось подготовить камеру: ${_cameraErrorHint(_lastVideoCameraError)}',
          tone: AppNoticeTone.error,
          duration: const Duration(seconds: 2),
        );
        return;
      }
      final controller = _videoCameraController!;
      if (controller.value.isRecordingVideo) {
        return;
      }
      try {
        await controller.prepareForVideoRecording();
      } catch (_) {}
      await controller.startVideoRecording();
      _videoRecordingTimer?.cancel();
      setState(() {
        _videoRecording = true;
        _videoRecordingLocked = false;
        _videoRecordingSeconds = 0;
        _videoRecordingDragDx = 0;
        _videoRecordingDragDy = 0;
      });
      _videoRecordingStartedAt = DateTime.now();
      _videoRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _videoRecordingSeconds += 1);
      });
      if (autoStopIfNotPressed && !_composerMediaPressActive) {
        await _stopVideoCircleRecordingAndSend();
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось начать видеозапись',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('startVideoCircleRecording error: $e');
    } finally {
      _videoStartInProgress = false;
    }
  }

  Future<void> _stopVideoCircleRecordingAndSend() async {
    if (!_videoRecording || _videoCameraController == null) return;
    final startedAt = _videoRecordingStartedAt;
    final durationMs = startedAt == null
        ? _videoRecordingSeconds * 1000
        : DateTime.now().difference(startedAt).inMilliseconds;
    _videoRecordingTimer?.cancel();
    _videoRecordingTimer = null;
    _videoRecordingStartedAt = null;
    setState(() {
      _videoRecording = false;
      _videoRecordingLocked = false;
      _videoRecordingSeconds = 0;
      _videoRecordingDragDx = 0;
      _videoRecordingDragDy = 0;
    });
    try {
      final xfile = await _videoCameraController!.stopVideoRecording();
      if (durationMs < 1000) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Видеосообщение отменено (меньше 1 секунды)',
          tone: AppNoticeTone.info,
          duration: const Duration(milliseconds: 900),
        );
        return;
      }
      if (kIsWeb) {
        final mimeType = xfile.mimeType?.trim();
        final bytes =
            await _readWebBlobBytes(xfile.path) ?? await xfile.readAsBytes();
        if (bytes.isEmpty) {
          if (!mounted) return;
          showAppNotice(
            context,
            'Не удалось прочитать видеосообщение',
            tone: AppNoticeTone.error,
            duration: const Duration(seconds: 2),
          );
          return;
        }
        await _sendMediaMessage(
          upload: _ChatUploadFile(
            filename:
                'video-note-${DateTime.now().millisecondsSinceEpoch}.${_videoExtensionForMime(mimeType)}',
            bytes: bytes,
            mimeType: mimeType,
          ),
          attachmentType: 'video',
          durationMs: durationMs,
        );
      } else {
        await _sendMediaMessage(
          upload: _ChatUploadFile(
            filename: xfile.name.isNotEmpty
                ? xfile.name
                : xfile.path.split('/').last,
            path: xfile.path,
          ),
          attachmentType: 'video',
          durationMs: durationMs,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось отправить видеосообщение: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('stopVideoCircleRecordingAndSend error: $e');
    }
  }

  Future<void> _cancelVideoCircleRecording({
    String notice = 'Видеосообщение отменено',
  }) async {
    if (!_videoRecording && !_videoStartInProgress) {
      _videoRecordingLocked = false;
      _videoRecordingDragDx = 0;
      _videoRecordingDragDy = 0;
      return;
    }
    _videoRecordingTimer?.cancel();
    _videoRecordingTimer = null;
    _videoRecordingStartedAt = null;
    setState(() {
      _videoRecording = false;
      _videoRecordingLocked = false;
      _videoRecordingSeconds = 0;
      _videoRecordingDragDx = 0;
      _videoRecordingDragDy = 0;
    });
    try {
      if (_videoCameraController?.value.isRecordingVideo == true) {
        await _videoCameraController!.stopVideoRecording();
      }
    } catch (_) {}
    if (!mounted) return;
    showAppNotice(
      context,
      notice,
      tone: AppNoticeTone.info,
      duration: const Duration(milliseconds: 900),
    );
  }

  Future<void> _stopVoiceRecordingAndSend() async {
    if (!_voiceRecording) return;
    final startedAt = _voiceRecordingStartedAt;
    final durationMs = startedAt == null
        ? _recordingSeconds * 1000
        : DateTime.now().difference(startedAt).inMilliseconds;
    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;
    _voiceRecordingStartedAt = null;
    setState(() {
      _voiceRecording = false;
      _voiceRecordingLocked = false;
      _recordingSeconds = 0;
      _recordingDragDx = 0;
      _recordingDragDy = 0;
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
      if (durationMs < 1000) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Голосовое отменено (меньше 1 секунды)',
          tone: AppNoticeTone.info,
          duration: const Duration(milliseconds: 900),
        );
        return;
      }
      if (kIsWeb) {
        final bytes = await _readWebBlobBytes(recordedPath);
        if (bytes == null || bytes.isEmpty) {
          if (!mounted) return;
          showAppNotice(
            context,
            'Не удалось прочитать записанный файл',
            tone: AppNoticeTone.error,
            duration: const Duration(seconds: 2),
          );
          return;
        }
        await _sendMediaMessage(
          upload: _ChatUploadFile(
            filename:
                'voice-${DateTime.now().millisecondsSinceEpoch}.$_activeVoiceUploadExtension',
            bytes: bytes,
          ),
          attachmentType: 'voice',
          durationMs: durationMs,
        );
      } else {
        await _sendMediaMessage(
          upload: _ChatUploadFile(
            filename: recordedPath.split('/').last,
            path: recordedPath,
          ),
          attachmentType: 'voice',
          durationMs: durationMs,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось отправить голосовое сообщение: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('stopVoiceRecordingAndSend error: $e');
    }
  }

  Future<void> _cancelVoiceRecording({
    String notice = 'Голосовое отменено',
  }) async {
    if (!_voiceRecording && !_voiceStartInProgress) {
      _voiceRecordingLocked = false;
      _recordingDragDx = 0;
      _recordingDragDy = 0;
      return;
    }
    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;
    _voiceRecordingStartedAt = null;
    setState(() {
      _voiceRecording = false;
      _voiceRecordingLocked = false;
      _recordingSeconds = 0;
      _recordingDragDx = 0;
      _recordingDragDy = 0;
    });
    try {
      await _voiceRecorder.stop();
    } catch (_) {}
    if (!mounted) return;
    showAppNotice(
      context,
      notice,
      tone: AppNoticeTone.info,
      duration: const Duration(milliseconds: 900),
    );
  }

  void _toggleComposerMediaMode() {
    if (!_cameraSupported) {
      if (_composerMediaMode != _ComposerMediaMode.voice) {
        setState(() => _composerMediaMode = _ComposerMediaMode.voice);
      }
      return;
    }
    setState(() {
      _composerMediaMode = _composerMediaMode == _ComposerMediaMode.voice
          ? _ComposerMediaMode.camera
          : _ComposerMediaMode.voice;
    });
    if (_composerMediaMode == _ComposerMediaMode.camera && !kIsWeb) {
      unawaited(_ensureVideoCameraReady());
    }
  }

  void _cancelComposerMediaHoldTimer() {
    _composerMediaHoldTimer?.cancel();
    _composerMediaHoldTimer = null;
  }

  Future<void> _runComposerHoldAction() async {
    if (_composerHoldActionTriggered || !_composerMediaPressActive) return;
    _composerHoldActionTriggered = true;
    if (_composerMediaMode == _ComposerMediaMode.camera) {
      await _startVideoCircleRecording();
      return;
    }
    await _startVoiceRecording();
  }

  void _handleComposerMediaTap({
    required BuildContext context,
    required bool canCompose,
    required bool disabled,
  }) {
    if (disabled) {
      if (!canCompose && mounted) {
        showAppNotice(
          context,
          _composeBlockedReason() ?? 'Отправка сообщений недоступна',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
      }
      return;
    }
    final isDesktopWeb =
        kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;
    if (!_cameraSupported &&
        _composerMediaMode == _ComposerMediaMode.voice &&
        isDesktopWeb) {
      if (_voiceRecording) {
        unawaited(_stopVoiceRecordingAndSend());
      } else {
        unawaited(_startVoiceRecording(autoStopIfNotPressed: false));
      }
      return;
    }
    if (_voiceRecording || _videoRecording) return;
    _toggleComposerMediaMode();
  }

  void _handleComposerMediaTapDown({
    required bool disabled,
    required BuildContext context,
    required bool canCompose,
    required TapDownDetails details,
  }) {
    if (disabled) return;
    if (kIsWeb &&
        _composerMediaMode == _ComposerMediaMode.voice &&
        _webVoiceConfigsFuture == null) {
      // Warm up encoder support detection once to avoid a long delay on first hold.
      unawaited(_resolveWebVoiceRecordConfigs());
    }
    if (_composerMediaMode == _ComposerMediaMode.camera &&
        _videoCameraController == null &&
        !kIsWeb) {
      unawaited(_ensureVideoCameraReady());
    }
    _composerMediaPressActive = true;
    _composerPressStartGlobal = details.globalPosition;
    _composerHoldActionTriggered = false;
    _cancelComposerMediaHoldTimer();
    _composerMediaHoldTimer = Timer(const Duration(milliseconds: 160), () {
      unawaited(_runComposerHoldAction());
    });
  }

  Future<void> _handleComposerMediaTapUp({
    required bool disabled,
    required BuildContext context,
    required bool canCompose,
  }) async {
    final holdTriggered = _composerHoldActionTriggered;
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();

    if (holdTriggered) {
      if (_composerMediaMode == _ComposerMediaMode.camera) {
        if (_videoRecording && !_videoRecordingLocked) {
          await _stopVideoCircleRecordingAndSend();
        }
      } else if (_voiceRecording && !_voiceRecordingLocked) {
        await _stopVoiceRecordingAndSend();
      }
      return;
    }

    _handleComposerMediaTap(
      context: context,
      canCompose: canCompose,
      disabled: disabled,
    );
  }

  void _handleComposerMediaTapCancel() {
    if (_composerHoldActionTriggered ||
        _anyComposerRecording ||
        _anyRecorderStarting) {
      return;
    }
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();
  }

  void _handleComposerMediaPanUpdate(DragUpdateDetails details) {
    if (!_composerMediaPressActive) return;
    final start = _composerPressStartGlobal;
    if (start == null) return;
    final dx = details.globalPosition.dx - start.dx;
    final dy = details.globalPosition.dy - start.dy;
    if (_voiceRecording && mounted) {
      setState(() {
        _recordingDragDx = dx;
        _recordingDragDy = dy;
      });
    }
    if (_videoRecording && mounted) {
      setState(() {
        _videoRecordingDragDx = dx;
        _videoRecordingDragDy = dy;
      });
    }
    if (_voiceRecording && !_voiceRecordingLocked) {
      if (dx <= -88) {
        unawaited(
          _cancelVoiceRecording(notice: 'Голосовое отменено (свайп влево)'),
        );
        _composerMediaPressActive = false;
        _cancelComposerMediaHoldTimer();
        return;
      }
      if (dy <= -72) {
        setState(() {
          _voiceRecordingLocked = true;
        });
        showAppNotice(
          context,
          'Запись зафиксирована',
          tone: AppNoticeTone.info,
          duration: const Duration(milliseconds: 900),
        );
      }
      return;
    }
    if (_videoRecording && !_videoRecordingLocked) {
      if (dx <= -88) {
        unawaited(
          _cancelVideoCircleRecording(
            notice: 'Видеосообщение отменено (свайп влево)',
          ),
        );
        _composerMediaPressActive = false;
        _cancelComposerMediaHoldTimer();
        return;
      }
      if (dy <= -72) {
        setState(() {
          _videoRecordingLocked = true;
        });
        showAppNotice(
          context,
          'Видеозапись зафиксирована',
          tone: AppNoticeTone.info,
          duration: const Duration(milliseconds: 900),
        );
      }
    }
  }

  void _handleComposerMediaPanEnd() {
    final holdTriggered = _composerHoldActionTriggered;
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();
    if (!holdTriggered) return;
    if (_composerMediaMode == _ComposerMediaMode.voice &&
        _voiceRecording &&
        !_voiceRecordingLocked) {
      unawaited(_stopVoiceRecordingAndSend());
      return;
    }
    if (_composerMediaMode == _ComposerMediaMode.camera &&
        _videoRecording &&
        !_videoRecordingLocked) {
      unawaited(_stopVideoCircleRecordingAndSend());
    }
  }

  void _handleComposerMediaPanCancel() {
    final holdTriggered = _composerHoldActionTriggered;
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();
    if (!holdTriggered) return;
    if (_composerMediaMode == _ComposerMediaMode.camera) {
      unawaited(_cancelVideoCircleRecording());
      return;
    }
    unawaited(_cancelVoiceRecording(notice: 'Голосовое отменено'));
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

      await _stopInlineVideoNotePlayback();
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

  Future<void> _stopInlineVideoNotePlayback({
    bool clearSelection = true,
    bool notify = true,
  }) async {
    if (kIsWeb) {
      if (notify && mounted) {
        setState(() {
          _inlineVideoNoteInitializing = false;
          if (clearSelection) {
            _activeVideoNoteMessageId = null;
          }
        });
      } else {
        _inlineVideoNoteInitializing = false;
        if (clearSelection) {
          _activeVideoNoteMessageId = null;
        }
      }
      return;
    }

    final controller = _inlineVideoNoteController;
    _inlineVideoNoteController = null;

    if (notify && mounted) {
      setState(() {
        _inlineVideoNoteInitializing = false;
        if (clearSelection) {
          _activeVideoNoteMessageId = null;
        }
      });
    } else {
      _inlineVideoNoteInitializing = false;
      if (clearSelection) {
        _activeVideoNoteMessageId = null;
      }
    }

    if (controller != null) {
      try {
        await controller.pause();
      } catch (_) {}
      await controller.dispose();
    }
  }

  Future<void> _toggleInlineVideoNotePlayback(
    String messageId,
    String videoUrl,
  ) async {
    final trimmedMessageId = messageId.trim();
    final trimmedVideoUrl = videoUrl.trim();
    if (trimmedMessageId.isEmpty || trimmedVideoUrl.isEmpty) return;

    if (kIsWeb) {
      try {
        await _voicePlayer.stop();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _activeVoiceMessageId = null;
        _activeVoicePosition = Duration.zero;
        _activeVoiceDuration = Duration.zero;
        _voicePlayerState = PlayerState.stopped;
        _inlineVideoNoteInitializing = false;
        _activeVideoNoteMessageId = trimmedMessageId;
      });
      return;
    }

    final currentController = _inlineVideoNoteController;
    final isCurrent =
        _activeVideoNoteMessageId == trimmedMessageId &&
        currentController != null;

    if (isCurrent && currentController.value.isInitialized) {
      try {
        if (currentController.value.isPlaying) {
          await currentController.pause();
        } else {
          final duration = currentController.value.duration;
          final position = currentController.value.position;
          if (duration > Duration.zero &&
              position >= duration - const Duration(milliseconds: 240)) {
            await currentController.seekTo(Duration.zero);
          }
          await currentController.play();
        }
        if (mounted) {
          setState(() {});
        }
      } catch (e) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Не удалось воспроизвести видеокружок',
          tone: AppNoticeTone.error,
          duration: const Duration(seconds: 2),
        );
        debugPrint('toggleInlineVideoNotePlayback error: $e');
      }
      return;
    }

    if (_inlineVideoNoteInitializing) return;

    final parsed = Uri.tryParse(trimmedVideoUrl);
    if (parsed == null) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Некорректная ссылка на видеокружок',
        tone: AppNoticeTone.warning,
        duration: const Duration(seconds: 2),
      );
      return;
    }

    await _stopInlineVideoNotePlayback(clearSelection: false);
    if (!mounted) return;

    try {
      await _voicePlayer.stop();
      if (_activeVoiceMessageId != null ||
          _activeVoicePosition > Duration.zero ||
          _activeVoiceDuration > Duration.zero ||
          _voicePlayerState != PlayerState.stopped) {
        setState(() {
          _activeVoiceMessageId = null;
          _activeVoicePosition = Duration.zero;
          _activeVoiceDuration = Duration.zero;
          _voicePlayerState = PlayerState.stopped;
        });
      }
    } catch (_) {}

    final controller = vp.VideoPlayerController.networkUrl(
      parsed,
      videoPlayerOptions: vp.VideoPlayerOptions(mixWithOthers: false),
    );

    setState(() {
      _activeVideoNoteMessageId = trimmedMessageId;
      _inlineVideoNoteInitializing = true;
      _inlineVideoNoteController = controller;
    });

    try {
      await controller.initialize();
      await controller.setLooping(false);
      if (!mounted ||
          _inlineVideoNoteController != controller ||
          _activeVideoNoteMessageId != trimmedMessageId) {
        await controller.dispose();
        return;
      }
      setState(() => _inlineVideoNoteInitializing = false);
      await controller.play();
    } catch (e) {
      if (_inlineVideoNoteController == controller) {
        _inlineVideoNoteController = null;
      }
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _inlineVideoNoteInitializing = false;
        _activeVideoNoteMessageId = null;
      });
      showAppNotice(
        context,
        'Не удалось воспроизвести видеокружок',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('toggleInlineVideoNotePlayback error: $e');
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
      if (_isLikelyOfflineBuyError(e)) {
        final user = authService.currentUser;
        final userId = user?.id.trim() ?? '';
        if (userId.isNotEmpty) {
          try {
            final queued = await offlinePurchaseQueueService.enqueuePurchase(
              userId: userId,
              tenantCode: user?.tenantCode,
              productId: productId,
              quantity: 1,
              sourceChatId: widget.chatId,
            );
            if (!mounted) return;
            showAppNotice(
              context,
              'Нет сети. Покупка сохранена оффлайн (${queued.quantity} шт.). '
              'Отправим автоматически, как только появится интернет.',
              tone: AppNoticeTone.warning,
              duration: const Duration(seconds: 3),
            );
            await playAppSound(AppUiSound.warning);
            return;
          } catch (_) {
            // fallback to common error toast below
          }
        }
      }
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

  bool _isLikelyOfflineBuyError(Object e) {
    if (e is! DioException) return false;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    final text = (e.message ?? '').toLowerCase();
    return text.contains('connection refused') ||
        text.contains('failed host lookup') ||
        text.contains('socketexception') ||
        text.contains('network is unreachable');
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

  bool _isReservedOrdersChat() {
    if ((widget.chatType ?? '').toLowerCase().trim() != 'channel') return false;
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    final title = widget.chatTitle.toLowerCase().trim();
    return kind == 'reserved_orders' ||
        systemKey == 'reserved_orders' ||
        title == 'забронированный товар';
  }

  String? _reservedProductCodeOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final directCode = int.tryParse((meta['product_code'] ?? '').toString());
    if (directCode != null && directCode > 0) {
      return directCode.toString();
    }

    final label = (meta['product_label'] ?? '').toString().trim();
    if (label.isNotEmpty) {
      final fromLabel = label
          .split('--')
          .first
          .trim()
          .replaceAll(RegExp(r'\D'), '');
      if (fromLabel.isNotEmpty) {
        return fromLabel;
      }
    }

    final text = (message['text'] ?? '').toString();
    final fromText = RegExp(
      r'ID\s*товара\s*:\s*([0-9]+)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    final normalizedTextCode = (fromText ?? '').trim();
    if (normalizedTextCode.isNotEmpty) {
      return normalizedTextCode;
    }
    return null;
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

  bool _requiresManualShelfOnPlaced() {
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
      var addressDraft = (meta['address_text'] ?? '').toString();
      var afterDraft = (meta['preferred_time_from'] ?? '').toString();
      var beforeDraft = (meta['preferred_time_to'] ?? '').toString();
      final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Адрес доставки'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: addressDraft,
                  onChanged: (value) => addressDraft = value,
                  minLines: 2,
                  maxLines: 4,
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      hintText: 'Самара, улица, дом, подъезд',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: afterDraft,
                        onChanged: (value) => afterDraft = value,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'После',
                            hintText: '10:00',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        initialValue: beforeDraft,
                        onChanged: (value) => beforeDraft = value,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'До',
                            hintText: '16:00',
                            border: OutlineInputBorder(),
                          ),
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
                'address_text': addressDraft.trim(),
                'preferred_time_from': afterDraft.trim(),
                'preferred_time_to': beforeDraft.trim(),
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
    final knownShelfRaw = int.tryParse(
      (meta['shelf_number'] ?? '').toString().trim(),
    );
    final knownShelf = (knownShelfRaw != null && knownShelfRaw > 0)
        ? knownShelfRaw
        : null;

    setState(() => _markingPlaced = true);
    try {
      final reservationIdValue = (reservationId ?? '').trim();
      final cartItemIdValue = (cartItemId ?? '').trim();
      Future<Response<dynamic>> sendMarkPlaced({
        int? shelfNumber,
        bool manualShelf = false,
      }) {
        final shelfValue = shelfNumber != null && shelfNumber > 0
            ? shelfNumber.toString()
            : '';
        return authService.dio.post(
          '/api/admin/orders/mark_placed',
          data: {
            if (reservationIdValue.isNotEmpty)
              'reservation_id': reservationIdValue,
            if (cartItemIdValue.isNotEmpty) 'cart_item_id': cartItemIdValue,
            if (shelfValue.isNotEmpty) 'shelf_number': shelfValue,
            if (manualShelf) 'manual_shelf': true,
          },
        );
      }

      Response<dynamic> resp;
      final requiresManualByRole = _requiresManualShelfOnPlaced();
      try {
        // Для админского потока не подставляем полку автоматически:
        // первый товар должен быть подтвержден ручным вводом.
        resp = await sendMarkPlaced(
          shelfNumber: requiresManualByRole ? null : knownShelf,
        );
      } on DioException catch (e) {
        final rawData = e.response?.data;
        final responseMap = rawData is Map
            ? Map<String, dynamic>.from(rawData)
            : const <String, dynamic>{};
        final errorCode = (responseMap['code'] ?? '').toString().trim();
        final serverMessage = _extractDioError(e).toLowerCase();
        final needsManualShelf =
            requiresManualByRole &&
            (errorCode == 'manual_shelf_required' ||
                serverMessage.contains('вручную указать номер полки'));
        if (!needsManualShelf) rethrow;
        if (!mounted) return;

        var shelfDraft = '';
        final manualShelf = await showDialog<int>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Укажите полку'),
            content: TextFormField(
              initialValue: shelfDraft,
              onChanged: (value) => shelfDraft = value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Номер полки',
                hintText: 'Например: 3',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(shelfDraft.trim());
                  if (parsed == null || parsed <= 0) {
                    showAppNotice(
                      context,
                      'Введите корректный номер полки',
                      tone: AppNoticeTone.warning,
                      duration: const Duration(seconds: 2),
                    );
                    return;
                  }
                  Navigator.of(ctx).pop(parsed);
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
        if (manualShelf == null) return;
        resp = await sendMarkPlaced(
          shelfNumber: manualShelf,
          manualShelf: true,
        );
      }
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
    final rawQuery = query.trim();
    if (rawQuery.isEmpty) return true;
    if (RegExp(r'^\d+$').hasMatch(rawQuery) &&
        (_isReservedOrdersChat() || _isReservedOrder(message))) {
      final productCode = _reservedProductCodeOf(message);
      if (productCode == null || productCode.isEmpty) return false;
      return productCode == rawQuery;
    }

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

  void _recomputeSearchResults({bool keepCurrent = true}) {
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      if (_searchResultIds.isEmpty && _searchResultIndex == -1) return;
      if (!mounted) {
        _searchResultIds = const [];
        _searchResultIndex = -1;
        return;
      }
      setState(() {
        _searchResultIds = const [];
        _searchResultIndex = -1;
      });
      return;
    }

    final matches = _visibleMessages()
        .map((message) => (message['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final currentId =
        keepCurrent &&
            _searchResultIndex >= 0 &&
            _searchResultIndex < _searchResultIds.length
        ? _searchResultIds[_searchResultIndex]
        : null;

    var nextIndex = matches.isEmpty ? -1 : 0;
    if (currentId != null) {
      final keepIndex = matches.indexOf(currentId);
      if (keepIndex >= 0) {
        nextIndex = keepIndex;
      }
    }

    if (listEquals(matches, _searchResultIds) &&
        nextIndex == _searchResultIndex) {
      return;
    }

    if (!mounted) {
      _searchResultIds = matches;
      _searchResultIndex = nextIndex;
      return;
    }
    setState(() {
      _searchResultIds = matches;
      _searchResultIndex = nextIndex;
    });
  }

  Future<void> _jumpToSearchResult(int index) async {
    if (index < 0 || index >= _searchResultIds.length) return;
    final messageId = _searchResultIds[index];
    final targetContext = await _resolveMessageContextWithScroll(messageId);
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 240),
      alignment: 0.18,
      curve: Curves.easeOutCubic,
    );
  }

  void _moveSearchResult(int delta) {
    if (_searchResultIds.isEmpty) return;
    final length = _searchResultIds.length;
    final base = _searchResultIndex < 0 ? 0 : _searchResultIndex;
    final next = (base + delta) % length;
    final normalized = next < 0 ? next + length : next;
    setState(() => _searchResultIndex = normalized);
    unawaited(_jumpToSearchResult(normalized));
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

  String _formatProductLabel(dynamic productCode, dynamic shelfNumber) {
    final code = int.tryParse('${productCode ?? ''}') ?? 0;
    final shelf = int.tryParse('${shelfNumber ?? ''}') ?? 0;
    final codePart = code > 0 ? '$code' : '—';
    final shelfPart = shelf > 0 ? shelf.toString().padLeft(2, '0') : '—';
    return '$codePart--$shelfPart';
  }

  String? _resolveImageUrl(String? raw) {
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
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
        text.toLowerCase() == 'голосовое сообщение' ||
        text.toLowerCase() == 'видеосообщение') {
      return '';
    }
    return text;
  }

  Widget _buildHighlightedText(
    String source, {
    TextStyle? style,
    int? maxLines,
    TextOverflow overflow = TextOverflow.clip,
  }) {
    final text = source;
    final query = _searchQuery.trim();
    if (query.isEmpty || text.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var cursor = 0;
    final spans = <TextSpan>[];
    final theme = Theme.of(context);

    while (cursor < text.length) {
      final matchIndex = lowerText.indexOf(lowerQuery, cursor);
      if (matchIndex < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (matchIndex > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, matchIndex)));
      }
      final end = matchIndex + lowerQuery.length;
      spans.add(
        TextSpan(
          text: text.substring(matchIndex, end),
          style: TextStyle(
            backgroundColor: theme.colorScheme.secondaryContainer,
            color: theme.colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = end;
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  String? _voiceUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(meta['voice_url']?.toString());
  }

  int _voiceDurationMsOf(Map<String, dynamic> meta) {
    return int.tryParse('${meta['voice_duration_ms'] ?? 0}') ?? 0;
  }

  String? _videoUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(meta['video_url']?.toString());
  }

  int _videoDurationMsOf(Map<String, dynamic> meta) {
    return int.tryParse('${meta['video_duration_ms'] ?? 0}') ?? 0;
  }

  Map<String, String> _reactionByUserOf(Map<String, dynamic> meta) {
    final raw = meta['reactions_by_user'];
    if (raw is! Map) return const <String, String>{};
    final normalized = <String, String>{};
    raw.forEach((key, value) {
      final userId = '$key'.trim();
      final emoji = '$value'.trim();
      if (userId.isEmpty || emoji.isEmpty) return;
      normalized[userId] = emoji;
    });
    return normalized;
  }

  Future<void> _toggleMessageReaction(String messageId, String emoji) async {
    final trimmedMessageId = messageId.trim();
    final trimmedEmoji = emoji.trim();
    if (trimmedMessageId.isEmpty || trimmedEmoji.isEmpty) return;
    if (mounted) {
      setState(() => _rememberRecentEmoji(_recentReactionEmojis, trimmedEmoji));
    }
    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/messages/$trimmedMessageId/reactions',
        data: {'emoji': trimmedEmoji},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        _upsertMessage(
          Map<String, dynamic>.from(data['data']),
          autoScroll: false,
        );
      }
    } on DioException catch (e) {
      if (!mounted) return;
      final status = e.response?.statusCode;
      if (status == 404) {
        final data = e.response?.data;
        final path = data is Map ? '${data['path'] ?? ''}'.trim() : '';
        final errorText = data is Map
            ? '${data['error'] ?? data['message'] ?? ''}'.toLowerCase().trim()
            : '';
        final looksLikeMissingRoute =
            path.contains('/reactions') && errorText.contains('not found');
        final looksLikeMissingMessage = errorText.contains(
          'сообщение не найдено',
        );
        showAppNotice(
          context,
          looksLikeMissingRoute
              ? 'Реакции недоступны: сервер не обновлён (маршрут /reactions не найден)'
              : looksLikeMissingMessage
              ? 'Сообщение больше недоступно для реакции'
              : 'Не удалось поставить реакцию',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 3),
        );
      } else {
        showAppNotice(
          context,
          'Не удалось поставить реакцию',
          tone: AppNoticeTone.error,
          duration: const Duration(seconds: 2),
        );
      }
      debugPrint('toggleMessageReaction error: $e');
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось поставить реакцию',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('toggleMessageReaction error: $e');
    }
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
    var nextDraft = current;
    final nextText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Изменить сообщение'),
        content: TextFormField(
          initialValue: current,
          onChanged: (value) => nextDraft = value,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: withInputLanguageBadge(
            const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(nextDraft.trim()),
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
    required bool canReact,
  }) async {
    final text = (message['text'] ?? '').toString();
    final imageUrl = _resolveImageUrl(
      _metaMapOf(message['meta'])['image_url']?.toString(),
    );
    final reactionByUser = _reactionByUserOf(_metaMapOf(message['meta']));
    final currentUserId = authService.currentUser?.id.trim() ?? '';

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
      } else if (action == 'forward') {
        if (!mounted) return;
        showAppNotice(
          context,
          'Пересылка появится в следующем обновлении',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
      } else if (action == 'select') {
        if (!mounted) return;
        showAppNotice(
          context,
          'Режим выбора сообщений появится в следующем обновлении',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
      } else if (action.startsWith('react:') && canReact) {
        final messageId = message['id']?.toString() ?? '';
        final emoji = action.substring('react:'.length).trim();
        if (messageId.isNotEmpty && emoji.isNotEmpty) {
          await _toggleMessageReaction(messageId, emoji);
        }
      }
    }

    final reactionChoices = canReact
        ? _reactionPickerEmojis()
        : const <String>[];
    final hasMenuItems =
        canReply ||
        canCopy ||
        canPin ||
        canOpenImage ||
        canCopyId ||
        canEdit ||
        canDeleteForMe ||
        canDeleteForAll ||
        canDeleteEntireChat;
    if (!hasMenuItems && reactionChoices.isEmpty) return;

    Widget buildActionPanel(BuildContext ctx, {required bool desktop}) {
      final theme = Theme.of(ctx);
      final topBarColor = theme.brightness == Brightness.dark
          ? const Color(0xFF1A2638).withValues(alpha: 0.82)
          : theme.colorScheme.primaryContainer.withValues(alpha: 0.86);
      final surfaceColor = theme.colorScheme.surface.withValues(alpha: 0.84);

      Widget glass({required Widget child, EdgeInsetsGeometry? padding}) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              color: surfaceColor,
              padding: padding,
              child: child,
            ),
          ),
        );
      }

      Widget actionTile(
        String value, {
        required IconData icon,
        required String title,
        Color? color,
      }) {
        return ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          leading: Icon(icon, color: color),
          title: Text(title, style: TextStyle(color: color)),
          onTap: () => Navigator.of(ctx).pop(value),
        );
      }

      final actionWidgets = <Widget>[
        if (canReply)
          actionTile('reply', icon: Icons.reply_outlined, title: 'Ответить'),
        if (canCopy)
          actionTile(
            'copy',
            icon: Icons.copy_all_outlined,
            title: 'Копировать текст',
          ),
        if (canPin)
          actionTile(
            isPinned ? 'unpin' : 'pin',
            icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin,
            title: isPinned ? 'Открепить' : 'Закрепить',
          ),
        if (canCopy)
          actionTile(
            'forward',
            icon: Icons.forward_to_inbox_outlined,
            title: 'Переслать',
          ),
        if (canCopy)
          actionTile(
            'select',
            icon: Icons.check_circle_outline_rounded,
            title: 'Выбрать',
          ),
        if (canOpenImage)
          actionTile(
            'open_image',
            icon: Icons.image_outlined,
            title: 'Открыть фото',
          ),
        if (canCopyId)
          actionTile(
            'copy_id',
            icon: Icons.tag_outlined,
            title: 'Копировать ID',
          ),
        if (canEdit)
          actionTile('edit', icon: Icons.edit_outlined, title: 'Изменить'),
        if (canDeleteForMe)
          actionTile(
            'delete_me',
            icon: Icons.remove_circle_outline,
            title: 'Удалить у меня',
          ),
        if (canDeleteForAll)
          actionTile(
            'delete_all',
            icon: Icons.delete_outline,
            title: 'Удалить у всех',
            color: Colors.red,
          ),
        if (canDeleteEntireChat)
          actionTile(
            'delete_chat',
            icon: Icons.delete_forever_outlined,
            title: 'УДАЛИТЬ ВСЁ!',
            color: Colors.red,
          ),
      ];

      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: desktop ? 460 : double.infinity,
          maxHeight: MediaQuery.sizeOf(ctx).height * (desktop ? 0.82 : 0.72),
        ),
        child: Column(
          mainAxisSize: hasMenuItems ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (reactionChoices.isNotEmpty)
              glass(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: topBarColor,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      children: reactionChoices.map((emoji) {
                        final mine =
                            currentUserId.isNotEmpty &&
                            reactionByUser[currentUserId] == emoji;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => Navigator.of(ctx).pop('react:$emoji'),
                            child: Ink(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: mine
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.22,
                                      )
                                    : Colors.transparent,
                              ),
                              child: Text(
                                emoji,
                                style: const TextStyle(fontSize: 30),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            if (hasMenuItems) ...[
              if (reactionChoices.isNotEmpty) const SizedBox(height: 8),
              Flexible(
                child: glass(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: actionWidgets,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (!mounted) return;
    final isDesktopLike = secondaryTap != null;
    final modalContext = context;
    final selected = isDesktopLike
        // ignore: use_build_context_synchronously
        ? await showDialog<String>(
            // ignore: use_build_context_synchronously
            context: modalContext,
            barrierColor: Colors.black.withValues(alpha: 0.38),
            builder: (ctx) => Dialog(
              elevation: 0,
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 24,
              ),
              child: buildActionPanel(ctx, desktop: true),
            ),
          )
        // ignore: use_build_context_synchronously
        : await showModalBottomSheet<String>(
            // ignore: use_build_context_synchronously
            context: modalContext,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (ctx) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: buildActionPanel(ctx, desktop: false),
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
    final waveform = _buildVoiceWaveform(theme, messageId, progress);
    final shellColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.10),
      theme.colorScheme.surface,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
      decoration: BoxDecoration(
        color: shellColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.14),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: voiceUrl == null
                ? null
                : () => _toggleVoicePlayback(messageId, voiceUrl),
            child: Ink(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: 0.85),
                    theme.colorScheme.primary.withValues(alpha: 0.65),
                  ],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.24),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                waveform,
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      isActive && currentPosition > Duration.zero
                          ? _formatDurationLabel(currentPosition)
                          : _formatDurationLabel(totalDuration),
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'голосовое',
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.72),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceWaveform(ThemeData theme, String seed, double progress) {
    final bars = _voiceWaveHeights(seed, 30);
    final activeBars = (bars.length * progress).round();
    return SizedBox(
      height: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(bars.length, (index) {
          final played = index < activeBars;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.7),
              child: Container(
                height: bars[index],
                decoration: BoxDecoration(
                  color: played
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.38,
                        ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  List<double> _voiceWaveHeights(String seed, int count) {
    final safeCount = count < 8 ? 8 : count;
    final random = Random(seed.hashCode);
    return List<double>.generate(safeCount, (_) {
      final base = 4 + random.nextInt(12); // 4..15
      return base.toDouble();
    });
  }

  Future<void> _switchVideoCameraLens() async {
    if (_availableCameras.length < 2 || _videoRecording) return;
    final currentName = _videoCameraController?.description.name;
    cam.CameraDescription? nextCamera;
    for (final camera in _availableCameras) {
      if (camera.name != currentName) {
        nextCamera = camera;
        break;
      }
    }
    if (nextCamera == null) return;
    try {
      final next = cam.CameraController(
        nextCamera,
        cam.ResolutionPreset.medium,
        enableAudio: true,
      );
      await next.initialize();
      try {
        await next.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}
      try {
        await next.setFlashMode(cam.FlashMode.off);
      } catch (_) {}
      final previous = _videoCameraController;
      setState(() => _videoCameraController = next);
      if (previous != null) {
        await previous.dispose();
      }
    } catch (e) {
      debugPrint('switchVideoCameraLens error: $e');
    }
  }

  Widget _buildComposerActionBubble({
    required IconData icon,
    required VoidCallback? onTap,
    required Color color,
    double size = 54,
    bool filled = true,
  }) {
    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? color : color.withValues(alpha: 0.14),
        border: filled
            ? null
            : Border.all(color: color.withValues(alpha: 0.24)),
        boxShadow: filled
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Icon(
        icon,
        color: filled ? Colors.white : color,
        size: size * 0.42,
      ),
    );
    if (onTap == null) return bubble;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: bubble,
    );
  }

  Widget _buildRecordingHintChip({
    required IconData icon,
    required String label,
    required double progress,
  }) {
    final visible = progress > 0.02;
    return IgnorePointer(
      ignoring: true,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 140),
        opacity: visible ? (0.45 + progress * 0.55).clamp(0.0, 1.0) : 0,
        child: Transform.translate(
          offset: Offset(0, -6 * progress),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF12181F).withValues(alpha: 0.90),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.84),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceRecordingBar(ThemeData theme) {
    final barColor = const Color(0xFF12181F).withValues(alpha: 0.97);
    final cancelProgress = _normalizedProgress(-_recordingDragDx, 96);
    final lockProgress = _normalizedProgress(-_recordingDragDy, 76);
    final cancelTextShift = (_recordingDragDx.clamp(-54, 0)).toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF4D5B),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFFFF4D5B,
                            ).withValues(alpha: 0.4),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _formatDurationLabel(
                        Duration(seconds: _recordingSeconds),
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRect(
                        child: Transform.translate(
                          offset: Offset(cancelTextShift, 0),
                          child: Row(
                            children: [
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 90),
                                opacity: _voiceRecordingLocked
                                    ? 0
                                    : (1 - cancelProgress * 0.82).clamp(
                                        0.18,
                                        1.0,
                                      ),
                                child: Icon(
                                  Icons.chevron_left_rounded,
                                  color: Colors.white.withValues(alpha: 0.55),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  _voiceRecordingLocked
                                      ? 'Запись зафиксирована'
                                      : 'Влево — отмена',
                                  style: TextStyle(
                                    color: Colors.white.withValues(
                                      alpha: _voiceRecordingLocked
                                          ? 0.92
                                          : (0.72 + cancelProgress * 0.16)
                                                .clamp(0.0, 1.0),
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_voiceRecordingLocked)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        child: TextButton(
                          onPressed: () => unawaited(_cancelVoiceRecording()),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          child: const Text('Отмена'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_voiceRecordingLocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildRecordingHintChip(
                      icon: Icons.lock_outline_rounded,
                      label: 'Вверх — зафиксировать',
                      progress: max(lockProgress, 0.20),
                    ),
                  ),
                _buildComposerActionBubble(
                  icon: _voiceRecordingLocked
                      ? Icons.arrow_upward_rounded
                      : Icons.mic_rounded,
                  onTap: _voiceRecordingLocked
                      ? () => unawaited(_stopVoiceRecordingAndSend())
                      : null,
                  color: const Color(0xFF2F80FF),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoRecordingOrb(ThemeData theme) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final size = min(viewportWidth * 0.68, 292.0);
    final controller = _videoCameraController;
    Widget child;
    if (controller != null && controller.value.isInitialized) {
      final previewSize = controller.value.previewSize;
      Widget preview = cam.CameraPreview(controller);
      if (controller.description.lensDirection ==
          cam.CameraLensDirection.front) {
        preview = Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(-1, 1, 1),
          child: preview,
        );
      }
      child = ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: previewSize?.height ?? size,
              height: previewSize?.width ?? size,
              child: preview,
            ),
          ),
        ),
      );
    } else {
      child = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3C2A68), Color(0xFF241631)],
          ),
        ),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }
    return AnimatedScale(
      duration: const Duration(milliseconds: 180),
      scale: _videoRecording ? 1 : 0.96,
      child: Container(
        width: size + 12,
        height: size + 12,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF5F8FFF).withValues(alpha: 0.72),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.36),
              blurRadius: 26,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  Widget _buildVideoRecordingBar(ThemeData theme) {
    final barColor = const Color(0xFF12181F).withValues(alpha: 0.94);
    final cancelProgress = _normalizedProgress(-_videoRecordingDragDx, 96);
    final lockProgress = _normalizedProgress(-_videoRecordingDragDy, 76);
    final cancelTextShift = (_videoRecordingDragDx.clamp(-54, 0)).toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Row(
          children: [
            _buildComposerActionBubble(
              icon: Icons.cameraswitch_rounded,
              onTap: _videoRecording
                  ? null
                  : () => unawaited(_switchVideoCameraLens()),
              color: Colors.white,
              size: 44,
              filled: false,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF4D5B),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _formatDurationLabel(
                        Duration(seconds: _videoRecordingSeconds),
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRect(
                        child: Transform.translate(
                          offset: Offset(cancelTextShift, 0),
                          child: Row(
                            children: [
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 90),
                                opacity: _videoRecordingLocked
                                    ? 0
                                    : (1 - cancelProgress * 0.82).clamp(
                                        0.18,
                                        1.0,
                                      ),
                                child: Icon(
                                  Icons.chevron_left_rounded,
                                  color: Colors.white.withValues(alpha: 0.55),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  _videoRecordingLocked
                                      ? 'Видеозапись зафиксирована'
                                      : 'Влево — отмена',
                                  style: TextStyle(
                                    color: Colors.white.withValues(
                                      alpha: _videoRecordingLocked
                                          ? 0.92
                                          : (0.72 + cancelProgress * 0.16)
                                                .clamp(0.0, 1.0),
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_videoRecordingLocked)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        child: TextButton(
                          onPressed: () =>
                              unawaited(_cancelVideoCircleRecording()),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          child: const Text('Отмена'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_videoRecordingLocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildRecordingHintChip(
                      icon: Icons.lock_outline_rounded,
                      label: 'Вверх — зафиксировать',
                      progress: max(lockProgress, 0.20),
                    ),
                  ),
                _buildComposerActionBubble(
                  icon: Icons.arrow_upward_rounded,
                  onTap: () => unawaited(_stopVideoCircleRecordingAndSend()),
                  color: const Color(0xFF2F80FF),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoNoteAttachment(
    ThemeData theme,
    Map<String, dynamic> message,
    Map<String, dynamic> meta, {
    required Color textColor,
  }) {
    final videoUrl = _videoUrlOf(meta);
    final durationMs = _videoDurationMsOf(meta);
    final messageId = message['id']?.toString().trim() ?? '';
    final accent = theme.colorScheme.primary;
    final seed = messageId.isEmpty ? meta.toString() : messageId;
    final bars = _voiceWaveHeights(seed, 18);
    final isActive = _activeVideoNoteMessageId == messageId;
    final useInlineWebVideo = kIsWeb && videoUrl != null;
    final controller = isActive ? _inlineVideoNoteController : null;
    final shellGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent.withValues(alpha: 0.82), const Color(0xFF1C2631)],
    );

    Widget buildVideoOrb({
      required Widget content,
      required String badgeLabel,
      required String footerLabel,
      required String durationLabel,
      required IconData actionIcon,
      required double actionProgress,
      bool showSpinner = false,
      bool isPlaying = false,
    }) {
      return Container(
        width: 196,
        height: 196,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: shellGradient,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipOval(
                child: ColoredBox(
                  color: const Color(0xFF11161D),
                  child: content,
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ClipOval(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.06),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.30),
                        ],
                        stops: const [0, 0.56, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isPlaying
                          ? Icons.equalizer_rounded
                          : Icons.videocam_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      badgeLabel,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.94),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: actionProgress.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.18),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          footerLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.86),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          durationLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Center(
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 74,
                      height: 74,
                      child: CircularProgressIndicator(
                        value: showSpinner
                            ? null
                            : actionProgress.clamp(0.0, 1.0),
                        strokeWidth: 3.2,
                        backgroundColor: Colors.white.withValues(alpha: 0.14),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 10,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: showSpinner
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  accent,
                                ),
                              ),
                            )
                          : Icon(actionIcon, color: accent, size: 34),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget inactiveVideoBackdrop() {
      return Stack(
        children: [
          Positioned.fill(
            child: ClipOval(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.25, -0.35),
                    radius: 1.0,
                    colors: [
                      Colors.white.withValues(alpha: 0.22),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 58,
            child: SizedBox(
              height: 24,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(bars.length, (index) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        height: 6 + bars[index],
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: index.isEven ? 0.58 : 0.40,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      );
    }

    Widget activeVideoOrb() {
      if (kIsWeb && videoUrl != null) {
        return InlineVideoNoteOrb(
          videoUrl: videoUrl,
          durationMs: durationMs,
          accentColor: accent,
          footerText: 'Нажмите, чтобы продолжить',
        );
      }

      final activeController = controller;
      if (activeController == null) {
        return buildVideoOrb(
          content: inactiveVideoBackdrop(),
          badgeLabel: 'загрузка',
          footerLabel: 'Подготавливаем воспроизведение',
          durationLabel: durationMs > 0
              ? _formatDurationLabel(Duration(milliseconds: durationMs))
              : '00:00',
          actionIcon: Icons.hourglass_top_rounded,
          actionProgress: 0,
          showSpinner: true,
        );
      }
      return ValueListenableBuilder<vp.VideoPlayerValue>(
        valueListenable: activeController,
        builder: (context, value, _) {
          final initialized = value.isInitialized;
          final totalDuration = initialized && value.duration > Duration.zero
              ? value.duration
              : Duration(milliseconds: durationMs > 0 ? durationMs : 0);
          final position = initialized ? value.position : Duration.zero;
          final progress = totalDuration.inMilliseconds > 0
              ? (position.inMilliseconds / totalDuration.inMilliseconds)
                    .clamp(0.0, 1.0)
                    .toDouble()
              : 0.0;
          final hasFinished =
              totalDuration > Duration.zero &&
              position >= totalDuration - const Duration(milliseconds: 180) &&
              !value.isPlaying;
          final playIcon = value.isPlaying
              ? Icons.pause_rounded
              : hasFinished
              ? Icons.replay_rounded
              : Icons.play_arrow_rounded;

          Widget content;
          if (initialized) {
            final videoSize = value.size;
            final safeWidth = videoSize.width > 0 ? videoSize.width : 196.0;
            final safeHeight = videoSize.height > 0 ? videoSize.height : 196.0;
            content = IgnorePointer(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: safeWidth,
                  height: safeHeight,
                  child: vp.VideoPlayer(activeController),
                ),
              ),
            );
          } else {
            content = inactiveVideoBackdrop();
          }

          return buildVideoOrb(
            content: content,
            badgeLabel: value.isPlaying ? 'видео' : 'кружок',
            footerLabel: value.isPlaying
                ? 'Нажмите для паузы'
                : initialized
                ? 'Нажмите для воспроизведения'
                : 'Подготавливаем воспроизведение',
            durationLabel: totalDuration > Duration.zero
                ? '${_formatDurationLabel(position)} / ${_formatDurationLabel(totalDuration)}'
                : '00:00',
            actionIcon: playIcon,
            actionProgress: progress,
            showSpinner: !initialized || _inlineVideoNoteInitializing,
            isPlaying: value.isPlaying,
          );
        },
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: useInlineWebVideo
          ? null
          : videoUrl == null
          ? null
          : (kIsWeb && isActive)
          ? null
          : () =>
                unawaited(_toggleInlineVideoNotePlayback(messageId, videoUrl)),
      child: SizedBox(
        width: 196,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            useInlineWebVideo
                ? InlineVideoNoteOrb(
                    videoUrl: videoUrl,
                    durationMs: durationMs,
                    accentColor: accent,
                    footerText: 'Нажмите для воспроизведения',
                  )
                : isActive
                ? activeVideoOrb()
                : buildVideoOrb(
                    content: inactiveVideoBackdrop(),
                    badgeLabel: 'кружок',
                    footerLabel: 'Нажмите для воспроизведения',
                    durationLabel: durationMs > 0
                        ? _formatDurationLabel(
                            Duration(milliseconds: durationMs),
                          )
                        : '00:00',
                    actionIcon: Icons.play_arrow_rounded,
                    actionProgress: 0,
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> message) {
    final theme = Theme.of(context);
    final reducedMotion =
        performanceModeNotifier.value ||
        (MediaQuery.maybeOf(context)?.disableAnimations == true);
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
    final isVideoMessage =
        !isDeleted &&
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        attachmentType == 'video';
    final imageUrl = _resolveImageUrl(metaMap['image_url']?.toString());
    final captionText = _captionTextOf(message, metaMap);
    final catalogTexts = _extractCatalogTexts(text);
    final productLabel = (() {
      final fromMeta = metaMap['product_label']?.toString().trim() ?? '';
      if (fromMeta.isNotEmpty) return fromMeta;
      return _formatProductLabel(
        metaMap['product_code'],
        metaMap['product_shelf_number'] ?? metaMap['shelf_number'],
      );
    })();
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
        !isVoiceMessage &&
        !isVideoMessage;
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
    final canReact = hasMessageId && !isDeleted;
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
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: AdaptiveNetworkImage(
                imageUrl,
                width: width ?? 240,
                fit: BoxFit.contain,
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

    final reactionByUser = _reactionByUserOf(metaMap);
    final currentUserId = authService.currentUser?.id.trim() ?? '';
    final reactionCounts = <String, int>{};
    for (final emoji in reactionByUser.values) {
      reactionCounts.update(emoji, (value) => value + 1, ifAbsent: () => 1);
    }
    final reactionEntries = reactionCounts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });

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
        canReact: canReact,
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
        canReact: canReact,
      ),
      child: AnimatedContainer(
        duration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 220),
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
                    '$offerProcessedSum ₽',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildHighlightedText(
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
              _buildHighlightedText(
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
                  _catalogMetaBadge(theme, 'Цена', '$price ₽'),
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
                _buildHighlightedText(
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
                  _catalogMetaBadge(theme, 'ID', productLabel),
                  _catalogMetaBadge(theme, 'Цена', '$price ₽'),
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
                  _buildHighlightedText(
                    captionText,
                    style: TextStyle(color: textColor),
                  ),
                ],
              ] else if (isVideoMessage) ...[
                Align(
                  alignment: fromMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: _buildVideoNoteAttachment(
                    theme,
                    message,
                    metaMap,
                    textColor: textColor,
                  ),
                ),
                if (captionText.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _buildHighlightedText(
                    captionText,
                    style: TextStyle(color: textColor),
                  ),
                ],
              ] else ...[
                if (imageUrl != null) ...[
                  buildMessageImage(),
                  if (captionText.isNotEmpty || isPlainMessage)
                    const SizedBox(height: 10),
                ],
                if (isPlainMessage || captionText.isNotEmpty)
                  _buildHighlightedText(
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
              if (reactionEntries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: reactionEntries.map((entry) {
                      final mine =
                          currentUserId.isNotEmpty &&
                          reactionByUser[currentUserId] == entry.key;
                      return InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () =>
                            _toggleMessageReaction(messageId, entry.key),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: mine
                                ? theme.colorScheme.secondaryContainer
                                : theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: mine
                                  ? theme.colorScheme.secondary
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Text(
                            '${entry.key} ${entry.value}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: mine
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: mine
                                  ? theme.colorScheme.onSecondaryContainer
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
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
                                  alpha: reducedMotion ? 0.92 : 0.76,
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

    final bubbleRow = Padding(
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
    );

    final animatedItem = reducedMotion
        ? bubbleRow
        : TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: isAppearing ? 0 : 1, end: 1),
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              final dx = fromMe ? 18 * (1 - value) : -28 * (1 - value);
              final dy = 10 * (1 - value);
              return Opacity(
                opacity: value.clamp(0, 1),
                child: Transform.translate(
                  offset: Offset(dx, dy),
                  child: child,
                ),
              );
            },
            child: bubbleRow,
          );

    if (hasMessageId) {
      return KeyedSubtree(key: _messageKeyFor(messageId), child: animatedItem);
    }
    return animatedItem;
  }

  @override
  Widget build(BuildContext context) {
    final platform = defaultTargetPlatform;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final isMobileLikePlatform =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final isLikelyMobileWeb =
        kIsWeb && (isMobileLikePlatform || viewportWidth < 900);
    final allowEnterShortcut =
        !isLikelyMobileWeb &&
        (kIsWeb ||
            platform == TargetPlatform.macOS ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux);
    final canCompose = _canCompose();
    final blockedReason = _composeBlockedReason();
    final visibleMessages = _visibleMessages();
    final timeline = _buildTimeline(visibleMessages);
    final recordingOverlayActive = _voiceRecording || _videoRecording;

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
          if (_searchMode && _searchQuery.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  _searchResultIds.isEmpty
                      ? '0/0'
                      : '${_searchResultIndex + 1}/${_searchResultIds.length}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
          if (_searchMode)
            IconButton(
              tooltip: 'Предыдущее совпадение',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: _searchResultIds.isEmpty
                  ? null
                  : () => _moveSearchResult(-1),
            ),
          if (_searchMode)
            IconButton(
              tooltip: 'Следующее совпадение',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _searchResultIds.isEmpty
                  ? null
                  : () => _moveSearchResult(1),
            ),
          IconButton(
            icon: Icon(_searchMode ? Icons.close : Icons.search),
            onPressed: () {
              if (!_searchMode && _voiceRecording) {
                unawaited(_cancelVoiceRecording());
              }
              setState(() {
                if (_searchMode) {
                  _searchController.clear();
                  _searchQuery = '';
                }
                _searchMode = !_searchMode;
              });
              _recomputeSearchResults(keepCurrent: false);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_isDirectMessageChat())
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Внимание: не отправляйте личные данные, фото документов, карты и пароли. Личные сообщения пока в доработке, поэтому это небезопасно.',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_isClientRole() && _offlineQueuedCount > 0)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.cloud_off_outlined,
                        color: Theme.of(
                          context,
                        ).colorScheme.onTertiaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Оффлайн-покупок в очереди: $_offlineQueuedCount. '
                          'Они отправятся автоматически, когда появится интернет.',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onTertiaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _offlineSyncBusy
                            ? null
                            : _syncOfflinePurchasesNow,
                        child: _offlineSyncBusy
                            ? const Text('...')
                            : const Text('Синхр.'),
                      ),
                    ],
                  ),
                ),
              if (_activePin != null)
                GestureDetector(
                  onTap: _jumpToPinnedMessage,
                  child: Container(
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
              if (!_searchMode) ...[
                if (blockedReason != null &&
                    !_voiceRecording &&
                    !_voiceStartInProgress &&
                    !_videoRecording &&
                    !_videoStartInProgress)
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
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: recordingOverlayActive ? 0 : 1,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            tooltip: 'Вложение',
                            icon: _mediaUploading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.attach_file_rounded),
                            onPressed:
                                canCompose &&
                                    !_mediaUploading &&
                                    !_voiceSending &&
                                    !_anyComposerRecording &&
                                    !_anyRecorderStarting
                                ? _openAttachmentSheet
                                : null,
                          ),
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: SubmitOnEnter(
                                controller: _controller,
                                enabled:
                                    allowEnterShortcut &&
                                    canCompose &&
                                    !_anyComposerRecording,
                                onSubmit: _send,
                                child: TextField(
                                  focusNode: _inputFocusNode,
                                  controller: _controller,
                                  enabled: canCompose && !_anyComposerRecording,
                                  minLines: 1,
                                  maxLines: 6,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: TextInputAction.newline,
                                  decoration: withInputLanguageBadge(
                                    InputDecoration(
                                      hintText: _anyComposerRecording
                                          ? 'Говорите... отпустите кнопку для отправки'
                                          : canCompose
                                          ? 'Сообщение...'
                                          : 'Отправка сообщений недоступна',
                                      border: InputBorder.none,
                                      isDense: true,
                                    ),
                                    controller: _controller,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Эмодзи',
                            icon: const Icon(Icons.emoji_emotions_outlined),
                            onPressed: canCompose && !_anyComposerRecording
                                ? _openComposerEmojiPicker
                                : null,
                          ),
                          if (_hasDraftText)
                            IconButton(
                              icon: _voiceSending
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.send_rounded),
                              onPressed: !canCompose || _mediaUploading
                                  ? null
                                  : _send,
                            )
                          else
                            Builder(
                              builder: (context) {
                                final disabled =
                                    !canCompose ||
                                    _mediaUploading ||
                                    _voiceSending ||
                                    _anyRecorderStarting;
                                final activeColor = Theme.of(
                                  context,
                                ).colorScheme.primary;
                                final icon = _voiceRecording
                                    ? Icons.stop_circle_outlined
                                    : (_composerMediaMode ==
                                              _ComposerMediaMode.camera
                                          ? Icons.radio_button_unchecked_rounded
                                          : Icons.mic_rounded);
                                final isArmed =
                                    _anyComposerRecording ||
                                    _anyRecorderStarting;
                                final buttonBaseColor = _voiceRecording
                                    ? Theme.of(context).colorScheme.error
                                    : _videoRecording
                                    ? const Color(0xFF2F80FF)
                                    : activeColor;
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) =>
                                      _handleComposerMediaTapDown(
                                        disabled: disabled,
                                        context: context,
                                        canCompose: canCompose,
                                        details: details,
                                      ),
                                  onTapUp: (_) => unawaited(
                                    _handleComposerMediaTapUp(
                                      disabled: disabled,
                                      context: context,
                                      canCompose: canCompose,
                                    ),
                                  ),
                                  onTapCancel: _handleComposerMediaTapCancel,
                                  onPanUpdate: _handleComposerMediaPanUpdate,
                                  onPanEnd: (_) => _handleComposerMediaPanEnd(),
                                  onPanCancel: _handleComposerMediaPanCancel,
                                  child: TweenAnimationBuilder<double>(
                                    duration: const Duration(milliseconds: 180),
                                    tween: Tween<double>(
                                      begin: 1,
                                      end: isArmed ? 1.08 : 1.0,
                                    ),
                                    curve: Curves.easeOutBack,
                                    builder: (ctx, scale, child) =>
                                        Transform.scale(
                                          scale: scale,
                                          child: child,
                                        ),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      width: 46,
                                      height: 46,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: disabled
                                            ? null
                                            : LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [
                                                  buttonBaseColor.withValues(
                                                    alpha: 0.9,
                                                  ),
                                                  buttonBaseColor.withValues(
                                                    alpha: 0.72,
                                                  ),
                                                ],
                                              ),
                                        color: disabled
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.surfaceContainerHigh
                                            : null,
                                        boxShadow: disabled
                                            ? null
                                            : [
                                                BoxShadow(
                                                  color: buttonBaseColor
                                                      .withValues(alpha: 0.30),
                                                  blurRadius: 14,
                                                  offset: const Offset(0, 5),
                                                ),
                                              ],
                                      ),
                                      child:
                                          _voiceSending || _anyRecorderStarting
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(Colors.white),
                                              ),
                                            )
                                          : Icon(
                                              icon,
                                              color: disabled
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant
                                                  : Colors.white,
                                            ),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_voiceRecording)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildVoiceRecordingBar(Theme.of(context)),
            ),
          if (_videoRecording)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: true,
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.10),
                            Colors.black.withValues(alpha: 0.38),
                          ],
                        ),
                      ),
                      child: Align(
                        alignment: const Alignment(0, 0.46),
                        child: _buildVideoRecordingOrb(Theme.of(context)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_videoRecording)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildVideoRecordingBar(Theme.of(context)),
            ),
        ],
      ),
    );
  }
}
