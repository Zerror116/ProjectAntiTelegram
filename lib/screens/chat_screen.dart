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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart' as vp;

import '../main.dart';
import '../services/sticker_print_service.dart';
import '../services/web_image_cache_service.dart';
import '../services/web_media_capture_permission_service.dart';
import '../src/utils/chat_api.dart';
import '../src/utils/chat_image_preprocessor.dart';
import '../src/utils/media_url.dart';
import '../src/utils/messenger_ui_helpers.dart';
import '../utils/date_time_utils.dart';
import '../utils/phone_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/chat_media_viewer.dart';
import '../widgets/chat_message_image.dart';
import '../widgets/delivery_address_picker_dialog.dart';
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
    this.width,
    this.height,
    this.preprocessTag,
  });

  final String filename;
  final String? path;
  final Uint8List? bytes;
  final String? mimeType;
  final int? width;
  final int? height;
  final String? preprocessTag;
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
  static const String _chatScrollOffsetKeyPrefix = 'chat_scroll_offset_v2:';
  static const String _chatScrollFractionKeyPrefix = 'chat_scroll_fraction_v1:';
  static const String _chatScrollAnchorMessageIdKeyPrefix =
      'chat_scroll_anchor_message_id_v1:';
  static const String _chatScrollAnchorOffsetKeyPrefix =
      'chat_scroll_anchor_offset_v1:';
  static final Map<String, double> _inMemoryScrollOffsets = <String, double>{};
  static final Map<String, double> _inMemoryScrollFractions =
      <String, double>{};
  static final Map<String, String> _inMemoryScrollAnchorMessageIds =
      <String, String>{};
  static final Map<String, double> _inMemoryScrollAnchorOffsets =
      <String, double>{};

  final _controller = TextEditingController();
  final _searchController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final GlobalKey _messagesViewportKey = GlobalKey();
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
  bool _messagesLoadInFlight = false;
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
  bool _showScrollToBottomButton = false;
  bool _initialViewportApplied = false;
  bool _initialViewportReady = false;
  bool _loadingOlderMessages = false;
  bool _loadingNewerMessages = false;
  bool _draftSyncInFlight = false;
  bool _hasMoreBefore = false;
  bool _stickToBottom = true;
  int _offlineQueuedCount = 0;
  int _unreadCount = 0;

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
  Timer? _bottomAnchorTimer;
  Timer? _persistScrollOffsetTimer;
  Timer? _initialViewportFailsafeTimer;
  Timer? _draftSyncTimer;
  Timer? _serverChatStateSyncTimer;
  Timer? _reconnectReplayTimer;
  Timer? _searchDebounceTimer;
  int _bottomSettlePassesRemaining = 0;
  VoidCallback? _bottomSettleOnComplete;
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
  List<Map<String, dynamic>> _serverSearchMessages = const [];
  bool _serverSearchLoading = false;
  bool _serverSearchLoaded = false;
  final List<String> _recentReactionEmojis = <String>[];
  final List<String> _recentComposerEmojis = <String>[];
  double? _savedScrollOffset;
  double? _savedScrollFraction;
  String? _savedScrollAnchorMessageId;
  double? _savedScrollAnchorOffset;
  String? _firstUnreadMessageId;
  String? _lastSeenMessageId;
  String? _oldestLoadedMessageId;
  String? _oldestLoadedCreatedAt;
  String? _newestLoadedMessageId;
  String? _newestLoadedCreatedAt;
  String? _replyToMessageId;
  String? _replyPreviewText;
  String? _replyPreviewSenderName;
  bool _applyingServerDraft = false;
  MessengerReservedQuickFilter _reservedQuickFilter =
      MessengerReservedQuickFilter.all;

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
  static const Map<String, List<String>> _reactionEmojiCategories =
      <String, List<String>>{
        'Частые': <String>[
          '👍',
          '❤️',
          '🔥',
          '👏',
          '🎉',
          '😂',
          '😢',
          '🙏',
          '🤝',
          '💯',
          '✅',
          '👀',
        ],
        'Лица': <String>[
          '😀',
          '😁',
          '😅',
          '😂',
          '😊',
          '😍',
          '😘',
          '🤔',
          '😎',
          '🥳',
          '😭',
          '😡',
          '😴',
          '🥲',
          '😱',
          '🤯',
          '🤩',
          '🙃',
          '😇',
          '🫶',
        ],
        'Жесты': <String>[
          '👍',
          '👎',
          '👏',
          '🙌',
          '🙏',
          '🤝',
          '👌',
          '✌️',
          '🤞',
          '👊',
          '🤟',
          '🫡',
          '💪',
          '☝️',
          '👆',
          '👇',
          '👉',
          '👈',
        ],
        'Сердца': <String>[
          '❤️',
          '🩷',
          '🧡',
          '💛',
          '💚',
          '🩵',
          '💙',
          '💜',
          '🤍',
          '🖤',
          '🤎',
          '💔',
          '❤️‍🔥',
          '❤️‍🩹',
        ],
        'Работа': <String>[
          '✅',
          '❌',
          '⚠️',
          '⏳',
          '🚀',
          '📌',
          '🛠️',
          '📦',
          '🧾',
          '💬',
          '📞',
          '📍',
          '💸',
          '📈',
          '🔒',
        ],
        'Праздник': <String>[
          '🎉',
          '🔥',
          '⭐',
          '🌟',
          '💯',
          '🏆',
          '🎁',
          '🍾',
          '🥂',
          '🎈',
          '🎊',
          '🍀',
          '🌈',
          '☀️',
        ],
      };

  @override
  void initState() {
    super.initState();
    activeChatIdNotifier.value = widget.chatId;
    unawaited(_initializeChat());
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
      setState(() {
        _searchQuery = next;
        if (next.isEmpty) {
          _serverSearchMessages = const [];
          _serverSearchLoaded = false;
          _serverSearchLoading = false;
        } else {
          _serverSearchMessages = const [];
          _serverSearchLoaded = true;
          _serverSearchLoading = true;
        }
      });
      if (next.isEmpty) {
        _recomputeSearchResults(keepCurrent: false);
      } else {
        _scheduleServerSearch();
      }
    });

    _hasDraftText = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final nextHasDraft = _controller.text.trim().isNotEmpty;
      if (nextHasDraft != _hasDraftText && mounted) {
        setState(() => _hasDraftText = nextHasDraft);
      }
      _scheduleDraftSync();
    });

    _inputFocusNode.addListener(() {
      if (_inputFocusNode.hasFocus) {
        _scrollToBottom(animated: true);
      }
    });
    _scrollController.addListener(_handleScroll);

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
          showAppNotice(context, 'Диалог закончен', tone: AppNoticeTone.info);
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
      if (type == 'socket:connected') {
        _reconnectReplayTimer?.cancel();
        _reconnectReplayTimer = Timer(const Duration(milliseconds: 220), () {
          unawaited(_replayMissedMessagesAfterReconnect());
        });
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

  Future<void> _initializeChat() async {
    await _restoreSavedScrollOffset();
    await _loadServerChatState();
    if (!mounted) return;
    await _loadMessages();
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
    _bottomAnchorTimer?.cancel();
    _persistScrollOffsetTimer?.cancel();
    _initialViewportFailsafeTimer?.cancel();
    _draftSyncTimer?.cancel();
    _serverChatStateSyncTimer?.cancel();
    _reconnectReplayTimer?.cancel();
    _searchDebounceTimer?.cancel();
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
    _scrollController.removeListener(_handleScroll);
    unawaited(_persistCurrentScrollOffset());
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

  String _messageIdOf(Map<String, dynamic> message) =>
      (message['id'] ?? '').toString().trim();

  String? _messageCreatedAtCursorOf(Map<String, dynamic> message) {
    final parsed = _parseDate(message['created_at']);
    if (parsed != null) return parsed.toUtc().toIso8601String();
    final raw = (message['created_at'] ?? '').toString().trim();
    return raw.isEmpty ? null : raw;
  }

  Map<String, dynamic> _chatStateMapOf(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
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

  String get _chatScrollOffsetStorageKey =>
      '$_chatScrollOffsetKeyPrefix${widget.chatId}';

  String get _chatScrollFractionStorageKey =>
      '$_chatScrollFractionKeyPrefix${widget.chatId}';

  String get _chatScrollAnchorMessageIdStorageKey =>
      '$_chatScrollAnchorMessageIdKeyPrefix${widget.chatId}';

  String get _chatScrollAnchorOffsetStorageKey =>
      '$_chatScrollAnchorOffsetKeyPrefix${widget.chatId}';

  Future<void> _restoreSavedScrollOffset() async {
    final cached = _inMemoryScrollOffsets[widget.chatId];
    if (cached != null && cached.isFinite && cached >= 0) {
      _savedScrollOffset = cached;
    }
    final cachedFraction = _inMemoryScrollFractions[widget.chatId];
    if (cachedFraction != null &&
        cachedFraction.isFinite &&
        cachedFraction >= 0 &&
        cachedFraction <= 1) {
      _savedScrollFraction = cachedFraction;
    }
    final cachedAnchorMessageId =
        _inMemoryScrollAnchorMessageIds[widget.chatId];
    if (cachedAnchorMessageId != null &&
        cachedAnchorMessageId.trim().isNotEmpty) {
      _savedScrollAnchorMessageId = cachedAnchorMessageId.trim();
    }
    final cachedAnchorOffset = _inMemoryScrollAnchorOffsets[widget.chatId];
    if (cachedAnchorOffset != null && cachedAnchorOffset.isFinite) {
      _savedScrollAnchorOffset = cachedAnchorOffset;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_chatScrollOffsetStorageKey);
      if (saved != null && saved.isFinite && saved >= 0) {
        _savedScrollOffset = saved;
        _inMemoryScrollOffsets[widget.chatId] = saved;
      }
      final savedFraction = prefs.getDouble(_chatScrollFractionStorageKey);
      if (savedFraction != null &&
          savedFraction.isFinite &&
          savedFraction >= 0 &&
          savedFraction <= 1) {
        _savedScrollFraction = savedFraction;
        _inMemoryScrollFractions[widget.chatId] = savedFraction;
      }
      final savedAnchorMessageId = prefs.getString(
        _chatScrollAnchorMessageIdStorageKey,
      );
      if (savedAnchorMessageId != null &&
          savedAnchorMessageId.trim().isNotEmpty) {
        _savedScrollAnchorMessageId = savedAnchorMessageId.trim();
        _inMemoryScrollAnchorMessageIds[widget.chatId] = savedAnchorMessageId
            .trim();
      }
      final savedAnchorOffset = prefs.getDouble(
        _chatScrollAnchorOffsetStorageKey,
      );
      if (savedAnchorOffset != null && savedAnchorOffset.isFinite) {
        _savedScrollAnchorOffset = savedAnchorOffset;
        _inMemoryScrollAnchorOffsets[widget.chatId] = savedAnchorOffset;
      }
    } catch (_) {}
  }

  void _refreshLoadedMessageBounds() {
    if (_messages.isEmpty) {
      _oldestLoadedMessageId = null;
      _oldestLoadedCreatedAt = null;
      _newestLoadedMessageId = null;
      _newestLoadedCreatedAt = null;
      return;
    }
    final ordered = [..._messages]..sort(_compareByCreatedAt);
    final oldest = ordered.first;
    final newest = ordered.last;
    _oldestLoadedMessageId = _messageIdOf(oldest);
    _oldestLoadedCreatedAt = _messageCreatedAtCursorOf(oldest);
    _newestLoadedMessageId = _messageIdOf(newest);
    _newestLoadedCreatedAt = _messageCreatedAtCursorOf(newest);
  }

  void _applyServerChatState(
    Map<String, dynamic> state, {
    bool restoreDraft = true,
    bool restoreScroll = true,
  }) {
    _lastSeenMessageId =
        (state['last_seen_message_id'] ?? '').toString().trim().isEmpty
        ? null
        : (state['last_seen_message_id'] ?? '').toString().trim();
    _firstUnreadMessageId =
        (state['first_unread_message_id'] ?? '').toString().trim().isEmpty
        ? null
        : (state['first_unread_message_id'] ?? '').toString().trim();
    _unreadCount = int.tryParse('${state['unread_count'] ?? 0}') ?? 0;

    if (restoreScroll) {
      final serverAnchorId = (state['scroll_anchor_message_id'] ?? '')
          .toString()
          .trim();
      final serverAnchorOffset = double.tryParse(
        '${state['scroll_anchor_offset'] ?? ''}',
      );
      if (serverAnchorId.isNotEmpty) {
        _savedScrollAnchorMessageId = serverAnchorId;
        _savedScrollAnchorOffset = serverAnchorOffset ?? 0;
        _inMemoryScrollAnchorMessageIds[widget.chatId] = serverAnchorId;
        _inMemoryScrollAnchorOffsets[widget.chatId] = serverAnchorOffset ?? 0;
      }
    }

    if (restoreDraft) {
      final serverDraft = (state['draft_text'] ?? '').toString();
      if (serverDraft.trim().isNotEmpty && _controller.text.trim().isEmpty) {
        _applyingServerDraft = true;
        _controller.value = TextEditingValue(
          text: serverDraft,
          selection: TextSelection.collapsed(offset: serverDraft.length),
        );
        _applyingServerDraft = false;
        _hasDraftText = serverDraft.trim().isNotEmpty;
      }
    }
  }

  Future<void> _loadServerChatState({bool restoreDraft = true}) async {
    try {
      final resp = await authService.dio.get('/api/chats/${widget.chatId}/state');
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! Map) return;
      final state = _chatStateMapOf(data['data']);
      if (!mounted) {
        _applyServerChatState(state, restoreDraft: restoreDraft);
        return;
      }
      setState(() {
        _applyServerChatState(state, restoreDraft: restoreDraft);
      });
    } catch (_) {
      // Ignore state bootstrap failures; local fallback will still work.
    }
  }

  Future<void> _patchServerChatState(Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    await authService.dio.patch('/api/chats/${widget.chatId}/state', data: patch);
  }

  void _scheduleDraftSync() {
    if (_applyingServerDraft) return;
    _draftSyncTimer?.cancel();
    _draftSyncTimer = Timer(const Duration(milliseconds: 480), () {
      unawaited(_syncDraftToServer());
    });
  }

  Future<void> _syncDraftToServer() async {
    if (_draftSyncInFlight) return;
    _draftSyncInFlight = true;
    try {
      await _patchServerChatState({
        'draft_text': _controller.text,
        'draft_updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // keep draft local, we'll retry on next edit
    } finally {
      _draftSyncInFlight = false;
    }
  }

  String? _lastVisibleMessageId() {
    final viewportContext = _messagesViewportKey.currentContext;
    final viewportObject = viewportContext?.findRenderObject();
    if (viewportObject is! RenderBox) return null;
    String? bestId;
    var bestBottom = double.negativeInfinity;
    for (final entry in _messageItemKeys.entries) {
      final itemContext = entry.value.currentContext;
      final itemObject = itemContext?.findRenderObject();
      if (itemObject is! RenderBox || !itemObject.hasSize) continue;
      final topLeft = itemObject.localToGlobal(
        Offset.zero,
        ancestor: viewportObject,
      );
      final top = topLeft.dy;
      final bottom = top + itemObject.size.height;
      if (bottom <= 0 || top >= viewportObject.size.height) continue;
      if (bottom > bestBottom) {
        bestBottom = bottom;
        bestId = entry.key.trim();
      }
    }
    return bestId;
  }

  void _scheduleServerViewportSync() {
    _serverChatStateSyncTimer?.cancel();
    _serverChatStateSyncTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_syncViewportStateToServer());
    });
  }

  Future<void> _syncViewportStateToServer() async {
    final anchor = _currentScrollAnchor();
    final visibleLastMessageId = _isNearBottom()
        ? _newestLoadedMessageId
        : _lastVisibleMessageId();
    final patch = <String, dynamic>{};
    if (anchor != null) {
      patch['scroll_anchor_message_id'] = anchor.messageId;
      patch['scroll_anchor_offset'] = anchor.offset;
    }
    if ((visibleLastMessageId ?? '').trim().isNotEmpty) {
      patch['last_seen_message_id'] = visibleLastMessageId!.trim();
    }
    if (patch.isEmpty) return;
    try {
      await _patchServerChatState(patch);
      _lastSeenMessageId = (patch['last_seen_message_id'] ?? _lastSeenMessageId)
          ?.toString();
    } catch (_) {
      // ignore best-effort sync errors
    }
  }

  ({String messageId, double offset})? _currentScrollAnchor() {
    final viewportContext = _messagesViewportKey.currentContext;
    final viewportObject = viewportContext?.findRenderObject();
    if (viewportObject is! RenderBox) return null;

    ({String messageId, double offset})? best;
    var bestDistance = double.infinity;

    for (final entry in _messageItemKeys.entries) {
      final messageId = entry.key.trim();
      if (messageId.isEmpty) continue;
      final itemContext = entry.value.currentContext;
      final itemObject = itemContext?.findRenderObject();
      if (itemObject is! RenderBox || !itemObject.hasSize) continue;
      final topLeft = itemObject.localToGlobal(
        Offset.zero,
        ancestor: viewportObject,
      );
      final top = topLeft.dy;
      final bottom = top + itemObject.size.height;
      if (bottom <= 0 || top >= viewportObject.size.height) continue;
      final distance = top.abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = (
          messageId: messageId,
          offset: top.clamp(
            -viewportObject.size.height,
            viewportObject.size.height,
          ),
        );
      }
    }

    return best;
  }

  Future<void> _persistCurrentScrollOffset() async {
    if (!_scrollController.hasClients) return;
    final rawOffset = _scrollController.position.pixels;
    if (!rawOffset.isFinite) return;
    final offset = rawOffset
        .clamp(0.0, _scrollController.position.maxScrollExtent)
        .toDouble();
    final maxExtent = _scrollController.position.maxScrollExtent;
    final fraction = maxExtent <= 0
        ? 1.0
        : (offset / maxExtent).clamp(0.0, 1.0).toDouble();
    _savedScrollOffset = offset;
    _savedScrollFraction = fraction;
    _inMemoryScrollOffsets[widget.chatId] = offset;
    _inMemoryScrollFractions[widget.chatId] = fraction;
    final anchor = _currentScrollAnchor();
    if (anchor != null) {
      _savedScrollAnchorMessageId = anchor.messageId;
      _savedScrollAnchorOffset = anchor.offset;
      _inMemoryScrollAnchorMessageIds[widget.chatId] = anchor.messageId;
      _inMemoryScrollAnchorOffsets[widget.chatId] = anchor.offset;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_chatScrollOffsetStorageKey, offset);
      await prefs.setDouble(_chatScrollFractionStorageKey, fraction);
      if (anchor != null) {
        await prefs.setString(
          _chatScrollAnchorMessageIdStorageKey,
          anchor.messageId,
        );
        await prefs.setDouble(_chatScrollAnchorOffsetStorageKey, anchor.offset);
      }
    } catch (_) {}
  }

  void _queuePersistCurrentScrollOffset() {
    _persistScrollOffsetTimer?.cancel();
    _persistScrollOffsetTimer = Timer(
      const Duration(milliseconds: 240),
      () => unawaited(_persistCurrentScrollOffset()),
    );
    _scheduleServerViewportSync();
  }

  void _handleScroll() {
    if (!mounted) return;
    _queuePersistCurrentScrollOffset();
    if (_scrollController.hasClients && _scrollController.position.pixels <= 280) {
      unawaited(_loadOlderMessages());
    }
    final nearBottom = _isNearBottom();
    _stickToBottom = nearBottom;
    if (nearBottom && _unreadCount > 0) {
      _scheduleReadSync();
    }
    final shouldShow = _initialViewportReady && !nearBottom;
    if (_showScrollToBottomButton == shouldShow) return;
    setState(() => _showScrollToBottomButton = shouldShow);
  }

  void _clearBottomSettle({bool clearCallback = true}) {
    _bottomAnchorTimer?.cancel();
    _bottomAnchorTimer = null;
    _bottomSettlePassesRemaining = 0;
    if (clearCallback) {
      _bottomSettleOnComplete = null;
    }
  }

  void _completeBottomSettleIfNeeded() {
    if (_bottomSettlePassesRemaining > 0) return;
    final onComplete = _bottomSettleOnComplete;
    _bottomSettleOnComplete = null;
    onComplete?.call();
  }

  void _runBottomSettlePass({
    Duration interval = const Duration(milliseconds: 120),
  }) {
    if (!mounted || !_scrollController.hasClients) {
      _completeBottomSettleIfNeeded();
      return;
    }
    if (_bottomSettlePassesRemaining <= 0) {
      _completeBottomSettleIfNeeded();
      return;
    }

    final target = _scrollController.position.maxScrollExtent.toDouble();
    final delta = (target - _scrollController.position.pixels).abs();
    if (delta > 0.5) {
      _scrollController.jumpTo(target);
    }
    _bottomSettlePassesRemaining = max(0, _bottomSettlePassesRemaining - 1);
    _handleScroll();
    if (_bottomSettlePassesRemaining > 0) {
      _bottomAnchorTimer?.cancel();
      _bottomAnchorTimer = Timer(
        interval,
        () => _runBottomSettlePass(interval: interval),
      );
      return;
    }
    _completeBottomSettleIfNeeded();
  }

  void _armBottomSettle({
    int passes = 3,
    Duration delay = const Duration(milliseconds: 180),
    Duration interval = const Duration(milliseconds: 120),
    VoidCallback? onComplete,
  }) {
    if (passes <= 0) {
      onComplete?.call();
      return;
    }
    _bottomSettlePassesRemaining = max(_bottomSettlePassesRemaining, passes);
    if (onComplete != null) {
      _bottomSettleOnComplete = onComplete;
    }
    _bottomAnchorTimer?.cancel();
    _bottomAnchorTimer = Timer(
      delay,
      () => _runBottomSettlePass(interval: interval),
    );
  }

  void _pingBottomSettle({
    Duration delay = const Duration(milliseconds: 40),
    Duration interval = const Duration(milliseconds: 120),
  }) {
    if (_bottomSettlePassesRemaining <= 0) return;
    _bottomAnchorTimer?.cancel();
    _bottomAnchorTimer = Timer(
      delay,
      () => _runBottomSettlePass(interval: interval),
    );
  }

  void _scrollToBottom({
    bool animated = true,
    int settlePasses = 5,
    Duration settleInterval = const Duration(milliseconds: 120),
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _stickToBottom = true;
      final target = _scrollController.position.maxScrollExtent;
      if (settlePasses > 0) {
        _armBottomSettle(
          passes: settlePasses,
          delay: animated
              ? const Duration(milliseconds: 220)
              : Duration.zero,
          interval: settleInterval,
        );
      } else {
        _clearBottomSettle(clearCallback: false);
      }
      if (animated) {
        unawaited(
          _scrollController
              .animateTo(
                target,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              )
              .whenComplete(() {
                if (!mounted || !_scrollController.hasClients) return;
                _pingBottomSettle(
                  delay: Duration.zero,
                  interval: settleInterval,
                );
              }),
        );
      } else {
        _scrollController.jumpTo(target);
      }
      _handleScroll();
    });
  }

  void _applyInitialViewportAfterLoad() {
    if (_initialViewportApplied) return;
    _initialViewportApplied = true;
    _initialViewportFailsafeTimer?.cancel();
    _initialViewportFailsafeTimer = Timer(
      const Duration(seconds: 4),
      () {
        if (!mounted || _initialViewportReady) return;
        _fallbackAfterAnchorRestoreFailure();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _performInitialViewportRestore();
    });
  }

  void _performInitialViewportRestore({int attempts = 8}) {
    if (!mounted) return;
    if (_messages.isEmpty) {
      _markInitialViewportReady();
      return;
    }
    if (!_scrollController.hasClients) {
      if (attempts <= 0) {
        _markInitialViewportReady();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _performInitialViewportRestore(attempts: attempts - 1);
      });
      return;
    }

    final savedOffset = _savedScrollOffset;
    final savedFraction = _savedScrollFraction;
    final savedAnchorMessageId = _savedScrollAnchorMessageId;
    final savedAnchorOffset = _savedScrollAnchorOffset;
    if (savedAnchorMessageId != null && savedAnchorMessageId.isNotEmpty) {
      unawaited(
        _restoreSavedViewportByAnchor(
          messageId: savedAnchorMessageId,
          desiredOffset: savedAnchorOffset ?? 0,
          passes: 5,
        ),
      );
      return;
    }
    if (savedOffset != null || savedFraction != null) {
      _restoreSavedViewport(
        savedOffset: savedOffset,
        savedFraction: savedFraction,
        passes: 4,
        onComplete: _markInitialViewportReady,
      );
      return;
    }

    _stabilizeBottomAnchor(passes: 7, onComplete: _markInitialViewportReady);
  }

  Future<void> _restoreSavedViewportByAnchor({
    required String messageId,
    required double desiredOffset,
    int passes = 4,
  }) async {
    if (!mounted || passes <= 0) {
      _markInitialViewportReady();
      return;
    }
    final targetContext = await _resolveMessageContextWithScroll(messageId);
    if (!mounted || targetContext == null || !_scrollController.hasClients) {
      if (passes <= 1) {
        _fallbackAfterAnchorRestoreFailure();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreSavedViewportByAnchor(
          messageId: messageId,
          desiredOffset: desiredOffset,
          passes: passes - 1,
        );
      });
      return;
    }

    final viewportContext = _messagesViewportKey.currentContext;
    final viewportObject = viewportContext?.findRenderObject();
    if (!targetContext.mounted) {
      if (passes <= 1) {
        _markInitialViewportReady();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreSavedViewportByAnchor(
          messageId: messageId,
          desiredOffset: desiredOffset,
          passes: passes - 1,
        );
      });
      return;
    }
    final targetObject = targetContext.findRenderObject();
    if (viewportObject is! RenderBox || targetObject is! RenderBox) {
      if (passes <= 1) {
        _markInitialViewportReady();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreSavedViewportByAnchor(
          messageId: messageId,
          desiredOffset: desiredOffset,
          passes: passes - 1,
        );
      });
      return;
    }

    final currentTop = targetObject
        .localToGlobal(Offset.zero, ancestor: viewportObject)
        .dy;
    final correction = currentTop - desiredOffset;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final nextOffset = (_scrollController.offset + correction)
        .clamp(0.0, maxExtent)
        .toDouble();
    _scrollController.jumpTo(nextOffset);
    _handleScroll();

    if (passes == 1) {
      _markInitialViewportReady();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreSavedViewportByAnchor(
        messageId: messageId,
        desiredOffset: desiredOffset,
        passes: passes - 1,
      );
    });
  }

  void _restoreSavedViewport({
    double? savedOffset,
    double? savedFraction,
    int passes = 1,
    VoidCallback? onComplete,
  }) {
    if (!mounted || !_scrollController.hasClients || passes <= 0) return;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final hasSavedFraction =
        savedFraction != null &&
        savedFraction.isFinite &&
        savedFraction >= 0 &&
        savedFraction <= 1;
    final normalizedFraction = savedFraction ?? 0.0;
    final target = hasSavedFraction
        ? (maxExtent * normalizedFraction).clamp(0.0, maxExtent).toDouble()
        : (savedOffset ?? 0.0).clamp(0.0, maxExtent).toDouble();
    _scrollController.jumpTo(target);
    _handleScroll();
    if (passes == 1) {
      onComplete?.call();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreSavedViewport(
        savedOffset: savedOffset,
        savedFraction: savedFraction,
        passes: passes - 1,
        onComplete: onComplete,
      );
    });
  }

  void _stabilizeBottomAnchor({
    int passes = 5,
    Duration interval = const Duration(milliseconds: 180),
    VoidCallback? onComplete,
  }) {
    if (passes <= 0) {
      onComplete?.call();
      return;
    }
    _scrollToBottom(
      animated: false,
      settlePasses: passes,
      settleInterval: interval,
    );
    if (onComplete != null) {
      _bottomSettleOnComplete = onComplete;
    }
  }

  void _markInitialViewportReady() {
    if (!mounted || _initialViewportReady) return;
    _initialViewportFailsafeTimer?.cancel();
    setState(() => _initialViewportReady = true);
    if (_isNearBottom()) {
      _scheduleReadSync();
    }
  }

  Future<void> _clearSavedScrollAnchor() async {
    _savedScrollAnchorMessageId = null;
    _savedScrollAnchorOffset = null;
    _inMemoryScrollAnchorMessageIds.remove(widget.chatId);
    _inMemoryScrollAnchorOffsets.remove(widget.chatId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_chatScrollAnchorMessageIdStorageKey);
      await prefs.remove(_chatScrollAnchorOffsetStorageKey);
    } catch (_) {
      // ignore
    }
  }

  void _fallbackAfterAnchorRestoreFailure() {
    unawaited(_clearSavedScrollAnchor());
    final savedOffset = _savedScrollOffset;
    final savedFraction = _savedScrollFraction;
    if (_scrollController.hasClients &&
        (savedOffset != null || savedFraction != null)) {
      _restoreSavedViewport(
        savedOffset: savedOffset,
        savedFraction: savedFraction,
        passes: 2,
        onComplete: _markInitialViewportReady,
      );
      return;
    }
    _markInitialViewportReady();
  }

  void _onMediaFramePainted() {
    if (!_initialViewportReady) {
      final anchorMessageId = _savedScrollAnchorMessageId;
      if (anchorMessageId != null && anchorMessageId.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _restoreSavedViewportByAnchor(
            messageId: anchorMessageId,
            desiredOffset: _savedScrollAnchorOffset ?? 0,
            passes: 2,
          );
        });
      }
      return;
    }
    if (_bottomSettlePassesRemaining > 0) {
      _pingBottomSettle();
      return;
    }
    if (!_stickToBottom) return;
    _armBottomSettle(
      passes: 2,
      delay: Duration.zero,
      interval: const Duration(milliseconds: 80),
    );
  }

  Future<bool> _warmUpVisibleImageDimensions(
    List<Map<String, dynamic>> messages,
    {int limit = 10,
    bool refreshAfterWarmUp = false}
  ) async {
    final savedAnchorMessageId = _savedScrollAnchorMessageId;
    var centerIndex = messages.isEmpty ? 0 : messages.length - 1;
    if (savedAnchorMessageId != null && savedAnchorMessageId.isNotEmpty) {
      final anchorIndex = messages.indexWhere(
        (message) => (message['id'] ?? '').toString() == savedAnchorMessageId,
      );
      if (anchorIndex >= 0) {
        centerIndex = anchorIndex;
      }
    } else if (_savedScrollFraction != null && messages.length > 1) {
      centerIndex = (_savedScrollFraction! * (messages.length - 1))
          .round()
          .clamp(0, messages.length - 1);
    }

    final candidates =
        <({int distance, Map<String, dynamic> message, String url})>[];
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      final meta = _metaMapOf(message['meta']);
      final imageUrl = _resolveImageUrl(meta['image_url']?.toString());
      if (imageUrl == null || imageUrl.isEmpty) continue;
      final hasKnownWidth =
          _positiveMediaDimension(meta['image_width']) != null;
      final hasKnownHeight =
          _positiveMediaDimension(meta['image_height']) != null;
      if (hasKnownWidth && hasKnownHeight) continue;
      candidates.add((
        distance: (index - centerIndex).abs(),
        message: message,
        url: imageUrl,
      ));
    }
    if (candidates.isEmpty) return false;

    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    final sample = candidates.take(limit).toList();
    var updated = false;
    await Future.wait(sample.map((item) async {
      final size = await warmUpChatMessageImageSize(item.url);
      if (size == null || size.width <= 0 || size.height <= 0) return;
      final meta = _metaMapOf(item.message['meta']);
      final nextWidth = size.width.round();
      final nextHeight = size.height.round();
      final currentWidth = _positiveMediaDimension(meta['image_width'])?.round();
      final currentHeight = _positiveMediaDimension(meta['image_height'])
          ?.round();
      if (currentWidth == nextWidth && currentHeight == nextHeight) {
        return;
      }
      meta['image_width'] = nextWidth;
      meta['image_height'] = nextHeight;
      meta['image_aspect_ratio'] = (size.width / size.height).toStringAsFixed(
        4,
      );
      item.message['meta'] = meta;
      updated = true;
    }));

    if (updated && refreshAfterWarmUp && mounted) {
      setState(() {});
    }
    return updated;
  }

  List<String> _initialChannelImageBatch(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return const <String>[];

    final savedAnchorMessageId = _savedScrollAnchorMessageId;
    var centerIndex = messages.length - 1;
    if (savedAnchorMessageId != null && savedAnchorMessageId.isNotEmpty) {
      final anchorIndex = messages.indexWhere(
        (message) => (message['id'] ?? '').toString() == savedAnchorMessageId,
      );
      if (anchorIndex >= 0) {
        centerIndex = anchorIndex;
      }
    } else if (_savedScrollFraction != null && messages.length > 1) {
      centerIndex = (_savedScrollFraction! * (messages.length - 1))
          .round()
          .clamp(0, messages.length - 1);
    }

    final candidates =
        <({int distance, String url})>[];
    for (var index = 0; index < messages.length; index++) {
      final meta = _metaMapOf(messages[index]['meta']);
      final imageUrl = _resolveImageUrl(meta['image_url']?.toString());
      if (imageUrl == null || imageUrl.isEmpty) continue;
      candidates.add((distance: (index - centerIndex).abs(), url: imageUrl));
    }
    if (candidates.isEmpty) return const <String>[];
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    return candidates
        .map((entry) => entry.url)
        .toSet()
        .take(10)
        .toList(growable: false);
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

  int _messageIndexInList(
    List<Map<String, dynamic>> messages, {
    String? messageId,
    String? clientMsgId,
  }) {
    final normalizedId = (messageId ?? '').trim();
    final normalizedClientMsgId = (clientMsgId ?? '').trim();
    if (normalizedId.isNotEmpty) {
      final byId = messages.indexWhere(
        (m) => (m['id']?.toString() ?? '').trim() == normalizedId,
      );
      if (byId >= 0) return byId;
    }
    if (normalizedClientMsgId.isNotEmpty) {
      return messages.indexWhere(
        (m) => (m['client_msg_id']?.toString() ?? '').trim() == normalizedClientMsgId,
      );
    }
    return -1;
  }

  List<Map<String, dynamic>> _mergeServerMessagesWithLocalState(
    List<Map<String, dynamic>> serverMessages,
  ) {
    final merged = serverMessages
        .map((message) => _normalizeMessage(message))
        .toList(growable: true);
    final localOnlyMessages = _messages.where((message) {
      final meta = _metaMapOf(message['meta']);
      return meta['local_only'] == true;
    });

    for (final localMessage in localOnlyMessages) {
      final localId = _messageIdOf(localMessage);
      final clientMsgId = (localMessage['client_msg_id'] ?? '')
          .toString()
          .trim();
      final existingIndex = _messageIndexInList(
        merged,
        messageId: localId.startsWith('temp-') ? null : localId,
        clientMsgId: clientMsgId,
      );
      if (existingIndex >= 0) {
        continue;
      }
      merged.add(_normalizeMessage(Map<String, dynamic>.from(localMessage)));
    }

    merged.sort(_compareByCreatedAt);
    return merged;
  }

  void _patchMessageLocally({
    required String clientMsgId,
    Map<String, dynamic> Function(Map<String, dynamic> message)? transform,
  }) {
    final normalizedClientMsgId = clientMsgId.trim();
    if (normalizedClientMsgId.isEmpty) return;
    final index = _messageIndexInList(
      _messages,
      clientMsgId: normalizedClientMsgId,
    );
    if (index < 0) return;
    final current = Map<String, dynamic>.from(_messages[index]);
    final next = transform == null ? current : transform(current);
    _upsertMessage(next);
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
        final index = _messageIndexInList(
          _messages,
          messageId: msgId,
          clientMsgId: clientMsgId,
        );
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
    final nextMessages = List<Map<String, dynamic>>.from(_messages);
    var changed = false;
    for (var index = 0; index < nextMessages.length; index++) {
      final message = nextMessages[index];
      final meta = _metaMapOf(message['meta']);
      final kind = meta['kind']?.toString() ?? '';
      final currentProductId = meta['product_id']?.toString() ?? '';
      if (kind != 'catalog_product' || currentProductId != productId) {
        continue;
      }

      final nextMeta = Map<String, dynamic>.from(meta);
      var itemChanged = false;
      if ((nextMeta['quantity'] as Object?) != quantity) {
        nextMeta['quantity'] = quantity;
        changed = true;
        itemChanged = true;
      }
      if (price != null &&
          price.trim().isNotEmpty &&
          (nextMeta['price']?.toString() ?? '') != price) {
        nextMeta['price'] = price;
        changed = true;
        itemChanged = true;
      }
      if (imageUrl != null &&
          imageUrl.trim().isNotEmpty &&
          (nextMeta['image_url']?.toString() ?? '') != imageUrl) {
        nextMeta['image_url'] = imageUrl;
        changed = true;
        itemChanged = true;
      }
      if (!itemChanged) continue;
      nextMessages[index] = {
        ...message,
        'meta': nextMeta,
      };
    }
    if (!changed) return;
    if (!mounted) {
      _messages = nextMessages;
      return;
    }
    setState(() {
      _messages = nextMessages;
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

  Map<String, dynamic>? _activePinnedMessage() {
    final pin = _activePin;
    if (pin == null) return null;
    final messageRaw = pin['message'];
    if (messageRaw is! Map) return null;
    return Map<String, dynamic>.from(messageRaw);
  }

  String _pinPreviewSubtitle() {
    final message = _activePinnedMessage();
    final sender = message == null ? '' : _senderNameOf(message);
    final pinnedBy = (_activePin?['pinned_by_name'] ?? '').toString().trim();
    final parts = <String>[
      if (sender.isNotEmpty) sender,
      if (pinnedBy.isNotEmpty && pinnedBy != sender) 'закрепил $pinnedBy',
    ];
    return parts.join(' • ');
  }

  Widget _buildActivePinPreview(ThemeData theme) {
    if (_activePin == null) return const SizedBox.shrink();
    final subtitle = _pinPreviewSubtitle();
    return GestureDetector(
      onTap: _jumpToPinnedMessage,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.push_pin_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Закреплённое сообщение',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _pinPreviewText(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              children: [
                if (_canPinMessages())
                  IconButton(
                    tooltip: 'Открепить',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _unpinMessage,
                  ),
                Icon(
                  Icons.arrow_outward_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
    final targetIndex = visibleMessages.indexWhere(
      (message) => (message['id'] ?? '').toString().trim() == messageId,
    );
    if (targetIndex < 0) return null;

    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) {
      return _messageItemKeys[messageId]?.currentContext;
    }

    final indexById = <String, int>{};
    for (var index = 0; index < visibleMessages.length; index++) {
      final id = (visibleMessages[index]['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      indexById[id] = index;
    }

    final viewportContext = _messagesViewportKey.currentContext;
    final viewportObject = viewportContext?.findRenderObject();
    final builtAnchors = <({int index, double top})>[];
    if (viewportObject is RenderBox) {
      for (final entry in _messageItemKeys.entries) {
        final builtIndex = indexById[entry.key.trim()];
        if (builtIndex == null) continue;
        final itemContext = entry.value.currentContext;
        final itemObject = itemContext?.findRenderObject();
        if (itemObject is! RenderBox || !itemObject.hasSize) continue;
        final topLeft = itemObject.localToGlobal(
          Offset.zero,
          ancestor: viewportObject,
        );
        builtAnchors.add((index: builtIndex, top: topLeft.dy));
      }
    }

    double ratioOffset() {
      if (visibleMessages.length <= 1) return 0.0;
      return (maxExtent * (targetIndex / (visibleMessages.length - 1)))
          .clamp(0.0, maxExtent)
          .toDouble();
    }

    double estimatedOffsetFromAnchors() {
      if (builtAnchors.isEmpty || viewportObject is! RenderBox) {
        return ratioOffset();
      }
      builtAnchors.sort((a, b) => a.index.compareTo(b.index));
      var pixelsPerMessage = 92.0;
      final first = builtAnchors.first;
      final last = builtAnchors.last;
      final indexDelta = last.index - first.index;
      final topDelta = last.top - first.top;
      if (indexDelta.abs() >= 1 && topDelta.abs() > 1) {
        pixelsPerMessage = (topDelta / indexDelta)
            .abs()
            .clamp(58.0, 260.0)
            .toDouble();
      }
      final nearest = builtAnchors.reduce((best, candidate) {
        final bestDistance = (best.index - targetIndex).abs();
        final nextDistance = (candidate.index - targetIndex).abs();
        if (nextDistance < bestDistance) return candidate;
        return best;
      });
      final desiredTop = viewportObject.size.height * 0.18;
      final estimatedTop =
          nearest.top + (targetIndex - nearest.index) * pixelsPerMessage;
      return (_scrollController.offset + estimatedTop - desiredTop)
          .clamp(0.0, maxExtent)
          .toDouble();
    }

    final attemptedOffsets = <double>[];

    Future<BuildContext?> attemptOffset(double offset) async {
      final clamped = offset.clamp(0.0, maxExtent).toDouble();
      if (attemptedOffsets.any((value) => (value - clamped).abs() < 2)) {
        return null;
      }
      attemptedOffsets.add(clamped);
      if (!_scrollController.hasClients) return null;
      _scrollController.jumpTo(clamped);
      await Future<void>.delayed(const Duration(milliseconds: 34));
      if (!mounted) return null;
      final resolved = _messageItemKeys[messageId]?.currentContext;
      if (resolved != null && resolved.mounted) {
        return resolved;
      }
      return null;
    }

    context = await attemptOffset(estimatedOffsetFromAnchors());
    if (context != null) return context;

    context = await attemptOffset(ratioOffset());
    if (context != null) return context;

    return _messageItemKeys[messageId]?.currentContext;
  }

  Future<void> _jumpToPinnedMessage() async {
    final pin = _activePin;
    if (pin == null) return;
    final messageId = (pin['message_id'] ?? '').toString().trim();
    if (messageId.isEmpty) return;

    await _jumpToMessageById(messageId);
  }

  Future<void> _jumpToFirstUnread() async {
    final messageId = (_firstUnreadMessageId ?? '').trim();
    if (messageId.isEmpty) return;
    await _jumpToMessageById(messageId);
  }

  Future<void> _jumpToMessageById(String messageId) async {
    final trimmedMessageId = messageId.trim();
    if (trimmedMessageId.isEmpty) return;
    _stickToBottom = false;
    _clearBottomSettle();

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
      trimmedMessageId,
    );
    if (targetContext == null) {
      try {
        final resp = await authService.dio.get(
          '/api/chats/${widget.chatId}/messages/$trimmedMessageId',
        );
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          _upsertMessage(
            Map<String, dynamic>.from(data['data']),
            autoScroll: false,
          );
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (!mounted) return;
          targetContext = await _resolveMessageContextWithScroll(trimmedMessageId);
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
    _handleScroll();
  }

  Future<void> _markChatAsRead() async {
    if (!_initialViewportReady || !_isNearBottom()) return;
    final visibleUntilMessageId = (_newestLoadedMessageId ?? '').trim();
    if (visibleUntilMessageId.isEmpty) return;
    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/read',
        data: {'visible_until_message_id': visibleUntilMessageId},
      );
      final data = resp.data;
      if (data is Map && data['data'] is Map) {
        final ids = ((data['data']['message_ids'] ?? const []) as List)
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toSet();
        _applyReadState(ids, readByMe: true);
        if (!mounted) {
          _firstUnreadMessageId = null;
          _unreadCount = 0;
        } else {
          setState(() {
            _firstUnreadMessageId = null;
            _unreadCount = 0;
          });
        }
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

  String _supportTicketStatusLabel() {
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    return messengerSupportStatusLabel(
      (settings['support_ticket_status'] ?? '').toString(),
    );
  }

  String _supportTicketAssigneeName() {
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    return (settings['support_assignee_name'] ?? '').toString().trim();
  }

  bool _supportTicketWaitingCustomer() {
    final settings = widget.chatSettings ?? const <String, dynamic>{};
    final raw = settings['support_waiting_customer'];
    if (raw is bool) return raw;
    final normalized = raw?.toString().trim().toLowerCase() ?? '';
    return normalized == 'true' || normalized == '1';
  }

  ({
    Color background,
    Color foreground,
    Color border,
    IconData icon,
  }) _supportBannerPalette(String statusRaw, ThemeData theme) {
    return switch (messengerSupportStatusTone(statusRaw)) {
      MessengerSupportStatusTone.success => (
        background: theme.colorScheme.tertiaryContainer,
        foreground: theme.colorScheme.onTertiaryContainer,
        border: theme.colorScheme.tertiary.withValues(alpha: 0.35),
        icon: Icons.task_alt_rounded,
      ),
      MessengerSupportStatusTone.secondary => (
        background: theme.colorScheme.secondaryContainer,
        foreground: theme.colorScheme.onSecondaryContainer,
        border: theme.colorScheme.secondary.withValues(alpha: 0.35),
        icon: Icons.schedule_rounded,
      ),
      MessengerSupportStatusTone.neutral => (
        background: theme.colorScheme.surfaceContainerHigh,
        foreground: theme.colorScheme.onSurface,
        border: theme.colorScheme.outlineVariant,
        icon: Icons.archive_outlined,
      ),
      MessengerSupportStatusTone.primary => (
        background: theme.colorScheme.primaryContainer,
        foreground: theme.colorScheme.onPrimaryContainer,
        border: theme.colorScheme.primary.withValues(alpha: 0.35),
        icon: Icons.support_agent_rounded,
      ),
    };
  }

  Widget _buildSupportBannerChip(
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

  Widget _buildSupportTicketBanner() {
    if (!_isSupportTicketChat()) return const SizedBox.shrink();
    final statusLabel = _supportTicketStatusLabel();
    final assigneeName = _supportTicketAssigneeName();
    if (statusLabel.isEmpty && assigneeName.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isArchived = _isArchivedSupportTicketChat();
    final statusRaw = ((widget.chatSettings ?? const <String, dynamic>{})['support_ticket_status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final palette = _supportBannerPalette(statusRaw, theme);
    final background = palette.background;
    final foreground = palette.foreground;
    final border = palette.border;
    final icon = palette.icon;
    final chipBackground = foreground.withValues(alpha: 0.08);
    final chipBorder = foreground.withValues(alpha: 0.16);
    final chips = <Widget>[
      if (statusLabel.isNotEmpty)
        _buildSupportBannerChip(
          theme,
          icon: icon,
          label: statusLabel,
          background: chipBackground,
          foreground: foreground,
          border: chipBorder,
        ),
      if (statusRaw == 'open')
        _buildSupportBannerChip(
          theme,
          icon: Icons.hourglass_bottom_rounded,
          label: messengerSupportWaitingLabel(
            waitingCustomer: _supportTicketWaitingCustomer(),
          ),
          background: chipBackground,
          foreground: foreground,
          border: chipBorder,
        ),
      if (assigneeName.isNotEmpty)
        _buildSupportBannerChip(
          theme,
          icon: Icons.person_outline_rounded,
          label: assigneeName,
          background: chipBackground,
          foreground: foreground,
          border: chipBorder,
        ),
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isArchived ? 'Обращение закрыто' : 'Статус обращения',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: chips,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
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

  Future<void> _loadMessages({bool showLoader = true}) async {
    if (_messagesLoadInFlight) return;
    _messagesLoadInFlight = true;
    var loadedSuccessfully = false;
    if (mounted && showLoader) {
      setState(() => _loading = true);
    }
    try {
      const maxAttempts = 3;
      Object? lastError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          final resp = await authService.dio.get(
            '/api/chats/${widget.chatId}/messages',
            queryParameters: const {'limit': 80},
            options: Options(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );
          final data = resp.data;
          if (data is Map && data['ok'] == true && data['data'] is List) {
            final serverMessages = List<Map<String, dynamic>>.from(data['data'])
              ..sort(_compareByCreatedAt);
            final messages = _mergeServerMessagesWithLocalState(serverMessages);
            final paging = _chatStateMapOf(data['paging']);
            final state = _chatStateMapOf(data['state']);
            if (mounted) {
              setState(() {
                _messages = messages;
                _incomingQueue.clear();
                _appearingMessageIds.clear();
                _hasMoreBefore = paging['has_more_before'] == true;
                _messageIds
                  ..clear()
                  ..addAll(
                    messages
                        .map((m) => m['id']?.toString())
                        .where((id) => id != null && id.isNotEmpty)
                        .cast<String>(),
                  );
                _messageItemKeys.removeWhere(
                  (id, _) => !_messageIds.contains(id),
                );
                _applyServerChatState(state, restoreDraft: false);
                _refreshLoadedMessageBounds();
              });
            } else {
              _messages = messages;
              _hasMoreBefore = paging['has_more_before'] == true;
              _applyServerChatState(state, restoreDraft: false);
              _refreshLoadedMessageBounds();
            }
            _incomingTimer?.cancel();
            _incomingTimer = null;
            _recomputeSearchResults(keepCurrent: false);
            if (kIsWeb) {
              unawaited(primeWebImageCache(_initialChannelImageBatch(messages)));
            }
            unawaited(
              _warmUpVisibleImageDimensions(
                messages,
                limit: 10,
                refreshAfterWarmUp: true,
              ),
            );
            loadedSuccessfully = true;
          }
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          debugPrint(
            'Error loading messages (attempt $attempt/$maxAttempts): $e',
          );
          final shouldRetry =
              _isTransientMessageLoadError(e) && attempt < maxAttempts;
          if (!shouldRetry) {
            break;
          }
          await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
        }
      }
      if (lastError != null) {
        debugPrint('Error loading messages: $lastError');
        if (mounted &&
            _messages.isEmpty &&
            _isTransientMessageLoadError(lastError)) {
          showAppNotice(
            context,
            'Сеть нестабильна, пробуем загрузить чат повторно',
            tone: AppNoticeTone.warning,
            duration: const Duration(seconds: 2),
          );
        }
      }
    } finally {
      _messagesLoadInFlight = false;
      if (mounted && showLoader) {
        setState(() => _loading = false);
      } else if (!mounted) {
        _loading = false;
      }
      if (loadedSuccessfully) {
        _applyInitialViewportAfterLoad();
      } else {
        _markInitialViewportReady();
      }
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlderMessages ||
        _messagesLoadInFlight ||
        !_hasMoreBefore ||
        _oldestLoadedMessageId == null ||
        _oldestLoadedCreatedAt == null) {
      return;
    }
    _loadingOlderMessages = true;
    final hadClients = _scrollController.hasClients;
    final previousPixels = hadClients ? _scrollController.position.pixels : 0.0;
    final previousMaxExtent = hadClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages',
        queryParameters: {
          'before_created_at': _oldestLoadedCreatedAt,
          'before_id': _oldestLoadedMessageId,
          'limit': 60,
        },
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! List) return;
      final pageMessages = List<Map<String, dynamic>>.from(data['data'])
        ..sort(_compareByCreatedAt);
      final paging = _chatStateMapOf(data['paging']);
      final state = _chatStateMapOf(data['state']);
      if (pageMessages.isEmpty) {
        if (mounted) {
          setState(() {
            _hasMoreBefore = paging['has_more_before'] == true;
            _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
          });
        } else {
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
        }
        return;
      }
      final existingIds = _messages.map(_messageIdOf).where((id) => id.isNotEmpty).toSet();
      final toInsert = pageMessages
          .where((message) => !existingIds.contains(_messageIdOf(message)))
          .toList(growable: false);
      if (toInsert.isEmpty) {
        if (mounted) {
          setState(() {
            _hasMoreBefore = paging['has_more_before'] == true;
            _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
          });
        } else {
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
        }
        return;
      }
      if (mounted) {
        setState(() {
          _messages = [...toInsert, ..._messages]..sort(_compareByCreatedAt);
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
          _messageIds
            ..clear()
            ..addAll(
              _messages
                  .map(_messageIdOf)
                  .where((id) => id.isNotEmpty),
            );
          _refreshLoadedMessageBounds();
        });
      } else {
        _messages = [...toInsert, ..._messages]..sort(_compareByCreatedAt);
        _hasMoreBefore = paging['has_more_before'] == true;
        _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
        _refreshLoadedMessageBounds();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final nextMaxExtent = _scrollController.position.maxScrollExtent;
        final delta = nextMaxExtent - previousMaxExtent;
        final target = (previousPixels + max(0.0, delta))
            .clamp(0.0, nextMaxExtent)
            .toDouble();
        _scrollController.jumpTo(target);
      });
    } catch (_) {
      // ignore transient older-page failures
    } finally {
      _loadingOlderMessages = false;
    }
  }

  Future<void> _replayMissedMessagesAfterReconnect() async {
    if (_loadingNewerMessages || _messagesLoadInFlight) return;
    final newestId = _newestLoadedMessageId;
    final newestCreatedAt = _newestLoadedCreatedAt;
    if ((newestId ?? '').isEmpty || (newestCreatedAt ?? '').isEmpty) {
      await _loadMessages(showLoader: false);
      return;
    }
    _loadingNewerMessages = true;
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages',
        queryParameters: {
          'after_created_at': newestCreatedAt,
          'after_id': newestId,
          'limit': 80,
        },
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! List) {
        return;
      }
      final pageMessages = List<Map<String, dynamic>>.from(data['data'])
        ..sort(_compareByCreatedAt);
      final paging = _chatStateMapOf(data['paging']);
      final state = _chatStateMapOf(data['state']);
      if (mounted) {
        setState(() {
          for (final message in pageMessages) {
            final id = _messageIdOf(message);
            final clientMsgId = (message['client_msg_id'] ?? '')
                .toString()
                .trim();
            final index = _messageIndexInList(
              _messages,
              messageId: id,
              clientMsgId: clientMsgId,
            );
            if (index >= 0) {
              _messages[index] = {..._messages[index], ...message};
            } else {
              _messages.add(message);
            }
          }
          _messages.sort(_compareByCreatedAt);
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
          _messageIds
            ..clear()
            ..addAll(
              _messages.map(_messageIdOf).where((id) => id.isNotEmpty),
            );
          _refreshLoadedMessageBounds();
        });
      } else {
        for (final message in pageMessages) {
          final id = _messageIdOf(message);
          final clientMsgId = (message['client_msg_id'] ?? '')
              .toString()
              .trim();
          final index = _messageIndexInList(
            _messages,
            messageId: id,
            clientMsgId: clientMsgId,
          );
          if (index >= 0) {
            _messages[index] = {..._messages[index], ...message};
          } else {
            _messages.add(message);
          }
        }
        _messages.sort(_compareByCreatedAt);
        _hasMoreBefore = paging['has_more_before'] == true;
        _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
        _refreshLoadedMessageBounds();
      }
      _recomputeSearchResults();
      if (_isNearBottom()) {
        _scheduleReadSync();
      }
    } catch (_) {
      // ignore replay issues; next socket/API refresh will recover
    } finally {
      _loadingNewerMessages = false;
    }
  }

  bool _isTransientMessageLoadError(Object error) {
    if (error is! DioException) return false;
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    final text = (error.message ?? '').toLowerCase();
    return text.contains('xmlhttprequest error') ||
        text.contains('network error') ||
        text.contains('connection refused') ||
        text.contains('failed host lookup') ||
        text.contains('socketexception') ||
        text.contains('network is unreachable') ||
        text.contains('http2') ||
        text.contains('ping failed');
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

  List<ChatMediaViewerEntry> _chatMediaViewerEntries() {
    final entries = <ChatMediaViewerEntry>[];
    for (final item in _messages) {
      final meta = _metaMapOf(item['meta']);
      final imageUrl = _resolveImageUrl(meta['image_url']?.toString());
      if (imageUrl == null || imageUrl.isEmpty) continue;
      if (_isHiddenForAll(item)) continue;
      final entryId =
          _messageIdOf(item).trim().isNotEmpty
              ? _messageIdOf(item).trim()
              : '${item['client_msg_id'] ?? imageUrl}-${item['created_at'] ?? ''}';
      entries.add(
        ChatMediaViewerEntry(
          id: entryId,
          imageUrl: imageUrl,
          caption: _captionTextOf(item, meta),
          senderName: _senderNameOf(item),
          timeLabel: _formatMessageTime(item['created_at']),
        ),
      );
    }
    return entries;
  }

  Future<void> _openImagePreviewForMessage(
    Map<String, dynamic> message,
    String imageUrl,
  ) async {
    final gallery = _chatMediaViewerEntries();
    if (gallery.isEmpty) {
      await showChatMediaViewer(
        context,
        entries: <ChatMediaViewerEntry>[
          ChatMediaViewerEntry(
            id: _messageIdOf(message).trim().isNotEmpty
                ? _messageIdOf(message).trim()
                : imageUrl,
            imageUrl: imageUrl,
            caption: _captionTextOf(message, _metaMapOf(message['meta'])),
            senderName: _senderNameOf(message),
            timeLabel: _formatMessageTime(message['created_at']),
          ),
        ],
      );
      return;
    }

    final targetId = _messageIdOf(message).trim();
    var initialIndex = gallery.indexWhere((entry) => entry.id == targetId);
    if (initialIndex < 0) {
      initialIndex = gallery.indexWhere((entry) => entry.imageUrl == imageUrl);
    }
    if (initialIndex < 0) initialIndex = 0;

    await showChatMediaViewer(
      context,
      entries: gallery,
      initialIndex: initialIndex,
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
        withData: true,
      );
      final picked = result?.files.single;
      if (picked == null) return null;
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) return null;
      final preprocessed = await preprocessChatImageForMessage(
        bytes: bytes,
        filename: picked.name.isNotEmpty ? picked.name : 'image.jpg',
      );
      return _ChatUploadFile(
        filename: preprocessed.filename,
        bytes: preprocessed.bytes,
        mimeType: preprocessed.mimeType,
        width: preprocessed.width,
        height: preprocessed.height,
        preprocessTag: preprocessed.preprocessTag,
      );
    }

    final picked = await _imagePicker.pickImage(source: source);
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return null;
    final preprocessed = await preprocessChatImageForMessage(
      bytes: bytes,
      filename: picked.name.isNotEmpty
          ? picked.name
          : picked.path.split('/').last,
    );
    return _ChatUploadFile(
      filename: preprocessed.filename,
      bytes: preprocessed.bytes,
      mimeType: preprocessed.mimeType,
      width: preprocessed.width,
      height: preprocessed.height,
      preprocessTag: preprocessed.preprocessTag,
    );
  }

  Future<void> _postMediaMessage({
    required _ChatUploadFile upload,
    required String attachmentType,
    required String clientMsgId,
    required String caption,
    required Map<String, dynamic> replyPayload,
    int? durationMs,
  }) async {
    var lastReportedBucket = -1;
    final form = FormData.fromMap({
      if (attachmentType == 'image') 'image': await _multipartFromUpload(upload),
      if (attachmentType == 'image' && (upload.width ?? 0) > 0)
        'image_width': upload.width,
      if (attachmentType == 'image' && (upload.height ?? 0) > 0)
        'image_height': upload.height,
      if (attachmentType == 'image' &&
          (upload.width ?? 0) > 0 &&
          (upload.height ?? 0) > 0)
        'image_aspect_ratio':
            (upload.width! / upload.height!).toStringAsFixed(4),
      if (attachmentType == 'image' &&
          (upload.preprocessTag ?? '').trim().isNotEmpty)
        'image_preprocess': upload.preprocessTag!.trim(),
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
      ...replyPayload,
      if (caption.trim().isNotEmpty) 'text': caption.trim(),
      if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
    });

    final resp = await authService.dio.post(
      '/api/chats/${widget.chatId}/messages/media',
      data: form,
      onSendProgress: (sent, total) {
        if (total <= 0) return;
        final progress = (sent / total).clamp(0.0, 1.0).toDouble();
        final bucket = (progress * 100).floor();
        if (bucket == lastReportedBucket) return;
        lastReportedBucket = bucket;
        _patchMessageLocally(
          clientMsgId: clientMsgId,
          transform: (current) {
            final nextMeta = _metaMapOf(current['meta']);
            nextMeta['delivery_status'] = progress >= 0.995
                ? 'sending'
                : 'uploading';
            nextMeta['local_upload_progress'] = progress;
            nextMeta.remove('error_message');
            return {
              ...current,
              'meta': nextMeta,
            };
          },
        );
      },
    );

    if (resp.statusCode == 200 || resp.statusCode == 201) {
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        _upsertMessage(Map<String, dynamic>.from(data['data']), autoScroll: true);
        return;
      }
      await _loadMessages(showLoader: false);
      return;
    }
    throw Exception('Сервер не принял вложение');
  }

  Future<void> _sendMediaMessage({
    required _ChatUploadFile upload,
    required String attachmentType,
    int? durationMs,
  }) async {
    if (!_canCompose()) return;
    final clientMsgId = _generateClientMessageId();
    final replyPayload = _currentReplyPayload();
    final caption = attachmentType == 'image' || attachmentType == 'video'
        ? _controller.text.trim()
        : '';
    final optimisticMessage = _buildOptimisticMediaMessage(
      clientMsgId: clientMsgId,
      upload: upload,
      attachmentType: attachmentType,
      caption: caption,
      replyPayload: replyPayload,
      durationMs: durationMs,
    );
    if (attachmentType == 'image' || attachmentType == 'video') {
      _controller.clear();
    }
    _clearReplyComposer();
    _upsertMessage(optimisticMessage, autoScroll: true);
    setState(() {
      _mediaUploading = attachmentType == 'image' || attachmentType == 'video';
      _voiceSending = attachmentType == 'voice';
    });
    try {
      await _postMediaMessage(
        upload: upload,
        attachmentType: attachmentType,
        clientMsgId: clientMsgId,
        caption: caption,
        replyPayload: replyPayload,
        durationMs: durationMs,
      );
      await playAppSound(AppUiSound.sent);
    } catch (e) {
      _patchMessageLocally(
        clientMsgId: clientMsgId,
        transform: (current) {
          final nextMeta = _metaMapOf(current['meta']);
          nextMeta['delivery_status'] = 'error';
          nextMeta['error_message'] = _extractDioError(e);
          nextMeta.remove('local_upload_progress');
          return {
            ...current,
            'meta': nextMeta,
          };
        },
      );
      if (!mounted) return;
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

  Future<String?> _openFullReactionPicker() async {
    final baseCategories = _reactionEmojiCategories.entries
        .where((entry) => entry.value.isNotEmpty)
        .toList(growable: false);
    final categories = <MapEntry<String, List<String>>>[
      if (_recentReactionEmojis.isNotEmpty)
        MapEntry('Недавние', List<String>.from(_recentReactionEmojis)),
      ...baseCategories,
    ];
    if (categories.isEmpty) return null;

    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return DefaultTabController(
          length: categories.length,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.66,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Выберите реакцию',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: categories
                          .map((entry) => Tab(text: entry.key))
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TabBarView(
                        children: categories.map((entry) {
                          final emojis = entry.value;
                          return GridView.builder(
                            padding: const EdgeInsets.only(top: 4),
                            itemCount: emojis.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 6,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                  childAspectRatio: 1,
                                ),
                            itemBuilder: (context, index) {
                              final emoji = emojis[index];
                              return InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => Navigator.of(ctx).pop(emoji),
                                child: Ink(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                  ),
                                  child: Center(
                                    child: Text(
                                      emoji,
                                      style: const TextStyle(fontSize: 28),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        }).toList(growable: false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
        if (!granted ||
            access != WebMediaCaptureAccessState.grantedAudioVideo) {
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

  Map<String, dynamic> _currentReplyPayload() {
    final replyId = (_replyToMessageId ?? '').trim();
    if (replyId.isEmpty) return const <String, dynamic>{};
    final payload = <String, dynamic>{'reply_to_message_id': replyId};
    final previewText = (_replyPreviewText ?? '').trim();
    final previewSender = (_replyPreviewSenderName ?? '').trim();
    if (previewText.isNotEmpty) {
      payload['reply_preview_text'] = previewText;
    }
    if (previewSender.isNotEmpty) {
      payload['reply_preview_sender_name'] = previewSender;
    }
    return payload;
  }

  Map<String, dynamic> _buildTextRetryPayload({
    required String text,
    required Map<String, dynamic> replyPayload,
  }) {
    return <String, dynamic>{
      'kind': 'text',
      'text': text,
      if ((replyPayload['reply_to_message_id'] ?? '').toString().trim().isNotEmpty)
        'reply_to_message_id': replyPayload['reply_to_message_id'],
      if ((replyPayload['reply_preview_text'] ?? '').toString().trim().isNotEmpty)
        'reply_preview_text': replyPayload['reply_preview_text'],
      if ((replyPayload['reply_preview_sender_name'] ?? '')
          .toString()
          .trim()
          .isNotEmpty)
        'reply_preview_sender_name': replyPayload['reply_preview_sender_name'],
    };
  }

  Map<String, dynamic> _extractReplyPayloadFromRetryPayload(
    Map<String, dynamic> retryPayload,
  ) {
    final replyPayload = <String, dynamic>{};
    for (final key in <String>[
      'reply_to_message_id',
      'reply_preview_text',
      'reply_preview_sender_name',
    ]) {
      final value = (retryPayload[key] ?? '').toString().trim();
      if (value.isNotEmpty) {
        replyPayload[key] = value;
      }
    }
    return replyPayload;
  }

  String _optimisticMediaText(String attachmentType, {required String caption}) {
    if (caption.trim().isNotEmpty) return caption.trim();
    switch (attachmentType) {
      case 'image':
        return 'Фото';
      case 'video':
        return 'Видеосообщение';
      case 'voice':
        return 'Голосовое сообщение';
      default:
        return 'Вложение';
    }
  }

  String? _localImagePreviewUrl(_ChatUploadFile upload) {
    final bytes = upload.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    final mimeType = (upload.mimeType ?? '').trim().isNotEmpty
        ? upload.mimeType!.trim()
        : 'image/jpeg';
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  }

  Map<String, dynamic> _buildMediaRetryPayload({
    required _ChatUploadFile upload,
    required String attachmentType,
    required Map<String, dynamic> replyPayload,
    required String caption,
    int? durationMs,
  }) {
    return <String, dynamic>{
      'kind': 'media',
      'attachment_type': attachmentType,
      'filename': upload.filename,
      if ((upload.path ?? '').trim().isNotEmpty) 'path': upload.path!.trim(),
      if (upload.bytes != null) 'bytes': upload.bytes,
      if ((upload.mimeType ?? '').trim().isNotEmpty)
        'mime_type': upload.mimeType!.trim(),
      if (upload.width != null) 'width': upload.width,
      if (upload.height != null) 'height': upload.height,
      if ((upload.preprocessTag ?? '').trim().isNotEmpty)
        'preprocess_tag': upload.preprocessTag!.trim(),
      if (caption.trim().isNotEmpty) 'caption': caption.trim(),
      if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
      ...replyPayload,
    };
  }

  _ChatUploadFile? _uploadFromRetryPayload(Map<String, dynamic> retryPayload) {
    final filename = (retryPayload['filename'] ?? '').toString().trim();
    final path = (retryPayload['path'] ?? '').toString().trim();
    final rawBytes = retryPayload['bytes'];
    Uint8List? bytes;
    if (rawBytes is Uint8List) {
      bytes = rawBytes;
    } else if (rawBytes is List<int>) {
      bytes = Uint8List.fromList(rawBytes);
    } else if (rawBytes is List) {
      final ints = rawBytes
          .map((item) => item is int ? item : int.tryParse('$item') ?? -1)
          .where((value) => value >= 0 && value <= 255)
          .cast<int>()
          .toList(growable: false);
      if (ints.isNotEmpty) {
        bytes = Uint8List.fromList(ints);
      }
    }
    if (path.isEmpty && (bytes == null || bytes.isEmpty)) {
      return null;
    }
    return _ChatUploadFile(
      filename: filename.isNotEmpty ? filename : 'attachment.bin',
      path: path.isNotEmpty ? path : null,
      bytes: bytes,
      mimeType: (retryPayload['mime_type'] ?? '').toString().trim().isNotEmpty
          ? (retryPayload['mime_type'] ?? '').toString().trim()
          : null,
      width: retryPayload['width'] is num
          ? (retryPayload['width'] as num).toInt()
          : int.tryParse('${retryPayload['width'] ?? ''}'),
      height: retryPayload['height'] is num
          ? (retryPayload['height'] as num).toInt()
          : int.tryParse('${retryPayload['height'] ?? ''}'),
      preprocessTag:
          (retryPayload['preprocess_tag'] ?? '').toString().trim().isNotEmpty
          ? (retryPayload['preprocess_tag'] ?? '').toString().trim()
          : null,
    );
  }

  bool _retryPayloadCanBeRetried(Map<String, dynamic> retryPayload) {
    final kind = (retryPayload['kind'] ?? '').toString().trim();
    if (kind == 'text') {
      return (retryPayload['text'] ?? '').toString().trim().isNotEmpty;
    }
    if (kind == 'media') {
      return _uploadFromRetryPayload(retryPayload) != null;
    }
    return false;
  }

  Map<String, dynamic> _buildOptimisticMediaMessage({
    required String clientMsgId,
    required _ChatUploadFile upload,
    required String attachmentType,
    required String caption,
    required Map<String, dynamic> replyPayload,
    int? durationMs,
  }) {
    final currentUser = authService.currentUser;
    final previewUrl = attachmentType == 'image'
        ? _localImagePreviewUrl(upload)
        : null;
    final retryPayload = _buildMediaRetryPayload(
      upload: upload,
      attachmentType: attachmentType,
      replyPayload: replyPayload,
      caption: caption,
      durationMs: durationMs,
    );
    final meta = <String, dynamic>{
      'attachment_type': attachmentType,
      'local_only': true,
      'delivery_status': 'uploading',
      'local_upload_progress': 0.0,
      'retry_payload': retryPayload,
      ...replyPayload,
      if (attachmentType == 'image' && previewUrl != null) 'image_url': previewUrl,
      if (attachmentType == 'image' && (upload.width ?? 0) > 0)
        'image_width': upload.width,
      if (attachmentType == 'image' && (upload.height ?? 0) > 0)
        'image_height': upload.height,
      if (attachmentType == 'voice' && (durationMs ?? 0) > 0)
        'voice_duration_ms': durationMs,
      if (attachmentType == 'video' && (durationMs ?? 0) > 0)
        'video_duration_ms': durationMs,
      if (caption.trim().isNotEmpty && attachmentType != 'voice')
        'caption': caption.trim(),
    };
    return <String, dynamic>{
      'id': 'temp-$clientMsgId',
      'client_msg_id': clientMsgId,
      'chat_id': widget.chatId,
      'sender_id': currentUser?.id,
      'sender_name': currentUser?.name?.trim().isNotEmpty == true
          ? currentUser!.name!.trim()
          : 'Вы',
      'text': _optimisticMediaText(attachmentType, caption: caption),
      'created_at': DateTime.now().toIso8601String(),
      'from_me': true,
      'read_by_others': false,
      'read_count': 0,
      'meta': meta,
    };
  }

  Map<String, dynamic> _retryPayloadOf(Map<String, dynamic> meta) {
    final raw = meta['retry_payload'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  bool _isRetryableFailedMessage(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    if (meta['local_only'] != true) return false;
    if ((meta['delivery_status'] ?? '').toString().trim() != 'error') {
      return false;
    }
    final retryPayload = _retryPayloadOf(meta);
    return _retryPayloadCanBeRetried(retryPayload);
  }

  Future<void> _retryFailedMessage(Map<String, dynamic> message) async {
    if (!_isRetryableFailedMessage(message)) return;
    final meta = _metaMapOf(message['meta']);
    final retryPayload = _retryPayloadOf(meta);
    final retryKind = (retryPayload['kind'] ?? '').toString().trim();
    if (retryKind == 'media') {
      final upload = _uploadFromRetryPayload(retryPayload);
      final attachmentType = (retryPayload['attachment_type'] ?? '')
          .toString()
          .trim();
      if (upload == null || attachmentType.isEmpty) return;
      final replyPayload = _extractReplyPayloadFromRetryPayload(retryPayload);
      final nextClientMsgId = _generateClientMessageId();
      final sendingMessage = _buildOptimisticMediaMessage(
        clientMsgId: nextClientMsgId,
        upload: upload,
        attachmentType: attachmentType,
        caption: (retryPayload['caption'] ?? '').toString(),
        replyPayload: replyPayload,
        durationMs: int.tryParse('${retryPayload['duration_ms'] ?? 0}'),
      );
      _upsertMessage(
        {
          ...message,
          'id': 'temp-$nextClientMsgId',
          'client_msg_id': nextClientMsgId,
          'text': sendingMessage['text'],
          'meta': sendingMessage['meta'],
        },
        autoScroll: true,
      );
      try {
        await _postMediaMessage(
          upload: upload,
          attachmentType: attachmentType,
          clientMsgId: nextClientMsgId,
          caption: (retryPayload['caption'] ?? '').toString(),
          replyPayload: replyPayload,
          durationMs: int.tryParse('${retryPayload['duration_ms'] ?? 0}'),
        );
        await playAppSound(AppUiSound.sent);
      } catch (e) {
        _patchMessageLocally(
          clientMsgId: nextClientMsgId,
          transform: (current) {
            final nextMeta = _metaMapOf(current['meta']);
            nextMeta['delivery_status'] = 'error';
            nextMeta['error_message'] = _extractDioError(e);
            nextMeta.remove('local_upload_progress');
            return {
              ...current,
              'meta': nextMeta,
            };
          },
        );
        if (!mounted) return;
        showAppNotice(
          context,
          'Не удалось повторно отправить вложение',
          tone: AppNoticeTone.error,
          duration: const Duration(seconds: 2),
        );
      }
      return;
    }

    final text = (retryPayload['text'] ?? message['text'] ?? '')
        .toString()
        .trim();
    if (text.isEmpty) return;

    final nextClientMsgId = _generateClientMessageId();
    final replyPayload = _extractReplyPayloadFromRetryPayload(retryPayload);

    final sendingMeta = <String, dynamic>{
      ...meta,
      ...replyPayload,
      'local_only': true,
      'delivery_status': 'sending',
      'retry_payload': retryPayload,
    };
    sendingMeta.remove('error_message');

    _upsertMessage({
      ...message,
      'client_msg_id': nextClientMsgId,
      'meta': sendingMeta,
    });

    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/messages',
        data: {
          'text': text,
          'client_msg_id': nextClientMsgId,
          ...replyPayload,
        },
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final data = resp.data;
        if (data is Map && data['ok'] == true && data['data'] is Map) {
          _upsertMessage(
            Map<String, dynamic>.from(data['data']),
            autoScroll: true,
          );
          await playAppSound(AppUiSound.sent);
          return;
        }
      }
      throw Exception('Сервер не принял повторную отправку');
    } catch (e) {
      _upsertMessage({
        ...message,
        'client_msg_id': nextClientMsgId,
        'meta': {
          ...sendingMeta,
          'delivery_status': 'error',
          'error_message': _extractDioError(e),
        },
      });
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось повторно отправить сообщение',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
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
    final replyPayload = _currentReplyPayload();
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
      'meta': {
        'delivery_status': 'sending',
        'local_only': true,
        'retry_payload': _buildTextRetryPayload(
          text: text,
          replyPayload: replyPayload,
        ),
        ...replyPayload,
      },
    };
    _controller.clear();
    _clearReplyComposer();
    _upsertMessage(optimisticMessage, autoScroll: true);

    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/messages',
        data: {'text': text, 'client_msg_id': clientMsgId, ...replyPayload},
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
        'error_message': _extractDioError(e),
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

  String _reservedDateLabelOf(Map<String, dynamic> message) {
    final date = _parseDate(message['created_at']);
    return date == null ? 'Без даты' : _formatDateLabel(date);
  }

  DateTime? _reservedDayOf(Map<String, dynamic> message) {
    final date = _parseDate(message['created_at']);
    if (date == null) return null;
    return DateTime(date.year, date.month, date.day);
  }

  String _reservedShelfLabelOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final processingMode = (meta['processing_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (processingMode == 'oversize' || meta['is_oversize'] == true) {
      return 'Габарит';
    }
    final shelf = (meta['shelf_number'] ?? '').toString().trim();
    return shelf.isEmpty ? 'Без полки' : 'Полка $shelf';
  }

  int _reservedShelfSortKeyOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final processingMode = (meta['processing_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (processingMode == 'oversize' || meta['is_oversize'] == true) {
      return 1 << 20;
    }
    final shelf = int.tryParse((meta['shelf_number'] ?? '').toString().trim());
    return shelf ?? ((1 << 20) - 1);
  }

  String _reservedClientNameOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final name = (meta['client_name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final senderName = _senderNameOf(message).trim();
    return senderName.isNotEmpty ? senderName : 'Клиент';
  }

  String _reservedClientPhoneOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    return _formatDisplayPhone(
      (meta['client_phone'] ?? '').toString().trim(),
      fallback: '',
    );
  }

  int _compareReservedTimelineMessages(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final dayA = _reservedDayOf(a);
    final dayB = _reservedDayOf(b);
    if (dayA == null && dayB != null) return -1;
    if (dayA != null && dayB == null) return 1;
    if (dayA != null && dayB != null) {
      final byDay = dayA.compareTo(dayB);
      if (byDay != 0) return byDay;
    }

    final byShelf = _reservedShelfSortKeyOf(a).compareTo(_reservedShelfSortKeyOf(b));
    if (byShelf != 0) return byShelf;

    final byClientName = _reservedClientNameOf(a).toLowerCase().compareTo(
      _reservedClientNameOf(b).toLowerCase(),
    );
    if (byClientName != 0) return byClientName;

    final byClientPhone = _reservedClientPhoneOf(a).compareTo(
      _reservedClientPhoneOf(b),
    );
    if (byClientPhone != 0) return byClientPhone;

    final byTime = _compareByCreatedAt(a, b);
    if (byTime != 0) return byTime;

    final productA = int.tryParse(_reservedProductCodeOf(a) ?? '') ?? 0;
    final productB = int.tryParse(_reservedProductCodeOf(b) ?? '') ?? 0;
    return productA.compareTo(productB);
  }

  String _reservedSectionKeyOf(Map<String, dynamic> message) {
    return [
      _reservedDateLabelOf(message),
      _reservedShelfLabelOf(message),
      _reservedClientNameOf(message),
      _reservedClientPhoneOf(message),
    ].join('|');
  }

  bool _reservedIsPlaced(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final cartItemId = (meta['cart_item_id'] ?? '').toString().trim();
    return meta['placed'] == true ||
        (cartItemId.isNotEmpty && _placedCartItemIds.contains(cartItemId));
  }

  bool _reservedIsOversize(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final processingMode = (meta['processing_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return processingMode == 'oversize' || meta['is_oversize'] == true;
  }

  String _reservedShelfNumberValue(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    return (meta['shelf_number'] ?? '').toString().trim();
  }

  bool _matchesReservedQuickFilter(
    Map<String, dynamic> message, {
    MessengerReservedQuickFilter? filter,
  }) {
    if (!_isReservedOrdersChat() && !_isReservedOrder(message)) return true;
    return messengerMatchesReservedQuickFilter(
      filter: filter ?? _reservedQuickFilter,
      isPlaced: _reservedIsPlaced(message),
      isOversize: _reservedIsOversize(message),
      shelfNumber: _reservedShelfNumberValue(message),
    );
  }

  List<Map<String, dynamic>> _messagesMatchingCurrentSearch() {
    if (_searchQuery.trim().isNotEmpty && _serverSearchLoaded) {
      return [..._serverSearchMessages]..sort(_compareByCreatedAt);
    }
    return _messages.where((m) => _messageMatchesSearch(m, _searchQuery)).toList()
      ..sort(_compareByCreatedAt);
  }

  int _reservedQuickFilterCount(MessengerReservedQuickFilter filter) {
    return _messagesMatchingCurrentSearch()
        .where((message) => _matchesReservedQuickFilter(message, filter: filter))
        .length;
  }

  Widget _buildReservedQuickFilterBar() {
    if (!_isReservedOrdersChat()) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final baseMessages = _messagesMatchingCurrentSearch();
    if (baseMessages.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: MessengerReservedQuickFilter.values.map((filter) {
            final count = _reservedQuickFilterCount(filter);
            final selected = _reservedQuickFilter == filter;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(
                  '${messengerReservedQuickFilterLabel(filter)} · $count',
                ),
                selected: selected,
                onSelected: (_) {
                  if (!mounted) return;
                  setState(() => _reservedQuickFilter = filter);
                },
                visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
                selectedColor: theme.colorScheme.secondaryContainer,
                side: BorderSide(
                  color: selected
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.outlineVariant,
                ),
                labelStyle: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: selected
                      ? theme.colorScheme.onSecondaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }).toList(growable: false),
        ),
      ),
    );
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

  bool _canMarkReservedOrderPlaced() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin' || role == 'creator';
  }

  bool _requiresManualShelfOnPlaced() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin' || role == 'tenant' || role == 'creator';
  }

  bool get _canUseDesktopStickerPrinting {
    return isStickerPrintSupported && _canMarkReservedOrderPlaced();
  }

  String _reservedOrderPriceLabel(dynamic raw) {
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) return '';
    return text.contains('₽') ? text : '$text ₽';
  }

  String _formatDisplayPhone(String raw, {String fallback = '—'}) {
    final formatted = PhoneUtils.formatForDisplay(raw);
    if (formatted.isNotEmpty) return formatted;
    final trimmed = raw.trim();
    return trimmed.isNotEmpty ? trimmed : fallback;
  }

  StickerPrintJob _reservedOrderStickerJob(
    Map<String, dynamic> meta, {
    required bool oversize,
  }) {
    final phone = _formatDisplayPhone(
      (meta['client_phone'] ?? '').toString().trim(),
    );
    final name = (meta['client_name'] ?? '').toString().trim();
    final title = (meta['title'] ?? '').toString().trim();
    final priceLabel = _reservedOrderPriceLabel(meta['price']);
    return StickerPrintJob(
      phone: phone.isEmpty ? '—' : phone,
      name: name.isEmpty ? 'Клиент' : name,
      productTitle: oversize && title.isNotEmpty ? title : null,
      priceLabel: oversize && priceLabel.isNotEmpty ? priceLabel : null,
      kindLabel: oversize ? 'Габарит' : null,
      showFooter: true,
      footerText: 'Феникс',
    );
  }

  Future<void> _openReservedOrderStickerPrint(
    Map<String, dynamic> meta, {
    required bool oversize,
  }) async {
    await printStickerJob(_reservedOrderStickerJob(meta, oversize: oversize));
    if (!mounted) return;
    showAppNotice(
      context,
      oversize
          ? 'Печать габаритной наклейки открыта'
          : 'Печать клиентской наклейки открыта',
      tone: AppNoticeTone.info,
      duration: const Duration(seconds: 3),
    );
  }

  void _patchReservedOrderMessageLocally({
    String? reservationId,
    String? cartItemId,
    required Map<String, dynamic> patch,
  }) {
    final reservationKey = (reservationId ?? '').trim();
    final cartItemKey = (cartItemId ?? '').trim();
    if (reservationKey.isEmpty && cartItemKey.isEmpty) return;
    setState(() {
      _messages = _messages.map((message) {
        final meta = _metaMapOf(message['meta']);
        if (meta['kind']?.toString() != 'reserved_order_item') return message;
        final messageReservationId = (meta['reservation_id'] ?? '')
            .toString()
            .trim();
        final messageCartItemId = (meta['cart_item_id'] ?? '')
            .toString()
            .trim();
        final matchesReservation =
            reservationKey.isNotEmpty && messageReservationId == reservationKey;
        final matchesCartItem =
            cartItemKey.isNotEmpty && messageCartItemId == cartItemKey;
        if (!matchesReservation && !matchesCartItem) return message;
        return {
          ...message,
          'meta': Map<String, dynamic>.from(meta)..addAll(patch),
        };
      }).toList();
    });
  }

  void _patchReservedUserShelfLocally({
    required String userId,
    required int shelfNumber,
  }) {
    final userKey = userId.trim();
    if (userKey.isEmpty || shelfNumber <= 0) return;
    setState(() {
      _messages = _messages.map((message) {
        final meta = _metaMapOf(message['meta']);
        if (meta['kind']?.toString() != 'reserved_order_item') return message;
        final messageUserId = (meta['user_id'] ?? '').toString().trim();
        final processingMode = (meta['processing_mode'] ?? 'standard')
            .toString()
            .trim()
            .toLowerCase();
        if (messageUserId != userKey || processingMode == 'oversize') {
          return message;
        }
        return {
          ...message,
          'meta': Map<String, dynamic>.from(meta)..['shelf_number'] = shelfNumber,
        };
      }).toList();
    });
  }

  Future<int?> _promptShelfNumber({
    String title = 'Укажите полку',
    String initialValue = '',
  }) async {
    var shelfDraft = initialValue.trim();
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
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
  }

  Future<void> _changeReservedOrderShelf(Map<String, dynamic> meta) async {
    if (!_canMarkReservedOrderPlaced()) return;
    final reservationId = (meta['reservation_id'] ?? '').toString().trim();
    final cartItemId = (meta['cart_item_id'] ?? '').toString().trim();
    if (reservationId.isEmpty && cartItemId.isEmpty) return;
    final currentShelf = int.tryParse((meta['shelf_number'] ?? '').toString());
    final nextShelf = await _promptShelfNumber(
      title: 'Смена полки',
      initialValue: currentShelf == null || currentShelf <= 0
          ? ''
          : currentShelf.toString(),
    );
    if (nextShelf == null) return;

    setState(() => _markingPlaced = true);
    try {
      final resp = await authService.dio.post(
        '/api/admin/orders/change_shelf',
        data: {
          if (reservationId.isNotEmpty) 'reservation_id': reservationId,
          if (cartItemId.isNotEmpty) 'cart_item_id': cartItemId,
          'shelf_number': nextShelf,
        },
      );
      final data = resp.data is Map<String, dynamic>
          ? resp.data as Map<String, dynamic>
          : <String, dynamic>{};
      final payload = data['data'] is Map<String, dynamic>
          ? data['data'] as Map<String, dynamic>
          : <String, dynamic>{};
      final userId = (payload['user_id'] ?? meta['user_id'] ?? '')
          .toString()
          .trim();
      if (!mounted) return;
      _patchReservedUserShelfLocally(userId: userId, shelfNumber: nextShelf);
      showAppNotice(
        context,
        'Полка изменена на $nextShelf',
        tone: AppNoticeTone.success,
        duration: const Duration(milliseconds: 1400),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка смены полки: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
    } finally {
      if (mounted) {
        setState(() => _markingPlaced = false);
      } else {
        _markingPlaced = false;
      }
    }
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
    String entrance = '';
    String comment = '';
    double? lat;
    double? lng;
    String? provider;
    String? providerAddressId;
    Map<String, dynamic>? addressStructured;
    bool saveAsDefault = true;
    bool confirmSelection = false;
    if (accepted) {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => DeliveryAddressPickerDialog(
          title: 'Адрес доставки',
          initialAddressText: (meta['address_text'] ?? '').toString(),
          initialEntrance: (meta['entrance'] ?? '').toString(),
          initialComment: (meta['comment'] ?? '').toString(),
          initialPreferredTimeFrom: (meta['preferred_time_from'] ?? '')
              .toString(),
          initialPreferredTimeTo: (meta['preferred_time_to'] ?? '').toString(),
        ),
      );
      if (result == null || (result['address_text'] ?? '').toString().trim().isEmpty) {
        return;
      }
      addressText = (result['address_text'] ?? '').toString().trim();
      preferredTimeFrom =
          (result['preferred_time_from'] ?? '').toString().trim();
      preferredTimeTo = (result['preferred_time_to'] ?? '').toString().trim();
      entrance = (result['entrance'] ?? '').toString().trim();
      comment = (result['comment'] ?? '').toString().trim();
      lat = (result['lat'] is num) ? (result['lat'] as num).toDouble() : null;
      lng = (result['lng'] is num) ? (result['lng'] as num).toDouble() : null;
      provider = (result['provider'] ?? '').toString().trim().isEmpty
          ? null
          : (result['provider'] ?? '').toString().trim();
      providerAddressId =
          (result['provider_address_id'] ?? '').toString().trim().isEmpty
          ? null
          : (result['provider_address_id'] ?? '').toString().trim();
      addressStructured = result['address_structured'] is Map
          ? Map<String, dynamic>.from(result['address_structured'] as Map)
          : null;
      saveAsDefault = result['save_as_default'] != false;
      confirmSelection = result['confirm_selection'] == true;
    }

    try {
      await authService.dio.post(
        '/api/delivery/offers/$customerId/respond',
        data: {
          'accepted': accepted,
          if (accepted) 'address_text': addressText,
          if (accepted && lat != null) 'lat': lat,
          if (accepted && lng != null) 'lng': lng,
          if (accepted && entrance.isNotEmpty) 'entrance': entrance,
          if (accepted && comment.isNotEmpty) 'comment': comment,
          if (accepted && provider != null) 'provider': provider,
          if (accepted && providerAddressId != null)
            'provider_address_id': providerAddressId,
          if (accepted && addressStructured != null)
            'address_structured': addressStructured,
          if (accepted) 'save_as_default': saveAsDefault,
          if (accepted && confirmSelection) 'confirm_selection': true,
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

  Future<void> _markReservedOrderPlaced(
    Map<String, dynamic> meta, {
    String processingMode = 'standard',
  }) async {
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
    final oversize = processingMode == 'oversize';

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
            'processing_mode': processingMode,
            if (shelfValue.isNotEmpty) 'shelf_number': shelfValue,
            if (manualShelf) 'manual_shelf': true,
          },
        );
      }

      Response<dynamic> resp;
      final requiresManualByRole = _requiresManualShelfOnPlaced();
      if (oversize && _canUseDesktopStickerPrinting) {
        try {
          await _openReservedOrderStickerPrint(meta, oversize: true);
        } catch (printError) {
          if (!mounted) return;
          showAppNotice(
            context,
            'Не удалось открыть печать габарита: $printError',
            tone: AppNoticeTone.error,
            duration: const Duration(seconds: 3),
          );
          return;
        }
      }
      try {
        // Для админского потока не подставляем полку автоматически:
        // первый товар должен быть подтвержден ручным вводом.
        resp = await sendMarkPlaced(
          shelfNumber: oversize
              ? null
              : (requiresManualByRole ? null : knownShelf),
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

        if (_canUseDesktopStickerPrinting) {
          try {
            await _openReservedOrderStickerPrint(meta, oversize: false);
          } catch (printError) {
            if (!mounted) return;
            showAppNotice(
              context,
              'Не удалось открыть печать клиентской наклейки: $printError',
              tone: AppNoticeTone.error,
              duration: const Duration(seconds: 3),
            );
            return;
          }
        }

        final manualShelf = await _promptShelfNumber();
        if (manualShelf == null) return;
        resp = await sendMarkPlaced(
          shelfNumber: manualShelf,
          manualShelf: true,
        );
      }
      if ((resp.statusCode == 200 || resp.statusCode == 201) && mounted) {
        final data = resp.data is Map<String, dynamic>
            ? resp.data as Map<String, dynamic>
            : <String, dynamic>{};
        final payload = data['data'] is Map<String, dynamic>
            ? data['data'] as Map<String, dynamic>
            : <String, dynamic>{};
        final resolvedMode = (payload['processing_mode'] ?? processingMode)
            .toString()
            .trim();
        _patchReservedOrderMessageLocally(
          reservationId: reservationId,
          cartItemId: cartItemId,
          patch: {
            'placed': true,
            'processing_mode': resolvedMode,
            'is_oversize': resolvedMode == 'oversize',
            'shelf_number': payload['shelf_number'],
            'processed_by_name':
                (payload['processed_by_name'] ?? '').toString().trim(),
          },
        );
        setState(() {
          if (cartItemId != null && cartItemId.isNotEmpty) {
            _placedCartItemIds.add(cartItemId);
          }
        });
        showAppNotice(
          context,
          oversize
              ? 'Габарит отмечен как обработанный'
              : 'Товар отмечен как обработанный',
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

  double? _positiveMediaDimension(dynamic raw) {
    if (raw is num) {
      final value = raw.toDouble();
      if (value.isFinite && value > 0) return value;
      return null;
    }
    final parsed = double.tryParse((raw ?? '').toString().trim());
    if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
    return parsed;
  }

  void _scheduleServerSearch() {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 280), () {
      unawaited(_performServerSearch());
    });
  }

  Future<void> _performServerSearch() async {
    final query = _searchQuery.trim();
    if (query.isEmpty) return;
    if (mounted) {
      setState(() {
        _serverSearchLoading = true;
      });
    } else {
      _serverSearchLoading = true;
    }
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/search',
        queryParameters: {'q': query},
      );
      final data = resp.data;
      final results =
          (data is Map && data['ok'] == true && data['data'] is List)
          ? (List<Map<String, dynamic>>.from(data['data'])
            ..sort(_compareByCreatedAt))
          : const <Map<String, dynamic>>[];
      if (_searchQuery.trim() != query) return;
      if (!mounted) {
        _serverSearchMessages = results;
        _serverSearchLoaded = true;
        _serverSearchLoading = false;
        _recomputeSearchResults(keepCurrent: false);
        return;
      }
      setState(() {
        _serverSearchMessages = results;
        _serverSearchLoaded = true;
        _serverSearchLoading = false;
      });
      _recomputeSearchResults(keepCurrent: false);
    } catch (_) {
      if (_searchQuery.trim() != query) return;
      if (!mounted) {
        _serverSearchMessages = const [];
        _serverSearchLoaded = true;
        _serverSearchLoading = false;
        _recomputeSearchResults(keepCurrent: false);
        return;
      }
      setState(() {
        _serverSearchMessages = const [];
        _serverSearchLoaded = true;
        _serverSearchLoading = false;
      });
      _recomputeSearchResults(keepCurrent: false);
    }
  }

  bool _messageMatchesSearch(Map<String, dynamic> message, String query) {
    if (query.isEmpty) return true;
    final text = (message['text'] ?? '').toString().toLowerCase();
    final meta = _metaMapOf(message['meta']);
    return messengerMatchesReservedSearch(
      query: query,
      reservedContext: _isReservedOrdersChat() || _isReservedOrder(message),
      text: text,
      title: (meta['title'] ?? '').toString(),
      description: (meta['description'] ?? '').toString(),
      clientName: (meta['client_name'] ?? '').toString(),
      productCode: _reservedProductCodeOf(message) ?? '',
      clientPhone: (meta['client_phone'] ?? '').toString(),
    );
  }

  List<Map<String, dynamic>> _visibleMessages() {
    return _messagesMatchingCurrentSearch()
      .where((message) => _matchesReservedQuickFilter(message))
      .toList()
      ..sort(_compareByCreatedAt);
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
    _stickToBottom = false;
    _clearBottomSettle();
    final targetContext = await _resolveMessageContextWithScroll(messageId);
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 240),
      alignment: 0.18,
      curve: Curves.easeOutCubic,
    );
    _handleScroll();
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
    if (_isReservedOrdersChat()) {
      final sorted = [...messages]..sort(_compareReservedTimelineMessages);
      final items = <Map<String, dynamic>>[];
      final unreadDividerMessageId = messengerShouldShowUnreadDivider(
            searchQuery: _searchQuery,
            firstUnreadMessageId: _firstUnreadMessageId,
          )
          ? (_firstUnreadMessageId ?? '').trim()
          : '';
      final groupCounts = <String, int>{};
      for (final message in sorted) {
        groupCounts.update(
          _reservedSectionKeyOf(message),
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }

      String? previousDate;
      String? previousGroup;
      var insertedUnreadDivider = false;
      for (final message in sorted) {
        final messageId = _messageIdOf(message);
        if (!insertedUnreadDivider &&
            unreadDividerMessageId.isNotEmpty &&
            messageId == unreadDividerMessageId) {
          items.add({
            'type': 'unread_divider',
            'unread_count': _unreadCount,
          });
          insertedUnreadDivider = true;
        }

        final dateLabel = _reservedDateLabelOf(message);
        if (dateLabel != previousDate) {
          items.add({'type': 'reserved_date_section', 'label': dateLabel});
          previousDate = dateLabel;
          previousGroup = null;
        }

        final groupKey = _reservedSectionKeyOf(message);
        if (groupKey != previousGroup) {
          items.add({
            'type': 'reserved_group_header',
            'label': _reservedClientNameOf(message),
            'client_phone': _reservedClientPhoneOf(message),
            'shelf_label': _reservedShelfLabelOf(message),
            'count': groupCounts[groupKey] ?? 1,
          });
          previousGroup = groupKey;
        }

        items.add({'type': 'message', 'data': message});
      }
      return items;
    }

    final items = <Map<String, dynamic>>[];
    String? prevDate;
    final unreadDividerMessageId = messengerShouldShowUnreadDivider(
          searchQuery: _searchQuery,
          firstUnreadMessageId: _firstUnreadMessageId,
        )
        ? (_firstUnreadMessageId ?? '').trim()
        : '';
    var insertedUnreadDivider = false;
    for (final message in messages) {
      final messageId = _messageIdOf(message);
      if (!insertedUnreadDivider &&
          unreadDividerMessageId.isNotEmpty &&
          messageId == unreadDividerMessageId) {
        items.add({
          'type': 'unread_divider',
          'unread_count': _unreadCount,
        });
        insertedUnreadDivider = true;
      }
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

  Widget _buildUnreadDivider() {
    final unreadLabel = _unreadCount > 0
        ? 'Непрочитанные • $_unreadCount'
        : 'Непрочитанные';
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              unreadLabel,
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReservedDateSection(String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReservedGroupHeader(
    ThemeData theme, {
    required String shelfLabel,
    required String clientName,
    required String clientPhone,
    required int count,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                shelfLabel,
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              clientName.isEmpty ? 'Клиент' : clientName,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (clientPhone.trim().isNotEmpty)
              Text(
                clientPhone,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                count == 1 ? '1 товар' : '$count шт.',
                style: TextStyle(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
      final descriptionLines = <String>[];
      for (final candidate in lines.skip(1)) {
        final lower = candidate.toLowerCase();
        if (lower.startsWith('id товара:') ||
            lower.startsWith('цена:') ||
            lower.startsWith('количество') ||
            lower.startsWith('нажмите "купить"') ||
            lower.startsWith('нажмите «купить»')) {
          break;
        }
        descriptionLines.add(candidate);
      }
      description = descriptionLines.join('\n').trim();
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

  String? _replyToMessageIdOf(Map<String, dynamic> meta) {
    final value = (meta['reply_to_message_id'] ?? '').toString().trim();
    return value.isEmpty ? null : value;
  }

  String _replyPreviewTextOf(Map<String, dynamic> meta) {
    final value = (meta['reply_preview_text'] ?? '').toString().trim();
    return value;
  }

  String _replyPreviewSenderNameOf(Map<String, dynamic> meta) {
    final value = (meta['reply_preview_sender_name'] ?? '').toString().trim();
    return value;
  }

  String _forwardedSenderNameOf(Map<String, dynamic> meta) {
    return (meta['forwarded_from_sender_name'] ?? '').toString().trim();
  }

  Widget _buildForwardedHeader(ThemeData theme, Map<String, dynamic> meta) {
    final forwardedBy = _forwardedSenderNameOf(meta);
    if (forwardedBy.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            Icons.forward_to_inbox_outlined,
            size: 14,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              messengerForwardedHeaderText(forwardedBy),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyPreviewBubble(
    ThemeData theme,
    Map<String, dynamic> meta, {
    required bool fromMe,
  }) {
    final replyMessageId = _replyToMessageIdOf(meta);
    final previewText = _replyPreviewTextOf(meta);
    final previewSender = _replyPreviewSenderNameOf(meta);
    if (replyMessageId == null && previewText.isEmpty && previewSender.isEmpty) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: replyMessageId == null ? null : () => _jumpToMessageById(replyMessageId),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: fromMe
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              height: 34,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    messengerReplyHeaderText(previewSender),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    previewText.isEmpty ? 'Сообщение' : previewText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fromMe
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (replyMessageId != null)
              Icon(
                Icons.arrow_upward_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  String _deliveryStatusOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final forced = (meta['delivery_status'] ?? '').toString().trim();
    if (forced.isNotEmpty) return forced;
    if (message['read_by_others'] == true) return 'read';
    return 'sent';
  }

  String _editedBadgeText(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    return messengerEditedBadgeText(
      editedByRole: (meta['edited_by_role'] ?? '').toString(),
      editedByName: (meta['edited_by_name'] ?? '').toString(),
      senderName: (message['sender_name'] ?? '').toString(),
    );
  }

  Future<void> _openEditHistory(Map<String, dynamic> message) async {
    final messageId = _messageIdOf(message);
    if (messageId.isEmpty) return;
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages/$messageId/edit-history',
      );
      final data = resp.data;
      final rows = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(data['data'])
          : const <Map<String, dynamic>>[];
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'История правок',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  const Text('История пока пуста')
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 18),
                      itemBuilder: (_, index) {
                        final row = rows[index];
                        final previousText = (row['previous_text'] ?? '')
                            .toString()
                            .trim();
                        final editedByName = (row['edited_by_name'] ?? 'Система')
                            .toString()
                            .trim();
                        final editedAt = formatDateTimeValue(row['edited_at']);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$editedByName • $editedAt',
                              style: Theme.of(ctx).textTheme.labelMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(previousText.isEmpty ? 'Без текста' : previousText),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось открыть историю правок: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Widget _buildDeliveryStatusIcon(
    ThemeData theme,
    String status, {
    required bool fromMe,
  }) {
    if (!fromMe) return const SizedBox.shrink();

    final (icon, color) = switch (status) {
      'uploading' => (
        Icons.cloud_upload_outlined,
        theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.78),
      ),
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

  Widget _buildLocalLifecycleRow(
    ThemeData theme,
    Map<String, dynamic> message,
    Map<String, dynamic> meta,
  ) {
    if (meta['local_only'] != true) return const SizedBox.shrink();
    final status = (meta['delivery_status'] ?? '').toString().trim();
    if (status != 'uploading' && status != 'sending' && status != 'error') {
      return const SizedBox.shrink();
    }

    final retryable = _isRetryableFailedMessage(message);
    final progressRaw = meta['local_upload_progress'];
    final progress = progressRaw is num
        ? progressRaw.toDouble().clamp(0.0, 1.0)
        : double.tryParse('${meta['local_upload_progress'] ?? ''}')
            ?.clamp(0.0, 1.0);
    final progressPercent = progress == null
        ? null
        : (progress * 100).round().clamp(0, 100);
    final label = messengerLocalDeliveryLabel(
      status,
      progress: progressPercent == null ? null : progress,
      retryable: retryable,
    );
    final chipBackground = switch (status) {
      'uploading' || 'sending' => theme.colorScheme.surfaceContainerHigh,
      'error' => theme.colorScheme.errorContainer,
      _ => theme.colorScheme.surfaceContainerHigh,
    };
    final chipForeground = switch (status) {
      'uploading' || 'sending' => theme.colorScheme.onSurfaceVariant,
      'error' => theme.colorScheme.onErrorContainer,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    final chipChild = status == 'uploading' || status == 'sending'
        ? const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.error_outline_rounded, size: 14);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: chipBackground,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme(
                  data: IconThemeData(color: chipForeground, size: 14),
                  child: chipChild,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: chipForeground,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (status == 'error' && retryable)
            TextButton.icon(
              onPressed: () => _retryFailedMessage(message),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Повторить'),
            ),
        ],
      ),
    );
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

  void _clearReplyComposer() {
    if (!mounted) {
      _replyToMessageId = null;
      _replyPreviewText = null;
      _replyPreviewSenderName = null;
      return;
    }
    setState(() {
      _replyToMessageId = null;
      _replyPreviewText = null;
      _replyPreviewSenderName = null;
    });
  }

  bool _canForwardMessage(Map<String, dynamic> message) {
    if (_isReservedOrder(message)) return false;
    final meta = _metaMapOf(message['meta']);
    final kind = (meta['kind'] ?? '').toString().trim().toLowerCase();
    if (kind == 'delivery_offer' || kind == 'delivery_status') return false;
    return !_isHiddenForAll(message);
  }

  String _forwardTextOf(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final attachmentType = _attachmentTypeOf(meta);
    final text = (message['text'] ?? '').toString().trim();
    final caption = _captionTextOf(message, meta).trim();
    switch (attachmentType) {
      case 'image':
        return caption.isNotEmpty ? caption : 'Фото';
      case 'voice':
        return 'Голосовое сообщение';
      case 'video':
        return caption.isNotEmpty ? caption : 'Видеосообщение';
      default:
        return text;
    }
  }

  Future<Map<String, dynamic>?> _pickForwardTargetChat() async {
    try {
      final chats = (await loadChatsCollection())
          .where((chat) {
            final kind = (_chatStateMapOf(chat['settings'])['kind'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
            return kind != 'reserved_orders' &&
                kind != 'delivery' &&
                kind != 'delivery_chat';
          })
          .where((chat) => (chat['id'] ?? '').toString().trim() != widget.chatId)
          .toList()
        ..sort((a, b) {
          final ad = _parseDate(a['updated_at'] ?? a['time']);
          final bd = _parseDate(b['updated_at'] ?? b['time']);
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });
      if (!mounted) return null;
      return showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Переслать в чат',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: chats.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final chat = chats[index];
                      final title = (chat['display_title'] ?? chat['title'] ?? 'Чат')
                          .toString()
                          .trim();
                      final subtitle = (chat['last_message'] ?? '').toString().trim();
                      return ListTile(
                        title: Text(title.isEmpty ? 'Чат' : title),
                        subtitle: subtitle.isEmpty
                            ? null
                            : Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => Navigator.of(ctx).pop(chat),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _forwardMessage(Map<String, dynamic> message) async {
    if (!_canForwardMessage(message)) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Эту карточку пока нельзя пересылать',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final text = _forwardTextOf(message).trim();
    if (text.isEmpty) {
      if (!mounted) return;
      showAppNotice(
        context,
        'В этом сообщении пока нечего пересылать',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    final targetChat = await _pickForwardTargetChat();
    if (!mounted || targetChat == null) return;
    final targetChatId = (targetChat['id'] ?? '').toString().trim();
    if (targetChatId.isEmpty) return;
    try {
      await authService.dio.post(
        '/api/chats/$targetChatId/messages',
        data: {
          'text': text,
          'forwarded_from_message_id': _messageIdOf(message),
          'forwarded_from_chat_id': widget.chatId,
          'forwarded_from_sender_name': _senderNameOf(message),
        },
      );
      if (!mounted) return;
      showAppNotice(
        context,
        'Сообщение переслано',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось переслать: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  void _replyToMessage(Map<String, dynamic> message) {
    final messageId = _messageIdOf(message);
    if (messageId.isEmpty) return;
    final text = _captionTextOf(message, _metaMapOf(message['meta']));
    final snippet = text.trim().replaceAll('\n', ' ');
    final bounded = snippet.length > 120
        ? '${snippet.substring(0, 120)}…'
        : snippet;
    final preview = bounded.isEmpty ? 'Сообщение' : bounded;
    final sender = _senderNameOf(message);
    setState(() {
      _replyToMessageId = messageId;
      _replyPreviewText = preview;
      _replyPreviewSenderName = sender;
    });
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
          await _openImagePreviewForMessage(message, imageUrl);
        }
      } else if (action == 'reply') {
        _replyToMessage(message);
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
        await _forwardMessage(message);
      } else if (action == 'select') {
        if (!mounted) return;
        showAppNotice(
          context,
          'Режим выбора сообщений появится в следующем обновлении',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
      } else if (action.startsWith('react:') && canReact) {
        final payload = action.substring('react:'.length).trim();
        if (payload == 'more') {
          final picked = await _openFullReactionPicker();
          final messageId = message['id']?.toString() ?? '';
          if (messageId.isNotEmpty && (picked ?? '').trim().isNotEmpty) {
            await _toggleMessageReaction(messageId, picked!.trim());
          }
        } else {
          final messageId = message['id']?.toString() ?? '';
          if (messageId.isNotEmpty && payload.isNotEmpty) {
            await _toggleMessageReaction(messageId, payload);
          }
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
                      }).toList()
                        ..add(
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () =>
                                  Navigator.of(ctx).pop('react:more'),
                              child: Ink(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.colorScheme.surface,
                                ),
                                child: Icon(
                                  Icons.add_reaction_outlined,
                                  size: 24,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
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
    final isPlaced = _reservedIsPlaced(message);
    final isOversizePlaced = _reservedIsOversize(message);
    final shelf = isOversizePlaced
        ? 'Габарит'
        : (metaMap['shelf_number']?.toString() ?? 'не назначена');
    final reservedDescription = metaMap['description']?.toString().trim() ?? '';
    final clientName = metaMap['client_name']?.toString() ?? '—';
    final clientPhone = _formatDisplayPhone(
      metaMap['client_phone']?.toString() ?? '',
    );
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
    final offerPhone = _formatDisplayPhone(
      (metaMap['customer_phone'] ?? '').toString().trim(),
      fallback: '—',
    );
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
    final reactionKind = (metaMap['kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final canReact =
        hasMessageId &&
        !isDeleted &&
        !isReservedOrder &&
        reactionKind != 'delivery_offer' &&
        reactionKind != 'delivery_status';
    final media = MediaQuery.of(context);
    final maxBubbleWidth = media.size.width * 0.72;
    final isCompactMedia = media.size.width < 680;
    final defaultImageWidth = min(
      maxBubbleWidth,
      isCompactMedia
          ? media.size.width * 0.72
          : (media.size.width < 1180 ? 360.0 : 420.0),
    ).toDouble();
    final defaultImageMaxHeight = min(
      isCompactMedia ? media.size.height * 0.36 : media.size.height * 0.46,
      440.0,
    ).clamp(220.0, 440.0);
    final showChatIdentity = !hasBuy && !isReservedOrder;
    final timeLabel = _formatMessageTime(message['created_at']);
    final deliveryStatus = fromMe && showChatIdentity
        ? _deliveryStatusOf(message)
        : '';

    final edited = metaMap['edited'] == true;
    Widget buildMessageImage({double? width}) {
      if (imageUrl == null) return const SizedBox.shrink();
      final cachedSize = cachedChatMessageImageSize(imageUrl);
      final wantsFullWidth = width == double.infinity;
      final resolvedWidth = wantsFullWidth
          ? maxBubbleWidth
          : (width ?? defaultImageWidth);
      final reservedHeight = min(
        defaultImageMaxHeight,
        max(220.0, resolvedWidth * (isCompactMedia ? 0.84 : 0.72)),
      );
      return ChatMessageImage(
        imageUrl: imageUrl,
        preferredWidth: resolvedWidth,
        maxBubbleWidth: maxBubbleWidth,
        maxHeight: reservedHeight,
        expandToMaxWidth: wantsFullWidth,
        borderRadius: isCompactMedia ? 16 : 18,
        knownWidth:
            _positiveMediaDimension(metaMap['image_width']) ??
            cachedSize?.width,
        knownHeight:
            _positiveMediaDimension(metaMap['image_height']) ??
            cachedSize?.height,
        onTap: () => _openImagePreviewForMessage(message, imageUrl),
        onFramePainted: _onMediaFramePainted,
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
    final showLocalLifecycle = metaMap['local_only'] == true;

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
            if (_forwardedSenderNameOf(metaMap).isNotEmpty)
              _buildForwardedHeader(theme, metaMap),
            if (_replyToMessageIdOf(metaMap) != null ||
                _replyPreviewTextOf(metaMap).isNotEmpty ||
                _replyPreviewSenderNameOf(metaMap).isNotEmpty)
              _buildReplyPreviewBubble(theme, metaMap, fromMe: fromMe),
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
                _buildHighlightedText(
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: Text('Телефон: $clientPhone')),
                  IconButton(
                    tooltip: 'Скопировать номер',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: clientPhone.trim().isEmpty || clientPhone == '—'
                        ? null
                        : () => _copyText(clientPhone),
                  ),
                ],
              ),
              Text(
                'Статус: ${isPlaced ? (isOversizePlaced ? 'Обработано • Габарит' : 'Обработано') : 'Ожидание обработки'}',
              ),
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
                  if (isOversizePlaced)
                    _catalogMetaBadge(theme, 'Режим', 'Габарит'),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 190,
                    child: ElevatedButton.icon(
                      icon: Icon(
                        isPlaced
                            ? Icons.print_outlined
                            : Icons.inventory_2_outlined,
                      ),
                      onPressed: (!_canMarkReservedOrderPlaced() || _markingPlaced)
                          ? null
                          : isPlaced
                          ? (_canUseDesktopStickerPrinting
                                ? () => _openReservedOrderStickerPrint(
                                    metaMap,
                                    oversize: isOversizePlaced,
                                  )
                                : null)
                          : () => _markReservedOrderPlaced(
                              metaMap,
                              processingMode: 'standard',
                            ),
                      label: Text(
                        isPlaced
                            ? 'Дай стикер'
                            : (_markingPlaced ? 'Сохранение...' : 'Положил'),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 190,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.all_inbox_outlined),
                      onPressed:
                          (!_canMarkReservedOrderPlaced() ||
                              isPlaced ||
                              _markingPlaced)
                          ? null
                          : () => _markReservedOrderPlaced(
                              metaMap,
                              processingMode: 'oversize',
                            ),
                      label: Text(
                        isPlaced && isOversizePlaced
                            ? 'Габарит'
                            : (_markingPlaced ? 'Сохранение...' : 'Габарит'),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 190,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.swap_horiz_outlined),
                      onPressed:
                          (!_canMarkReservedOrderPlaced() ||
                              _markingPlaced ||
                              isOversizePlaced)
                          ? null
                          : () => _changeReservedOrderShelf(metaMap),
                      label: const Text('Смена полки'),
                    ),
                  ),
                ],
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
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _openEditHistory(message),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 2,
                      ),
                      child: Text(
                        _editedBadgeText(message),
                        style: TextStyle(
                          color: fromMe
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
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
              if (showLocalLifecycle)
                _buildLocalLifecycleRow(theme, message, metaMap),
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
    final theme = Theme.of(context);
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
    final media = MediaQuery.of(context);
    final scrollButtonBottom =
        media.viewInsets.bottom +
        media.viewPadding.bottom +
        (_searchMode ? 18 : 92);

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
              if (_isSupportTicketChat()) _buildSupportTicketBanner(),
              if (_isReservedOrdersChat()) _buildReservedQuickFilterBar(),
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
              if (_activePin != null) _buildActivePinPreview(theme),
              Expanded(
                child: _loading
                    ? const _ChatTimelineLoadingView()
                    : timeline.isEmpty
                    ? Center(
                        child: _searchQuery.isNotEmpty && _serverSearchLoading
                            ? const CircularProgressIndicator()
                            : Text(
                                _searchQuery.isEmpty
                                    ? 'Нет сообщений'
                                    : 'Ничего не найдено',
                              ),
                      )
                    : Stack(
                        children: [
                          SizedBox.expand(
                            key: _messagesViewportKey,
                            child: IgnorePointer(
                              ignoring: !_initialViewportReady,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 120),
                                opacity: _initialViewportReady ? 1 : 0,
                                child: ListView.builder(
                                  controller: _scrollController,
                                  physics: kIsWeb
                                      ? const ClampingScrollPhysics()
                                      : const BouncingScrollPhysics(
                                          parent: AlwaysScrollableScrollPhysics(),
                                        ),
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  cacheExtent:
                                      media.size.height * (kIsWeb ? 3.6 : 2.2),
                                  itemCount: timeline.length,
                                  itemBuilder: (context, i) {
                                    final row = timeline[i];
                                    if (row['type'] == 'date') {
                                      return _buildDateDivider(
                                        (row['label'] ?? 'Без даты').toString(),
                                      );
                                    }
                                    if (row['type'] == 'reserved_date_section') {
                                      return _buildReservedDateSection(
                                        (row['label'] ?? 'Без даты').toString(),
                                      );
                                    }
                                    if (row['type'] == 'reserved_group_header') {
                                      return _buildReservedGroupHeader(
                                        theme,
                                        shelfLabel: (row['shelf_label'] ?? '')
                                            .toString(),
                                        clientName: (row['label'] ?? '')
                                            .toString(),
                                        clientPhone: (row['client_phone'] ?? '')
                                            .toString(),
                                        count:
                                            int.tryParse('${row['count'] ?? 1}') ??
                                            1,
                                      );
                                    }
                                    if (row['type'] == 'unread_divider') {
                                      return _buildUnreadDivider();
                                    }
                                    final message = Map<String, dynamic>.from(
                                      row['data'] as Map,
                                    );
                                    return _buildMessageItem(message);
                                  },
                                ),
                              ),
                            ),
                          ),
                          if (_loadingOlderMessages)
                            const Positioned(
                              top: 8,
                              left: 16,
                              right: 16,
                              child: LinearProgressIndicator(minHeight: 3),
                            ),
                          if (!_initialViewportReady)
                            const Positioned.fill(
                              child: PhoenixLoadingView(
                                title: 'Открываем чат',
                                subtitle:
                                    'Восстанавливаем последнее место в переписке',
                              ),
                            ),
                        ],
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
                if ((_replyToMessageId ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 4,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  (_replyPreviewSenderName ?? '').trim().isEmpty
                                      ? 'Ответ'
                                      : (_replyPreviewSenderName ?? '').trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  (_replyPreviewText ?? '').trim().isEmpty
                                      ? 'Сообщение'
                                      : (_replyPreviewText ?? '').trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Отменить ответ',
                            onPressed: _clearReplyComposer,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
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
          Positioned(
            right: 14,
            bottom: scrollButtonBottom,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if ((_firstUnreadMessageId ?? '').trim().isNotEmpty &&
                    _unreadCount > 0 &&
                    !_searchMode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FloatingActionButton.small(
                      heroTag: 'chat-jump-first-unread',
                      tooltip: 'К первому непрочитанному',
                      onPressed: _jumpToFirstUnread,
                      child: const Icon(Icons.mark_chat_unread_outlined),
                    ),
                  ),
                IgnorePointer(
                  ignoring: !_showScrollToBottomButton,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    offset: _showScrollToBottomButton
                        ? Offset.zero
                        : const Offset(0, 0.6),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _showScrollToBottomButton ? 1 : 0,
                      child: FloatingActionButton.small(
                        heroTag: 'chat-scroll-bottom',
                        tooltip: 'В конец чата',
                        onPressed: () => _scrollToBottom(animated: true),
                        child: const Icon(Icons.keyboard_double_arrow_down_rounded),
                      ),
                    ),
                  ),
                ),
              ],
            ),
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

class _ChatTimelineLoadingView extends StatelessWidget {
  const _ChatTimelineLoadingView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      children: const [
        _ChatSkeletonDateDivider(),
        SizedBox(height: 10),
        _ChatSkeletonBubble(
          alignEnd: false,
          widthFactor: 0.62,
          height: 92,
          showThumb: true,
        ),
        SizedBox(height: 12),
        _ChatSkeletonBubble(
          alignEnd: true,
          widthFactor: 0.54,
          height: 64,
        ),
        SizedBox(height: 18),
        _ChatSkeletonDateDivider(),
        SizedBox(height: 10),
        _ChatSkeletonBubble(
          alignEnd: false,
          widthFactor: 0.78,
          height: 72,
        ),
        SizedBox(height: 12),
        _ChatSkeletonBubble(
          alignEnd: true,
          widthFactor: 0.66,
          height: 118,
          showThumb: true,
        ),
      ],
    );
  }
}

class _ChatSkeletonDateDivider extends StatelessWidget {
  const _ChatSkeletonDateDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        width: 108,
        height: 26,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _ChatSkeletonBubble extends StatelessWidget {
  const _ChatSkeletonBubble({
    required this.alignEnd,
    required this.widthFactor,
    required this.height,
    this.showThumb = false,
  });

  final bool alignEnd;
  final double widthFactor;
  final double height;
  final bool showThumb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor = alignEnd
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.72)
        : theme.colorScheme.surfaceContainerHigh;
    final lineColor = alignEnd
        ? theme.colorScheme.primary.withValues(alpha: 0.12)
        : theme.colorScheme.surfaceContainerHighest;
    final width = MediaQuery.of(context).size.width * widthFactor;
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: width.clamp(220.0, 520.0)),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(alignEnd ? 20 : 8),
            bottomRight: Radius.circular(alignEnd ? 8 : 20),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showThumb) ...[
              Container(
                height: height - 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      lineColor,
                      lineColor.withValues(alpha: 0.66),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            FractionallySizedBox(
              widthFactor: 0.86,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: lineColor,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FractionallySizedBox(
              widthFactor: 0.58,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: lineColor.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 42,
                height: 10,
                decoration: BoxDecoration(
                  color: lineColor.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
