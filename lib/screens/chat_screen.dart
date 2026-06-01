// lib/screens/chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random, max, min;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart' as cam;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart' as vp;

import '../assets/phoenix_assets.dart';
import '../main.dart';
import '../services/chat_capture_capability_service.dart';
import '../services/chat_outbox_service.dart';
import '../services/chat_recent_gallery_service.dart';
import '../services/messenger_preferences_service.dart';
import '../services/monitoring_service.dart';
import '../services/native_video_note_capture_service.dart';
import '../services/sticker_print_service.dart';
import '../services/web_image_cache_service.dart';
import '../services/web_media_capture_permission_service.dart';
import '../services/web_video_note_capture_service.dart';
import '../src/utils/chat_api.dart';
import '../src/utils/chat_image_preprocessor.dart';
import '../src/utils/media_url.dart';
import '../src/utils/messenger_ui_helpers.dart';
import '../utils/date_time_utils.dart';
import '../utils/phone_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/adaptive_network_image.dart';
import '../widgets/chat_media_viewer.dart';
import '../widgets/chat_message_image.dart';
import '../widgets/delivery_address_picker_dialog.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/app_status_badge.dart';
import '../widgets/app_surface_card.dart';
import '../widgets/inline_video_note_orb.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_ambient_background.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/phoenix_micro_interactions.dart';
import '../widgets/phoenix_visual_effects.dart';
import '../widgets/submit_on_enter.dart';

class _ChatUploadFile {
  const _ChatUploadFile({
    required this.filename,
    this.path,
    this.bytes,
    this.mimeType,
    this.fileSize,
    this.qualityMode,
    this.width,
    this.height,
    this.preprocessTag,
  });

  final String filename;
  final String? path;
  final Uint8List? bytes;
  final String? mimeType;
  final int? fileSize;
  final String? qualityMode;
  final int? width;
  final int? height;
  final String? preprocessTag;
}

enum _ComposerMediaMode { voice, camera }

enum _RecordingActionVisualPhase { idle, dragging, lockedHover, cancellingDust }

enum _ImageSendMode { standard, hd, file }

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

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
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
  static const Duration _composerRecordHoldDelay = Duration(seconds: 1);
  static const Duration _recordingCancelDustDuration = Duration(
    milliseconds: 560,
  );
  static const int _typingActiveTtlMs = 10000;
  static const Duration _typingKeepAliveInterval = Duration(milliseconds: 3200);
  static const Duration _typingEmitThrottle = Duration(milliseconds: 2200);
  static const Duration _directMessageFallbackSyncInterval = Duration(
    seconds: 7,
  );
  static const Duration _channelPublicationLiveSyncFastInterval = Duration(
    milliseconds: 1400,
  );
  static const Duration _channelPublicationLiveSyncSlowInterval = Duration(
    seconds: 12,
  );
  static const Duration _channelPublicationLiveSyncWarmWindow = Duration(
    minutes: 6,
  );
  static const bool _channelLiveDebugLogs = bool.fromEnvironment(
    'FENIX_CHANNEL_LIVE_LOGS',
    defaultValue: false,
  );
  static const Duration _remoteActivityFallbackPollInterval = Duration(
    seconds: 8,
  );
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-'
    r'[0-9a-fA-F]{4}-'
    r'[1-5][0-9a-fA-F]{3}-'
    r'[89abAB][0-9a-fA-F]{3}-'
    r'[0-9a-fA-F]{12}$',
  );

  final _controller = TextEditingController();
  final _searchController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final GlobalKey _messagesViewportKey = GlobalKey();
  final ImagePicker _imagePicker = ImagePicker();
  late final AnimationController _recordingHoverController;
  AudioRecorder? _voiceRecorderInstance;
  AudioRecorder get _voiceRecorder =>
      _voiceRecorderInstance ??= AudioRecorder();
  final AudioPlayer _voicePlayer = AudioPlayer();
  final Connectivity _connectivity = Connectivity();
  late final ChatCaptureProfile _captureProfile;

  List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _incomingQueue = [];
  final Set<String> _appearingMessageIds = {};
  final Map<String, DateTime> _remoteTypingExpiresAt = {};
  final Map<String, Timer> _remoteTypingTimers = {};

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
  bool _nativeVideoNoteRecording = false;
  bool _webVideoNoteRecording = false;
  bool _videoRecordingLocked = false;
  _ComposerMediaMode _composerMediaMode = _ComposerMediaMode.voice;
  bool _composerMediaPressActive = false;
  bool _composerHoldActionTriggered = false;
  bool _voiceStartInProgress = false;
  bool _videoStartInProgress = false;
  bool _pinLoading = false;
  bool _hasDraftText = false;
  bool _offlineSyncBusy = false;
  bool _persistentOutboxFlushInFlight = false;
  bool _persistentOutboxFlushPending = false;
  bool _persistentOutboxPendingIncludeErrored = false;
  bool _showScrollToBottomButton = false;
  bool _initialViewportApplied = false;
  bool _initialViewportReady = false;
  bool _loadingOlderMessages = false;
  bool _loadingNewerMessages = false;
  bool _draftSyncInFlight = false;
  bool _hasMoreBefore = false;
  bool _stickToBottom = true;
  bool _manualBottomLockSuppressed = false;
  int _offlineQueuedCount = 0;
  int _unreadCount = 0;

  String _searchQuery = '';
  String? _stickyDateLabel;
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
  Uint8List? _nativeVideoPreviewFrame;
  Object? _lastVideoCameraError;
  DateTime? _attachmentCameraVideoStartedAt;
  bool _attachmentNativeVideoRecording = false;
  String? _activeVideoNoteMessageId;
  bool _inlineVideoNoteInitializing = false;
  final Map<String, Duration> _videoNoteDurationCache = <String, Duration>{};

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
  Timer? _remoteActivityTimer;
  Timer? _remoteActivityPollTimer;
  Timer? _localTypingIdleTimer;
  Timer? _directMessageLiveSyncTimer;
  Timer? _channelPublicationLiveSyncTimer;
  Timer? _channelPublicationImmediateSyncTimer;
  Timer? _persistentOutboxRetryTimer;
  Timer? _realtimeChatRefreshTimer;
  bool _readFlushOnExitInFlight = false;
  bool _readSyncInFlight = false;
  bool _readSyncPending = false;
  bool _directMessageLiveSyncInFlight = false;
  bool _channelPublicationLiveSyncInFlight = false;
  bool _channelPublicationForceLatestFallback = false;
  bool _remoteActivityPollInFlight = false;
  DateTime? _channelPublicationLiveSyncWarmUntil;
  int _bottomSettlePassesRemaining = 0;
  VoidCallback? _bottomSettleOnComplete;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<Duration>? _voicePositionSub;
  StreamSubscription<Duration>? _voiceDurationSub;
  StreamSubscription<PlayerState>? _voiceStateSub;
  StreamSubscription<void>? _voiceCompleteSub;
  StreamSubscription<Uint8List>? _nativeVideoPreviewSub;
  DateTime? _voiceRecordingStartedAt;
  DateTime? _videoRecordingStartedAt;
  Offset? _composerPressStartGlobal;
  double _recordingDragDx = 0;
  double _recordingDragDy = 0;
  double _videoRecordingDragDx = 0;
  double _videoRecordingDragDy = 0;
  _RecordingActionVisualPhase _voiceRecordingVisualPhase =
      _RecordingActionVisualPhase.idle;
  _RecordingActionVisualPhase _videoRecordingVisualPhase =
      _RecordingActionVisualPhase.idle;
  Timer? _voiceRecordingCancelVisualTimer;
  Timer? _videoRecordingCancelVisualTimer;
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
  late Map<String, dynamic> _chatSettings;
  late String _chatTitle;
  Map<String, dynamic>? _contactCard;
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
  bool _jumpedToFirstUnread = false;
  String? _lastSeenMessageId;
  String? _oldestLoadedMessageId;
  String? _oldestLoadedCreatedAt;
  String? _newestLoadedMessageId;
  String? _newestLoadedCreatedAt;
  String? _replyToMessageId;
  String? _replyPreviewText;
  String? _replyPreviewSenderName;
  bool _applyingServerDraft = false;
  bool _draftRestoredHintVisible = false;
  bool _scrollRestoredHintVisible = false;
  String _remoteActivityLabel = '';
  String? _highlightedSearchMessageId;
  DateTime? _lastTypingEmitAt;
  bool _localTypingActiveSent = false;
  MessengerPreferences _messengerPrefs = MessengerPreferences.defaults;
  List<ConnectivityResult> _connectivityResults = const <ConnectivityResult>[];
  final Set<String> _manualMediaLoads = <String>{};
  Timer? _draftRestoredHintTimer;
  Timer? _scrollRestoredHintTimer;
  Timer? _searchHitHighlightTimer;

  static const List<String> _quickReactions = <String>[
    '👍',
    '🔥',
    '✅',
    '❤️',
    '😂',
    '🙏',
    '🎉',
    '🤝',
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
    '📦',
    '🚚',
    '📍',
    '🧾',
    '💬',
    '📞',
    '💸',
    '📈',
    '🔒',
    '⚠️',
    '⏳',
    '🛠️',
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
    _recordingHoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat(reverse: true);
    _captureProfile = ChatCaptureCapabilityService.current;
    _chatSettings = widget.chatSettings == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(widget.chatSettings!);
    _chatTitle = widget.chatTitle;
    activeChatIdNotifier.value = widget.chatId;
    _channelLiveLog('initState');
    unawaited(_initializeChat());
    _loadPinnedMessage();
    _joinRoom();
    _startChannelPublicationLiveSync(resetWindow: true);
    unawaited(_refreshOfflineQueueCount());
    unawaited(_loadMessengerPreferences());
    unawaited(_refreshConnectivityState());
    _offlineQueueRefreshTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(_refreshOfflineQueueCount()),
    );
    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      if (!mounted) {
        _connectivityResults = List<ConnectivityResult>.from(results);
        return;
      }
      setState(() {
        _connectivityResults = List<ConnectivityResult>.from(results);
      });
    });

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
      if (nextHasDraft != _hasDraftText) {
        _hasDraftText = nextHasDraft;
      }
      if (!_applyingServerDraft) {
        if (nextHasDraft) {
          _maybeEmitTypingActivity();
        } else {
          _maybeEmitTypingInactive();
        }
      }
      _scheduleDraftSync();
    });

    _inputFocusNode.addListener(() {
      if (_inputFocusNode.hasFocus) {
        _scrollToBottom(animated: true);
      } else if (_controller.text.trim().isEmpty) {
        _maybeEmitTypingInactive();
      } else {
        _maybeEmitTypingActivity();
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
      if ((type == 'chat:message' || type == 'chat:message:global') &&
          data is Map) {
        final msg = data['message'] ?? data;
        final chatId = data['chatId'] ?? msg['chat_id'] ?? msg['chatId'];
        _channelLiveLog('socket event chat:message received', {
          'event_chat_id': chatId?.toString(),
          'matches_current':
              chatId != null && chatId.toString() == widget.chatId,
          'action': (data['action'] ?? data['type'] ?? '').toString(),
          'message_id': msg is Map ? (msg['id'] ?? '').toString() : '',
          'queue_id': (data['queue_id'] ?? data['queueId'] ?? '').toString(),
          'event_id': (data['event_id'] ?? data['eventId'] ?? '').toString(),
        });
        if (chatId != null && chatId.toString() == widget.chatId) {
          final message = Map<String, dynamic>.from(msg);
          final action = (data['action'] ?? data['type'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          _clearRemoteTypingUser(
            (message['sender_id'] ?? message['senderId'] ?? '').toString(),
          );
          _enqueueIncomingMessage(message, action: action);
          if (_isPublicationLiveSyncChannel()) {
            _startChannelPublicationLiveSync(resetWindow: true);
            _scheduleChannelPublicationImmediateSync(forceLatest: true);
          }
        }
        return;
      }
      if (type == 'chat:updated' && data is Map) {
        final chatId = (data['chatId'] ?? data['chat_id'] ?? '').toString();
        final chat = data['chat'];
        _channelLiveLog('socket event chat:updated received', {
          'event_chat_id': chatId,
          'matches_current': chatId == widget.chatId,
          'action': (data['action'] ?? '').toString(),
          'event_id': (data['event_id'] ?? data['eventId'] ?? '').toString(),
        });
        if (chatId == widget.chatId) {
          if (chat is Map) {
            _applyIncomingChatSnapshot(Map<String, dynamic>.from(chat));
          }
          _scheduleRealtimeChatRefresh(reason: 'chat_updated');
          if (_isPublicationLiveSyncChannel()) {
            _scheduleChannelPublicationImmediateSync(forceLatest: true);
          }
          _startChannelPublicationLiveSync(resetWindow: true);
        }
        return;
      }
      if (type == 'channel:media:updated' && data is Map) {
        final chatId = (data['chatId'] ?? data['chat_id'] ?? '').toString();
        final channelId = (data['channel_id'] ?? data['channelId'] ?? '')
            .toString();
        _channelLiveLog('socket event channel:media:updated received', {
          'event_chat_id': chatId,
          'event_channel_id': channelId,
          'matches_current':
              chatId == widget.chatId || channelId == widget.chatId,
          'action': (data['action'] ?? '').toString(),
          'message_id': (data['message_id'] ?? data['messageId'] ?? '')
              .toString(),
          'queue_id': (data['queue_id'] ?? data['queueId'] ?? '').toString(),
          'event_id': (data['event_id'] ?? data['eventId'] ?? '').toString(),
        });
        if (chatId == widget.chatId || channelId == widget.chatId) {
          final message = data['message'];
          if (message is Map) {
            final action = (data['action'] ?? 'message_published')
                .toString()
                .trim()
                .toLowerCase();
            _enqueueIncomingMessage(
              Map<String, dynamic>.from(message),
              action: action,
            );
          }
          _scheduleRealtimeChatRefresh(reason: 'channel_media_updated');
          if (_isPublicationLiveSyncChannel()) {
            _scheduleChannelPublicationImmediateSync(forceLatest: true);
          }
          _startChannelPublicationLiveSync(resetWindow: true);
        }
        return;
      }
      if (type == 'catalog:queue:updated' && data is Map) {
        final chatId =
            (data['chatId'] ??
                    data['chat_id'] ??
                    data['channel_id'] ??
                    data['channelId'] ??
                    '')
                .toString()
                .trim();
        final action = (data['action'] ?? '').toString().trim().toLowerCase();
        final affectsCurrentChannel =
            chatId == widget.chatId ||
            (chatId.isEmpty &&
                _isPublicationLiveSyncChannel() &&
                action.contains('publish'));
        _channelLiveLog('socket event catalog:queue:updated received', {
          'event_chat_or_channel_id': chatId,
          'action': action,
          'affects_current': affectsCurrentChannel,
          'queue_ids': data['queue_ids'],
          'batch_ids': data['batch_ids'],
          'event_id': (data['event_id'] ?? data['eventId'] ?? '').toString(),
        });
        if (affectsCurrentChannel && _isPublicationLiveSyncChannel()) {
          _startChannelPublicationLiveSync(resetWindow: true);
          _scheduleChannelPublicationImmediateSync(forceLatest: true);
        }
        return;
      }
      if (type == 'chat:direct_request_created' && data is Map) {
        final chatId = (data['chat_id'] ?? data['chatId'] ?? '').toString();
        if (chatId == widget.chatId) {
          final chat = data['chat'];
          if (chat is Map) {
            _applyIncomingChatSnapshot(Map<String, dynamic>.from(chat));
          }
          unawaited(_loadContactCard());
        }
        return;
      }
      if (type == 'chat:direct_request_updated' && data is Map) {
        final chatId = (data['chat_id'] ?? data['chatId'] ?? '').toString();
        if (chatId == widget.chatId) {
          unawaited(_loadContactCard());
          if (mounted) {
            setState(() {
              _chatSettings = {
                ..._effectiveChatSettings(),
                'direct_request_status': (data['status'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase(),
              };
            });
          }
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
        final chatId = (data['chatId'] ?? data['chat_id'] ?? '').toString();
        if (chatId != widget.chatId) return;
        final readerId = (data['readerId'] ?? data['reader_id'] ?? '')
            .toString();
        final currentUserId = authService.currentUser?.id ?? '';
        final isReadByMe = readerId.isNotEmpty && readerId == currentUserId;
        final hasUnreadCount = data.containsKey('unread_count');
        final unreadCount = hasUnreadCount
            ? (int.tryParse('${data['unread_count'] ?? 0}') ?? 0)
            : null;
        final rawMessageIds = data['messageIds'] ?? data['message_ids'];
        final messageIds = (rawMessageIds is List)
            ? rawMessageIds
                  .map((e) => e?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .toSet()
            : <String>{};
        if (messageIds.isNotEmpty) {
          _applyReadState(
            messageIds,
            readByMe: isReadByMe,
            readByOthers: !isReadByMe,
          );
        }
        if (isReadByMe && unreadCount != null) {
          if (mounted) {
            setState(() {
              _unreadCount = unreadCount;
              if (unreadCount <= 0) {
                _firstUnreadMessageId = null;
              }
              _jumpedToFirstUnread = false;
            });
          } else {
            _unreadCount = unreadCount;
            if (unreadCount <= 0) {
              _firstUnreadMessageId = null;
            }
            _jumpedToFirstUnread = false;
          }
        }
        return;
      }
      if (type == 'chat:typing' && data is Map) {
        final chatId = (data['chat_id'] ?? data['chatId'] ?? '').toString();
        final userId = (data['user_id'] ?? data['userId'] ?? '').toString();
        if (chatId == widget.chatId && userId != _myUserId()) {
          final active = _socketBool(data['active'], fallback: true);
          final ttlMs = _socketTtlMs(data['ttl_ms'] ?? data['ttlMs']);
          _applyRemoteTypingEvent(userId, active: active, ttlMs: ttlMs);
          if (active) {
            _setRemoteActivityLabel('Печатает...', ttlMs: ttlMs);
          }
        }
        return;
      }
      if (type == 'chat:recording_voice' && data is Map) {
        final chatId = (data['chat_id'] ?? data['chatId'] ?? '').toString();
        final userId = (data['user_id'] ?? data['userId'] ?? '').toString();
        if (chatId == widget.chatId && userId != _myUserId()) {
          _setRemoteActivityLabel('Записывает голосовое...');
        }
        return;
      }
      if (type == 'chat:recording_video' && data is Map) {
        final chatId = (data['chat_id'] ?? data['chatId'] ?? '').toString();
        final userId = (data['user_id'] ?? data['userId'] ?? '').toString();
        if (chatId == widget.chatId && userId != _myUserId()) {
          _setRemoteActivityLabel('Записывает видеокружок...');
        }
        return;
      }
      if (type == 'socket:connected') {
        unawaited(_joinRoom());
        unawaited(_reconcilePersistentOutbox());
        unawaited(_flushPersistentOutbox());
        unawaited(_syncLatestDirectMessages(forceLatest: true));
        _directMessageLiveSyncTimer?.cancel();
        _directMessageLiveSyncTimer = null;
        _remoteActivityPollTimer?.cancel();
        _remoteActivityPollTimer = null;
        _reconnectReplayTimer?.cancel();
        _reconnectReplayTimer = Timer(const Duration(milliseconds: 220), () {
          unawaited(_replayMissedMessagesAfterReconnect());
        });
        _startChannelPublicationLiveSync(resetWindow: true);
        return;
      }
      if (type == 'socket:disconnected' || type == 'socket:connect_error') {
        _startDirectMessageLiveSync();
        _startRemoteActivityPolling();
        _startChannelPublicationLiveSync(resetWindow: true);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_joinRoom());
      _startChannelPublicationLiveSync(resetWindow: true);
    });
  }

  Map<String, dynamic> _effectiveChatSettings() => _chatSettings;

  bool _isDiscussionsChat() {
    final settings = _effectiveChatSettings();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    return kind == 'discussions' ||
        systemKey == 'discussions' ||
        _chatTitle.toLowerCase().trim() == 'обсуждения';
  }

  bool _canManageDiscussionsChat() {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    return _isDiscussionsChat() && role == 'creator';
  }

  String? _chatAvatarUrl() {
    final settings = _effectiveChatSettings();
    return _resolveImageUrl((settings['avatar_url'] ?? '').toString());
  }

  double _chatAvatarFocus(String key, double fallback) {
    final value = double.tryParse('${_effectiveChatSettings()[key] ?? ''}');
    if (value == null || !value.isFinite) return fallback;
    return value.clamp(-1.0, 1.0).toDouble();
  }

  double _chatAvatarZoom() {
    final value = double.tryParse(
      '${_effectiveChatSettings()['avatar_zoom'] ?? ''}',
    );
    if (value == null || !value.isFinite) return 1.0;
    return value.clamp(1.0, 4.0).toDouble();
  }

  Future<void> _openDiscussionsSettings() async {
    if (!_isDiscussionsChat()) return;
    final updated = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DiscussionChatSettingsSheet(
        chatId: widget.chatId,
        title: _chatTitle,
        settings: _effectiveChatSettings(),
        canManage: _canManageDiscussionsChat(),
      ),
    );
    if (updated == null || !mounted) return;
    _applyIncomingChatSnapshot(updated);
  }

  Widget _buildAppBarTitle(ThemeData theme) {
    final titleColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_chatTitle),
        if (_remoteActivityLabel.isNotEmpty)
          Text(
            _remoteActivityLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );

    if (!_isDiscussionsChat()) return titleColumn;

    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: _openDiscussionsSettings,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppAvatar(
              title: _chatTitle,
              imageUrl: _chatAvatarUrl(),
              focusX: _chatAvatarFocus('avatar_focus_x', 0),
              focusY: _chatAvatarFocus('avatar_focus_y', 0),
              zoom: _chatAvatarZoom(),
              radius: 18,
              fallbackIcon: Icons.forum_outlined,
            ),
            const SizedBox(width: 10),
            Flexible(child: titleColumn),
            if (_canManageDiscussionsChat()) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.settings_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _channelLiveLog(String label, [Map<String, dynamic>? details]) {
    if (!kDebugMode || !_channelLiveDebugLogs) return;
    final payload = <String, dynamic>{
      'chat_id': widget.chatId,
      'title': _chatTitle,
      'type': widget.chatType,
      'is_channel': _isChannelChat(),
      'is_publication_channel': _isPublicationLiveSyncChannel(),
      'messages': _messages.length,
      if (_newestLoadedMessageId != null) 'newest_id': _newestLoadedMessageId,
      if (_newestLoadedCreatedAt != null)
        'newest_created_at': _newestLoadedCreatedAt,
      ...?details,
    };
    String encoded;
    try {
      encoded = jsonEncode(payload);
    } catch (_) {
      encoded = payload.toString();
    }
    debugPrint(
      '[PHX:CHANNEL-LIVE] ${DateTime.now().toIso8601String()} $label $encoded',
      wrapWidth: 1200,
    );
  }

  String _myUserId() => authService.currentUser?.id.trim() ?? '';

  bool get _isRealtimeSocketConnected => socket?.connected == true;

  String _outboxTenantCode() {
    final scoped = authService.creatorTenantScopeCode?.trim() ?? '';
    final fallback = authService.currentUser?.tenantCode?.trim() ?? '';
    final normalized = normalizeChatOutboxTenantCode(
      scoped.isNotEmpty ? scoped : fallback,
    );
    return normalized.isNotEmpty ? normalized : 'global';
  }

  bool _flagFrom(dynamic raw) {
    if (raw is bool) return raw;
    final normalized = '${raw ?? ''}'.trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  String _directRequestStatus() {
    return (_effectiveChatSettings()['direct_request_status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
  }

  bool _directRequestFirstMessageSent() {
    return _flagFrom(
      _effectiveChatSettings()['direct_request_first_message_sent'],
    );
  }

  bool _isPendingDirectRequestForMe() {
    if (_directRequestStatus() != 'pending') return false;
    final pendingFor =
        (_effectiveChatSettings()['direct_request_pending_for'] ?? '')
            .toString()
            .trim();
    return pendingFor.isNotEmpty && pendingFor == _myUserId();
  }

  bool _isPendingDirectRequestFromMe() {
    if (_directRequestStatus() != 'pending') return false;
    final createdBy =
        (_effectiveChatSettings()['direct_request_created_by'] ?? '')
            .toString()
            .trim();
    return createdBy.isNotEmpty && createdBy == _myUserId();
  }

  void _applyIncomingChatSnapshot(Map<String, dynamic> chat) {
    final nextSettings = chat['settings'] is Map
        ? Map<String, dynamic>.from(chat['settings'])
        : _effectiveChatSettings();
    final nextTitle = (chat['display_title'] ?? chat['title'] ?? _chatTitle)
        .toString()
        .trim();
    if (!mounted) {
      _chatSettings = nextSettings;
      if (nextTitle.isNotEmpty) {
        _chatTitle = nextTitle;
      }
      return;
    }
    setState(() {
      _chatSettings = nextSettings;
      if (nextTitle.isNotEmpty) {
        _chatTitle = nextTitle;
      }
    });
    _startRemoteActivityPolling();
    _startDirectMessageLiveSync();
    _startChannelPublicationLiveSync(resetWindow: true);
  }

  void _setRemoteActivityLabel(String value, {int ttlMs = 4500}) {
    _remoteActivityTimer?.cancel();
    if (!mounted) {
      _remoteActivityLabel = value;
      return;
    }
    setState(() => _remoteActivityLabel = value);
    if (value.isEmpty) return;
    _remoteActivityTimer = Timer(Duration(milliseconds: ttlMs), () {
      if (!mounted) return;
      setState(() => _remoteActivityLabel = '');
    });
  }

  bool _socketBool(dynamic raw, {required bool fallback}) {
    if (raw == null) return fallback;
    if (raw is bool) return raw;
    final text = raw.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  int _socketTtlMs(dynamic raw, {int fallback = 4500}) {
    final parsed = raw is num
        ? raw.toInt()
        : int.tryParse((raw ?? '').toString().trim());
    if (parsed == null || parsed <= 0) return fallback;
    return parsed.clamp(800, 12000).toInt();
  }

  List<String> _activeRemoteTypingUserIds() {
    if (_remoteTypingExpiresAt.isEmpty) return const <String>[];
    final now = DateTime.now();
    return _remoteTypingExpiresAt.entries
        .where((entry) => entry.value.isAfter(now))
        .map((entry) => entry.key)
        .where((id) => id.trim().isNotEmpty)
        .toList(growable: false);
  }

  void _clearRemoteTypingUser(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty || !_remoteTypingExpiresAt.containsKey(normalized)) {
      return;
    }
    _remoteTypingTimers.remove(normalized)?.cancel();
    if (!mounted) {
      _remoteTypingExpiresAt.remove(normalized);
      if (_activeRemoteTypingUserIds().isEmpty) {
        _remoteActivityTimer?.cancel();
        _remoteActivityLabel = '';
      }
      return;
    }
    setState(() {
      _remoteTypingExpiresAt.remove(normalized);
      if (_activeRemoteTypingUserIds().isEmpty) {
        _remoteActivityTimer?.cancel();
        _remoteActivityLabel = '';
      }
    });
  }

  void _applyRemoteTypingEvent(
    String userId, {
    required bool active,
    required int ttlMs,
  }) {
    final normalized = userId.trim();
    if (normalized.isEmpty) return;
    if (!active) {
      _clearRemoteTypingUser(normalized);
      return;
    }

    _remoteTypingTimers.remove(normalized)?.cancel();
    final expiresAt = DateTime.now().add(Duration(milliseconds: ttlMs));
    final shouldScroll = _isNearBottom();
    if (!mounted) {
      _remoteTypingExpiresAt[normalized] = expiresAt;
    } else {
      setState(() => _remoteTypingExpiresAt[normalized] = expiresAt);
    }
    _remoteTypingTimers[normalized] = Timer(Duration(milliseconds: ttlMs), () {
      _clearRemoteTypingUser(normalized);
    });
    if (shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToBottom(animated: true);
      });
    }
  }

  Future<void> _emitChatActivity(
    String eventName, {
    bool? active,
    int ttlMs = 4500,
    bool httpFallback = false,
  }) async {
    if (!_isDirectMessageChat() && !_isDiscussionsChat()) return;
    if (_directRequestStatus() == 'declined') return;
    final eventId =
        '$eventName:${widget.chatId}:${_myUserId()}:${active == false ? 0 : 1}:${DateTime.now().millisecondsSinceEpoch}';
    final payload = <String, dynamic>{
      'chat_id': widget.chatId,
      'ttl_ms': ttlMs,
      'event_id': eventId,
    };
    if (active != null) {
      payload['active'] = active;
    }
    try {
      socket?.emit(eventName, payload);
    } catch (_) {}
    if (!httpFallback || _isRealtimeSocketConnected) return;
    try {
      await authService.dio.post(
        '/api/chats/${widget.chatId}/activity',
        data: <String, dynamic>{...payload, 'type': eventName},
        options: Options(
          connectTimeout: const Duration(seconds: 3),
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
    } catch (_) {
      // Socket is still the primary realtime path; HTTP is only a keepalive backup.
    }
  }

  Future<void> _hydratePersistentOutboxMessages() async {
    try {
      final currentUserId = _myUserId();
      final items = await chatOutboxService.listForChat(
        chatId: widget.chatId,
        tenantCode: _outboxTenantCode(),
      );
      if (items.isEmpty) return;
      var changed = false;
      final nextMessages = List<Map<String, dynamic>>.from(_messages);
      for (final item in items) {
        if (currentUserId.isNotEmpty && item.userId != currentUserId) {
          continue;
        }
        final message = Map<String, dynamic>.from(item.message);
        final meta = _metaMapOf(message['meta']);
        final normalizedStatus = switch (item.status.trim().toLowerCase()) {
          'sending' || 'uploading' => 'queued',
          'failed_permanent' => 'error',
          'queued' || 'error' => item.status.trim().toLowerCase(),
          _ => 'queued',
        };
        meta['local_only'] = true;
        meta['delivery_status'] = normalizedStatus;
        meta['message_send_state'] = normalizedStatus == 'error'
            ? 'failed'
            : 'local_pending';
        if ((item.errorMessage ?? '').trim().isNotEmpty) {
          meta['error_message'] = item.errorMessage!.trim();
        }
        message['meta'] = meta;
        message['client_msg_id'] = item.clientMsgId;
        message['id'] = 'temp-${item.clientMsgId}';
        final index = _messageIndexInList(
          nextMessages,
          clientMsgId: item.clientMsgId,
        );
        if (index >= 0) {
          nextMessages[index] = {...nextMessages[index], ...message};
        } else {
          nextMessages.add(message);
        }
        changed = true;
        if (normalizedStatus != item.status.trim().toLowerCase()) {
          await chatOutboxService.updateStatus(
            chatId: widget.chatId,
            tenantCode: _outboxTenantCode(),
            clientMsgId: item.clientMsgId,
            status: normalizedStatus,
            errorMessage: item.errorMessage,
            message: sanitizeChatOutboxJson(message),
          );
        }
      }
      if (!changed) return;
      nextMessages.sort(_compareByCreatedAt);
      if (!mounted) {
        _messages = nextMessages;
        _refreshLoadedMessageBounds();
        return;
      }
      setState(() {
        _messages = nextMessages;
        _refreshLoadedMessageBounds();
      });
      _recomputeSearchResults();
    } catch (e, st) {
      unawaited(
        MonitoringService.captureError(
          e,
          st,
          subsystem: 'outbox',
          code: 'outbox_hydration_failed',
        ),
      );
    }
  }

  Future<void> _persistOutboxItem({
    required Map<String, dynamic> message,
    required Map<String, dynamic> retryPayload,
    required String status,
    String? errorMessage,
    int retryCount = 0,
  }) async {
    final clientMsgId = (message['client_msg_id'] ?? '').toString().trim();
    if (clientMsgId.isEmpty) return;
    await chatOutboxService.upsert(
      ChatOutboxItem(
        id: buildChatOutboxItemId(
          chatId: widget.chatId,
          tenantCode: _outboxTenantCode(),
          clientMsgId: clientMsgId,
        ),
        chatId: widget.chatId,
        tenantCode: _outboxTenantCode(),
        clientMsgId: clientMsgId,
        userId: _myUserId(),
        status: status.trim().toLowerCase(),
        message: sanitizeChatOutboxJson(message),
        retryPayload: sanitizeChatOutboxJson(retryPayload),
        errorMessage: errorMessage?.trim().isEmpty ?? true
            ? null
            : errorMessage!.trim(),
        retryCount: retryCount,
        createdAtIso: DateTime.now().toIso8601String(),
        updatedAtIso: DateTime.now().toIso8601String(),
      ),
    );
  }

  Future<void> _updatePersistentOutboxStatus({
    required String clientMsgId,
    required String status,
    String? errorMessage,
    bool clearError = false,
    int? retryCount,
    Map<String, dynamic>? message,
  }) async {
    if (clientMsgId.trim().isEmpty) return;
    await chatOutboxService.updateStatus(
      chatId: widget.chatId,
      tenantCode: _outboxTenantCode(),
      clientMsgId: clientMsgId,
      status: status.trim().toLowerCase(),
      errorMessage: errorMessage,
      clearError: clearError,
      retryCount: retryCount,
      message: message == null ? null : sanitizeChatOutboxJson(message),
    );
  }

  Future<void> _removePersistentOutboxItem(String clientMsgId) async {
    if (clientMsgId.trim().isEmpty) return;
    await chatOutboxService.remove(
      chatId: widget.chatId,
      tenantCode: _outboxTenantCode(),
      clientMsgId: clientMsgId,
    );
  }

  String _dioErrorCode(Object error) {
    if (error is! DioException) return '';
    final data = error.response?.data;
    if (data is Map) {
      return (data['error_code'] ?? data['code'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
    }
    return '';
  }

  bool _isRetryableOutboxError(Object error) {
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return true;
      }
      final statusCode = error.response?.statusCode ?? 0;
      final errorCode = _dioErrorCode(error);
      if (statusCode >= 500) return true;
      if (statusCode == 409) {
        return errorCode == 'chat_upload_offset_mismatch' ||
            errorCode == 'chat_upload_incomplete' ||
            errorCode == 'chat_upload_session_not_ready';
      }
      if (statusCode == 408 || statusCode == 429) {
        return true;
      }
      return false;
    }
    final normalized = error.toString().toLowerCase();
    return normalized.contains('network') ||
        normalized.contains('socketexception') ||
        normalized.contains('timeout') ||
        normalized.contains('connection');
  }

  Future<void> _deletePersistentOutboxMessage(
    Map<String, dynamic> message,
  ) async {
    final clientMsgId = (message['client_msg_id'] ?? '').toString().trim();
    if (clientMsgId.isEmpty) return;
    await _removePersistentOutboxItem(clientMsgId);
    _removeMessageLocally(_messageIdOf(message));
  }

  Future<void> _reconcilePersistentOutbox() async {
    final items = await chatOutboxService.listForChat(
      chatId: widget.chatId,
      tenantCode: _outboxTenantCode(),
    );
    if (items.isEmpty) return;
    final clientMsgIds = items
        .map((item) => item.clientMsgId.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (clientMsgIds.isEmpty) return;
    try {
      final response = await authService.dio.post(
        '/api/chats/${widget.chatId}/outbox/reconcile',
        data: {'client_msg_ids': clientMsgIds},
      );
      final data = response.data;
      final rows = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(
              (data['data'] as List).whereType<Map>(),
            )
          : const <Map<String, dynamic>>[];
      for (final row in rows) {
        final clientMsgId = (row['client_msg_id'] ?? '').toString().trim();
        if (clientMsgId.isEmpty) continue;
        final state = (row['state'] ?? '').toString().trim().toLowerCase();
        if (state == 'committed' && row['message'] is Map) {
          _upsertMessage(Map<String, dynamic>.from(row['message'] as Map));
          await _removePersistentOutboxItem(clientMsgId);
          continue;
        }
        if (state == 'failed_permanent') {
          _patchMessageLocally(
            clientMsgId: clientMsgId,
            transform: (current) {
              final meta = _metaMapOf(current['meta']);
              meta['delivery_status'] = 'error';
              meta['message_send_state'] = 'failed';
              meta['error_message'] = 'Сервер отклонил файл';
              return {...current, 'meta': meta};
            },
          );
          await _updatePersistentOutboxStatus(
            clientMsgId: clientMsgId,
            status: 'error',
            errorMessage: 'Сервер отклонил файл',
          );
          continue;
        }
        if (state == 'ready' ||
            state == 'processing' ||
            state == 'uploading' ||
            state == 'uploaded') {
          _patchMessageLocally(
            clientMsgId: clientMsgId,
            transform: (current) {
              final meta = _metaMapOf(current['meta']);
              meta['delivery_status'] = state == 'ready'
                  ? 'sending'
                  : 'uploading';
              meta.remove('error_message');
              return {...current, 'meta': meta};
            },
          );
        }
      }
    } catch (e, st) {
      unawaited(
        MonitoringService.captureError(
          e,
          st,
          subsystem: 'outbox',
          code: 'outbox_reconcile_failed',
        ),
      );
    }
  }

  Future<void> _flushPersistentOutbox({bool includeErrored = false}) async {
    if (!mounted) return;
    if (_persistentOutboxFlushInFlight) {
      _persistentOutboxFlushPending = true;
      _persistentOutboxPendingIncludeErrored =
          _persistentOutboxPendingIncludeErrored || includeErrored;
      return;
    }
    _persistentOutboxFlushInFlight = true;
    try {
      final currentUserId = _myUserId();
      final items = await chatOutboxService.listForChat(
        chatId: widget.chatId,
        tenantCode: _outboxTenantCode(),
      );
      if (!mounted) return;
      for (final item in items) {
        if (!mounted) break;
        if (currentUserId.isNotEmpty && item.userId != currentUserId) continue;
        final normalizedStatus = item.status.trim().toLowerCase();
        if (!(normalizedStatus == 'queued' ||
            normalizedStatus == 'sending' ||
            normalizedStatus == 'uploading' ||
            (includeErrored && normalizedStatus == 'error'))) {
          continue;
        }
        final retryPayload = Map<String, dynamic>.from(item.retryPayload);
        final retryKind = (retryPayload['kind'] ?? '').toString().trim();
        final sendingStatus = retryKind == 'media' ? 'uploading' : 'sending';
        if (mounted) {
          setState(() {
            _mediaUploading = retryKind == 'media';
            _voiceSending =
                retryKind == 'media' &&
                (retryPayload['attachment_type'] ?? '').toString().trim() ==
                    'voice';
          });
        } else {
          _mediaUploading = retryKind == 'media';
          _voiceSending =
              retryKind == 'media' &&
              (retryPayload['attachment_type'] ?? '').toString().trim() ==
                  'voice';
        }
        _patchMessageLocally(
          clientMsgId: item.clientMsgId,
          transform: (current) {
            final nextMeta = _metaMapOf(current['meta']);
            nextMeta['delivery_status'] = sendingStatus;
            nextMeta.remove('error_message');
            if (sendingStatus == 'uploading') {
              nextMeta['local_upload_progress'] = 0.0;
            }
            return {...current, 'meta': nextMeta};
          },
        );
        await _updatePersistentOutboxStatus(
          clientMsgId: item.clientMsgId,
          status: sendingStatus,
          clearError: true,
          retryCount: item.retryCount,
          message: item.message,
        );

        try {
          if (retryKind == 'text') {
            final text = (retryPayload['text'] ?? '').toString().trim();
            if (text.isEmpty) {
              throw StateError('Пустой текст в persistent outbox');
            }
            final replyPayload = _extractReplyPayloadFromRetryPayload(
              retryPayload,
            );
            final resp = await authService.dio.post(
              '/api/chats/${widget.chatId}/messages',
              data: {
                'text': text,
                'client_msg_id': item.clientMsgId,
                ...replyPayload,
              },
            );
            if (!mounted) return;
            if (resp.statusCode == 200 || resp.statusCode == 201) {
              final data = resp.data;
              if (data is Map && data['ok'] == true && data['data'] is Map) {
                _upsertMessage(
                  Map<String, dynamic>.from(data['data']),
                  autoScroll: true,
                );
              }
            }
          } else if (retryKind == 'media') {
            final upload = _uploadFromRetryPayload(retryPayload);
            final attachmentType = (retryPayload['attachment_type'] ?? '')
                .toString()
                .trim();
            if (upload == null || attachmentType.isEmpty) {
              throw StateError('Media payload is unreadable');
            }
            final replyPayload = _extractReplyPayloadFromRetryPayload(
              retryPayload,
            );
            await _postMediaMessage(
              upload: upload,
              attachmentType: attachmentType,
              clientMsgId: item.clientMsgId,
              caption: (retryPayload['caption'] ?? '').toString(),
              replyPayload: replyPayload,
              durationMs: int.tryParse('${retryPayload['duration_ms'] ?? 0}'),
              isVideoNote:
                  (retryPayload['is_video_note'] ?? false) == true ||
                  (retryPayload['is_video_note'] ?? '').toString() == 'true',
              listenOnce:
                  (retryPayload['listen_once'] ?? false) == true ||
                  (retryPayload['listen_once'] ?? '').toString() == 'true',
            );
            if (!mounted) return;
          } else {
            continue;
          }

          await _removePersistentOutboxItem(item.clientMsgId);
          await playAppSound(AppUiSound.sent);
          unawaited(
            MonitoringService.captureEvent(
              subsystem: 'outbox',
              code: 'outbox_item_delivered',
              level: 'info',
              message: 'Outbox item delivered',
              details: <String, dynamic>{
                'chat_id': widget.chatId,
                'client_msg_id': item.clientMsgId,
                'kind': retryKind,
              },
            ),
          );
        } catch (e, st) {
          final retryCount = item.retryCount + 1;
          final isRetryable = retryCount <= 3 && _isRetryableOutboxError(e);
          final nextStatus = isRetryable ? 'queued' : 'error';
          final errorMessage = _extractDioError(e);
          _patchMessageLocally(
            clientMsgId: item.clientMsgId,
            transform: (current) {
              final nextMeta = _metaMapOf(current['meta']);
              nextMeta['delivery_status'] = nextStatus;
              nextMeta['message_send_state'] = nextStatus == 'error'
                  ? 'failed'
                  : 'local_pending';
              nextMeta['error_message'] = errorMessage;
              nextMeta.remove('local_upload_progress');
              return {...current, 'meta': nextMeta};
            },
          );
          await _updatePersistentOutboxStatus(
            clientMsgId: item.clientMsgId,
            status: nextStatus,
            errorMessage: errorMessage,
            retryCount: retryCount,
            message: _messages
                .where(
                  (message) =>
                      (message['client_msg_id'] ?? '').toString().trim() ==
                      item.clientMsgId,
                )
                .cast<Map<String, dynamic>?>()
                .firstWhere((_) => true, orElse: () => null),
          );
          unawaited(
            MonitoringService.captureError(
              e,
              st,
              subsystem: 'outbox',
              code: isRetryable
                  ? 'outbox_retry_failed'
                  : 'outbox_permanent_failure',
              level: isRetryable ? 'warn' : 'error',
              details: <String, dynamic>{
                'chat_id': widget.chatId,
                'client_msg_id': item.clientMsgId,
                'kind': retryKind,
                'retry_count': retryCount,
              },
            ),
          );
          if (isRetryable) {
            _schedulePersistentOutboxRetry(retryCount: retryCount);
          }
        }
        if (mounted) {
          setState(() {
            _mediaUploading = false;
            _voiceSending = false;
          });
        } else {
          _mediaUploading = false;
          _voiceSending = false;
        }
      }
    } finally {
      _persistentOutboxFlushInFlight = false;
      if (_persistentOutboxFlushPending) {
        final rerunIncludeErrored = _persistentOutboxPendingIncludeErrored;
        _persistentOutboxFlushPending = false;
        _persistentOutboxPendingIncludeErrored = false;
        Future<void>.microtask(() {
          if (!mounted) return;
          unawaited(
            _flushPersistentOutbox(includeErrored: rerunIncludeErrored),
          );
        });
      }
    }
  }

  void _schedulePersistentOutboxRetry({int retryCount = 0}) {
    if (!mounted) return;
    final safeRetryCount = retryCount.clamp(0, 5).toInt();
    final delayMs = switch (safeRetryCount) {
      <= 1 => 900,
      2 => 1800,
      3 => 3200,
      4 => 5200,
      _ => 8000,
    };
    _persistentOutboxRetryTimer?.cancel();
    _persistentOutboxRetryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      unawaited(_flushPersistentOutbox());
    });
  }

  void _maybeEmitTypingActivity() {
    if (!_isDirectMessageChat() && !_isDiscussionsChat()) return;
    if (!_canCompose()) return;
    if (_controller.text.trim().isEmpty) {
      _maybeEmitTypingInactive();
      return;
    }
    _scheduleTypingKeepAlive();
    final now = DateTime.now();
    final last = _lastTypingEmitAt;
    if (last != null && now.difference(last) < _typingEmitThrottle) {
      return;
    }
    _lastTypingEmitAt = now;
    _localTypingActiveSent = true;
    unawaited(
      _emitChatActivity(
        'chat:typing',
        active: true,
        ttlMs: _typingActiveTtlMs,
        httpFallback: true,
      ),
    );
  }

  void _scheduleTypingKeepAlive() {
    _localTypingIdleTimer?.cancel();
    _localTypingIdleTimer = Timer(_typingKeepAliveInterval, () {
      if (!mounted) return;
      if (_controller.text.trim().isEmpty || !_canCompose()) {
        _maybeEmitTypingInactive();
        return;
      }
      _maybeEmitTypingActivity();
    });
  }

  void _maybeEmitTypingInactive() {
    _localTypingIdleTimer?.cancel();
    if (!_localTypingActiveSent) return;
    _localTypingActiveSent = false;
    _lastTypingEmitAt = null;
    unawaited(
      _emitChatActivity(
        'chat:typing',
        active: false,
        ttlMs: 1000,
        httpFallback: true,
      ),
    );
  }

  Future<void> _loadContactCard() async {
    if (!_isDirectMessageChat()) return;
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/contact-card',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final card = Map<String, dynamic>.from(data['data']);
        if (!mounted) {
          _contactCard = card;
          return;
        }
        setState(() => _contactCard = card);
      }
    } catch (_) {}
  }

  Future<void> _respondToDirectRequest(String action) async {
    final requestId =
        (_contactCard?['request_id'] ??
                _effectiveChatSettings()['direct_request_id'] ??
                '')
            .toString()
            .trim();
    if (requestId.isEmpty) {
      showAppNotice(
        context,
        'Не удалось определить запрос на переписку',
        tone: AppNoticeTone.error,
      );
      return;
    }
    try {
      final resp = await authService.dio.post(
        '/api/chats/direct/requests/$requestId/$action',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final payload = data['data'];
        if (payload is Map && payload['chat'] is Map) {
          _applyIncomingChatSnapshot(
            Map<String, dynamic>.from(payload['chat']),
          );
        } else if (action == 'decline' && mounted) {
          setState(() {
            _chatSettings = {
              ..._effectiveChatSettings(),
              'direct_request_status': 'declined',
            };
          });
        }
        await _loadContactCard();
        if (!mounted) return;
        showAppNotice(
          context,
          action == 'accept'
              ? 'Запрос на переписку принят'
              : 'Запрос на переписку отклонён',
          tone: action == 'accept' ? AppNoticeTone.success : AppNoticeTone.info,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось обработать запрос: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _addPeerToContactsFromCard() async {
    final peer = _contactCard?['peer'];
    final userId = peer is Map ? (peer['id'] ?? '').toString().trim() : '';
    if (userId.isEmpty) return;
    try {
      await authService.dio.post(
        '/api/chats/contacts',
        data: {'user_id': userId},
      );
      await _loadContactCard();
      if (!mounted) return;
      showAppNotice(context, 'Контакт добавлен', tone: AppNoticeTone.success);
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось добавить контакт: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _initializeChat() async {
    await _restoreSavedScrollOffset();
    await _loadServerChatState();
    if (!mounted) return;
    await _hydratePersistentOutboxMessages();
    await _reconcilePersistentOutbox();
    await _loadMessages();
    unawaited(_flushPersistentOutbox());
    await _loadContactCard();
    _startDirectMessageLiveSync();
    _startRemoteActivityPolling();
    _startChannelPublicationLiveSync(resetWindow: true);
  }

  @override
  void dispose() {
    if (_unreadCount > 0 && !_readFlushOnExitInFlight) {
      unawaited(_flushReadStateOnExit());
    }
    if (activeChatIdNotifier.value == widget.chatId) {
      activeChatIdNotifier.value = null;
    }
    _incomingTimer?.cancel();
    _readDebounceTimer?.cancel();
    _voiceRecordingTimer?.cancel();
    _videoRecordingTimer?.cancel();
    _voiceRecordingCancelVisualTimer?.cancel();
    _videoRecordingCancelVisualTimer?.cancel();
    _offlineQueueRefreshTimer?.cancel();
    _composerMediaHoldTimer?.cancel();
    _bottomAnchorTimer?.cancel();
    _persistScrollOffsetTimer?.cancel();
    _initialViewportFailsafeTimer?.cancel();
    _draftSyncTimer?.cancel();
    _serverChatStateSyncTimer?.cancel();
    _reconnectReplayTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _remoteActivityTimer?.cancel();
    _remoteActivityPollTimer?.cancel();
    _localTypingIdleTimer?.cancel();
    _directMessageLiveSyncTimer?.cancel();
    _channelPublicationLiveSyncTimer?.cancel();
    _channelPublicationImmediateSyncTimer?.cancel();
    _persistentOutboxRetryTimer?.cancel();
    _realtimeChatRefreshTimer?.cancel();
    _draftRestoredHintTimer?.cancel();
    _scrollRestoredHintTimer?.cancel();
    _searchHitHighlightTimer?.cancel();
    for (final timer in _remoteTypingTimers.values) {
      timer.cancel();
    }
    _remoteTypingTimers.clear();
    _remoteTypingExpiresAt.clear();
    _maybeEmitTypingInactive();
    _chatSub?.cancel();
    _connectivitySub?.cancel();
    _voicePositionSub?.cancel();
    _voiceDurationSub?.cancel();
    _voiceStateSub?.cancel();
    _voiceCompleteSub?.cancel();
    _stopNativeVideoPreviewStream();
    _leaveRoom();

    unawaited(_voicePlayer.stop());
    unawaited(_voicePlayer.dispose());
    final voiceRecorder = _voiceRecorderInstance;
    if (_voiceRecording && voiceRecorder != null) {
      unawaited(voiceRecorder.stop());
    }
    if (voiceRecorder != null) {
      unawaited(voiceRecorder.dispose());
    }
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
    _recordingHoverController.dispose();
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
    if (_isReservedOrder(message)) return false;
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
    final persistedMessages = _messages
        .where((message) {
          final meta = _metaMapOf(message['meta']);
          final id = _messageIdOf(message);
          return meta['local_only'] != true &&
              id.isNotEmpty &&
              !id.startsWith('temp-');
        })
        .toList(growable: false);
    if (persistedMessages.isEmpty) {
      _oldestLoadedMessageId = null;
      _oldestLoadedCreatedAt = null;
      _newestLoadedMessageId = null;
      _newestLoadedCreatedAt = null;
      return;
    }
    final ordered = [...persistedMessages]..sort(_compareByCreatedAt);
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
    final previousFirstUnreadMessageId = _firstUnreadMessageId;
    final previousUnreadCount = _unreadCount;
    _lastSeenMessageId =
        (state['last_seen_message_id'] ?? '').toString().trim().isEmpty
        ? null
        : (state['last_seen_message_id'] ?? '').toString().trim();
    _firstUnreadMessageId =
        (state['first_unread_message_id'] ?? '').toString().trim().isEmpty
        ? null
        : (state['first_unread_message_id'] ?? '').toString().trim();
    _unreadCount = int.tryParse('${state['unread_count'] ?? 0}') ?? 0;
    final unreadAnchorChanged =
        (previousFirstUnreadMessageId ?? '').trim() !=
        (_firstUnreadMessageId ?? '').trim();
    final unreadIncreased = _unreadCount > previousUnreadCount;
    if (_unreadCount <= 0 || unreadAnchorChanged || unreadIncreased) {
      _jumpedToFirstUnread = false;
    }

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
        _scheduleScrollRestoredHint();
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
        _scheduleDraftRestoredHint();
      }
    }
  }

  void _scheduleDraftRestoredHint() {
    _draftRestoredHintTimer?.cancel();
    _draftRestoredHintVisible = true;
    _draftRestoredHintTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) {
        _draftRestoredHintVisible = false;
        return;
      }
      setState(() => _draftRestoredHintVisible = false);
    });
  }

  void _scheduleScrollRestoredHint() {
    _scrollRestoredHintTimer?.cancel();
    _scrollRestoredHintVisible = true;
    _scrollRestoredHintTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) {
        _scrollRestoredHintVisible = false;
        return;
      }
      setState(() => _scrollRestoredHintVisible = false);
    });
  }

  void _markSearchHitHighlighted(String messageId) {
    final normalized = messageId.trim();
    if (normalized.isEmpty) return;
    _searchHitHighlightTimer?.cancel();
    if (mounted) {
      setState(() => _highlightedSearchMessageId = normalized);
    } else {
      _highlightedSearchMessageId = normalized;
    }
    _searchHitHighlightTimer = Timer(const Duration(milliseconds: 1050), () {
      if (!mounted) {
        _highlightedSearchMessageId = null;
        return;
      }
      setState(() {
        if (_highlightedSearchMessageId == normalized) {
          _highlightedSearchMessageId = null;
        }
      });
    });
  }

  Widget _buildEphemeralChatHint({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return PhoenixSlideFadeIn(
      beginOffset: const Offset(0, 12),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              color.withValues(alpha: 0.10),
              theme.colorScheme.surfaceContainerHigh,
            ),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.24)),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.12),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadServerChatState({bool restoreDraft = true}) async {
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/state',
      );
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
    await authService.dio.patch(
      '/api/chats/${widget.chatId}/state',
      data: patch,
    );
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
    if (_useApproximateViewportTracking) {
      return _approximateViewportMessageId();
    }
    final viewportContext = _messagesViewportKey.currentContext;
    final viewportObject = viewportContext?.findRenderObject();
    if (viewportObject is! RenderBox) return null;
    String? bestId;
    var bestBottom = double.negativeInfinity;
    for (final entry in _messageItemKeys.entries) {
      final itemContext = entry.value.currentContext;
      final itemObject = itemContext?.findRenderObject();
      if (itemObject is! RenderBox || !itemObject.hasSize) continue;
      final top = _renderBoxTopInViewport(itemObject, viewportObject);
      if (top == null) continue;
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
    final anchorMessageId = anchor?.messageId.trim();
    if (anchor != null && _isPersistableServerMessageId(anchorMessageId)) {
      patch['scroll_anchor_message_id'] = anchorMessageId;
      patch['scroll_anchor_offset'] = anchor.offset;
    }
    final normalizedVisibleLastMessageId = (visibleLastMessageId ?? '').trim();
    if (_isPersistableServerMessageId(normalizedVisibleLastMessageId)) {
      patch['last_seen_message_id'] = normalizedVisibleLastMessageId;
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
    if (_useApproximateViewportTracking) {
      return null;
    }
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
      final top = _renderBoxTopInViewport(itemObject, viewportObject);
      if (top == null) continue;
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

  double? _renderBoxTopInViewport(
    RenderBox itemObject,
    RenderBox viewportObject,
  ) {
    if (!itemObject.attached || !viewportObject.attached) return null;
    try {
      final itemGlobal = itemObject.localToGlobal(Offset.zero);
      final viewportGlobal = viewportObject.localToGlobal(Offset.zero);
      return itemGlobal.dy - viewportGlobal.dy;
    } catch (_) {
      return null;
    }
  }

  String? _stickyDateLabelForViewport() {
    final anchorMessageId =
        (_useApproximateViewportTracking
                ? _approximateViewportMessageId()
                : _currentScrollAnchor()?.messageId)
            ?.trim() ??
        '';
    if (anchorMessageId.isEmpty) return null;
    for (final message in _messages) {
      if (_messageIdOf(message) != anchorMessageId) continue;
      final createdAt = _parseDate(message['created_at']);
      if (createdAt == null) return null;
      return _formatDateLabel(createdAt);
    }
    return null;
  }

  double _timelineCacheExtentMultiplier() {
    if (kIsWeb) {
      return performanceModeNotifier.value ? 0.28 : 0.42;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return performanceModeNotifier.value ? 0.95 : 1.45;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return performanceModeNotifier.value ? 0.7 : 1.1;
    }
  }

  void _refreshStickyDateLabel({required bool show}) {
    final nextLabel = show ? _stickyDateLabelForViewport() : null;
    if (_stickyDateLabel == nextLabel) return;
    if (!mounted) {
      _stickyDateLabel = nextLabel;
      return;
    }
    setState(() => _stickyDateLabel = nextLabel);
  }

  bool _isPersistableServerMessageId(String? messageId) {
    final normalized = (messageId ?? '').trim();
    if (normalized.isEmpty) return false;
    if (normalized.startsWith('temp-')) return false;
    return _uuidPattern.hasMatch(normalized);
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
    if (_scrollController.hasClients &&
        _scrollController.position.pixels <= 280) {
      unawaited(_loadOlderMessages());
    }
    final userDirection = _scrollController.hasClients
        ? _scrollController.position.userScrollDirection
        : ScrollDirection.idle;
    final nearBottom = _isNearBottom();
    if (userDirection == ScrollDirection.forward) {
      _manualBottomLockSuppressed = true;
      _stickToBottom = false;
      _clearBottomSettle();
    } else {
      if (_manualBottomLockSuppressed &&
          nearBottom &&
          (userDirection == ScrollDirection.reverse ||
              userDirection == ScrollDirection.idle)) {
        _manualBottomLockSuppressed = false;
      }
      _stickToBottom = nearBottom && !_manualBottomLockSuppressed;
    }
    if (_unreadCount > 0 && _initialViewportReady) {
      _scheduleReadSync();
    }
    final shouldShow = _initialViewportReady && !nearBottom;
    _refreshStickyDateLabel(show: shouldShow);
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
      _manualBottomLockSuppressed = false;
      _stickToBottom = true;
      final target = _scrollController.position.maxScrollExtent;
      if (settlePasses > 0) {
        _armBottomSettle(
          passes: settlePasses,
          delay: animated ? const Duration(milliseconds: 220) : Duration.zero,
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

  void _forceChannelPublicationViewportToLatest({
    bool animated = true,
    int passes = 4,
    bool respectUserScroll = true,
  }) {
    if (!mounted || !_isPublicationLiveSyncChannel()) return;
    if (respectUserScroll && !_isNearBottom() && !_stickToBottom) {
      _channelLiveLog('force latest viewport skipped: user is reading above');
      return;
    }
    _manualBottomLockSuppressed = false;
    _stickToBottom = true;
    _savedScrollOffset = null;
    _savedScrollFraction = null;
    _savedScrollAnchorMessageId = null;
    _savedScrollAnchorOffset = null;

    void schedulePass(int remaining, Duration delay) {
      if (remaining <= 0) return;
      Future<void>.delayed(delay, () {
        if (!mounted || !_isPublicationLiveSyncChannel()) return;
        _scrollToBottom(
          animated: animated && remaining == passes,
          settlePasses: remaining == passes ? 5 : 1,
          settleInterval: const Duration(milliseconds: 90),
        );
        schedulePass(remaining - 1, const Duration(milliseconds: 180));
      });
    }

    _scrollToBottom(
      animated: animated,
      settlePasses: 5,
      settleInterval: const Duration(milliseconds: 90),
    );
    schedulePass(passes - 1, const Duration(milliseconds: 140));
  }

  void _applyInitialViewportAfterLoad() {
    if (_initialViewportApplied) return;
    _initialViewportApplied = true;
    _initialViewportFailsafeTimer?.cancel();
    _initialViewportFailsafeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _initialViewportReady) return;
      _fallbackAfterAnchorRestoreFailure();
    });
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
    if (!_useApproximateViewportTracking &&
        savedAnchorMessageId != null &&
        savedAnchorMessageId.isNotEmpty) {
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

    final currentTop = _renderBoxTopInViewport(targetObject, viewportObject);
    if (currentTop == null) {
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
    if (_unreadCount > 0 || _shouldReadWholeOpenChat()) {
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
      if (!_useApproximateViewportTracking &&
          anchorMessageId != null &&
          anchorMessageId.isNotEmpty) {
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
    if (!_stickToBottom || _manualBottomLockSuppressed) return;
    _armBottomSettle(
      passes: 2,
      delay: Duration.zero,
      interval: const Duration(milliseconds: 80),
    );
  }

  Future<bool> _warmUpVisibleImageDimensions(
    List<Map<String, dynamic>> messages, {
    int limit = 10,
    bool refreshAfterWarmUp = false,
  }) async {
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
      if (_isCatalogProduct(message) || _isReservedOrder(message)) continue;
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
    await Future.wait(
      sample.map((item) async {
        final size = await warmUpChatMessageImageSize(item.url);
        if (size == null || size.width <= 0 || size.height <= 0) return;
        final meta = _metaMapOf(item.message['meta']);
        final nextWidth = size.width.round();
        final nextHeight = size.height.round();
        final currentWidth = _positiveMediaDimension(
          meta['image_width'],
        )?.round();
        final currentHeight = _positiveMediaDimension(
          meta['image_height'],
        )?.round();
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
      }),
    );

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

    final candidates = <({int distance, String url})>[];
    for (var index = 0; index < messages.length; index++) {
      if (_isCatalogProduct(messages[index]) ||
          _isReservedOrder(messages[index])) {
        continue;
      }
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
    if (fromMe && localOnly) {
      final status = (meta['delivery_status'] ?? '').toString().trim();
      meta['message_send_state'] = status == 'error'
          ? 'failed'
          : 'local_pending';
    } else if (fromMe && !localOnly) {
      meta['delivery_status'] = normalized['read_by_others'] == true
          ? 'read'
          : 'sent';
      meta['message_send_state'] = 'server_confirmed';
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
        (m) =>
            (m['client_msg_id']?.toString() ?? '').trim() ==
            normalizedClientMsgId,
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
    merged.sort(_compareByCreatedAt);
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

    if (_isPublicationLiveSyncChannel()) {
      for (final existingMessage in _messages) {
        final message = Map<String, dynamic>.from(existingMessage);
        final id = _messageIdOf(message);
        if (id.isEmpty || id.startsWith('temp-') || _isHiddenForAll(message)) {
          continue;
        }
        final existingIndex = _messageIndexInList(merged, messageId: id);
        if (existingIndex >= 0) continue;
        // Silent channel reloads fetch only the latest page. Preserve already
        // loaded older messages so live-refresh does not erase the user's
        // current reading position.
        merged.add(_normalizeMessage(message));
      }
    }

    return _dedupeMessages(merged);
  }

  void _patchMessageLocally({
    required String clientMsgId,
    Map<String, dynamic> Function(Map<String, dynamic> message)? transform,
  }) {
    if (!mounted) return;
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
    if (!mounted) return;
    final normalized = _normalizeMessage(msg);
    final msgId = normalized['id']?.toString();
    final clientMsgId = normalized['client_msg_id']?.toString() ?? '';
    final meta = _metaMapOf(normalized['meta']);
    final localOnly = meta['local_only'] == true;
    var inserted = false;
    var insertedMessageId = '';
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
          insertedMessageId = msgId;
          _appearingMessageIds.add(msgId);
          _messages = [..._messages, normalized];
        }
        _messages = _dedupeMessages(_messages);
        if (!localOnly) {
          _messageIds.add(msgId);
        }
      }
    });

    if (inserted && insertedMessageId.isNotEmpty) {
      _scheduleMessageAppearanceClear(insertedMessageId);
    }
    _refreshLoadedMessageBounds();
    _recomputeSearchResults();

    if (!localOnly && clientMsgId.trim().isNotEmpty) {
      unawaited(_removePersistentOutboxItem(clientMsgId.trim()));
    }

    if (autoScroll) {
      if (_isPublicationLiveSyncChannel() && inserted) {
        _forceChannelPublicationViewportToLatest(animated: true);
      } else {
        _scrollToBottom(animated: true);
      }
    }
  }

  void _startDirectMessageLiveSync() {
    _directMessageLiveSyncTimer?.cancel();
    if ((!_isDirectMessageChat() && !_isDiscussionsChat()) ||
        _isReservedOrdersChat()) {
      return;
    }
    if (_isRealtimeSocketConnected) {
      _directMessageLiveSyncTimer = null;
      return;
    }
    _directMessageLiveSyncTimer = Timer.periodic(
      _directMessageFallbackSyncInterval,
      (_) => unawaited(_syncLatestDirectMessages()),
    );
  }

  void _startRemoteActivityPolling() {
    _remoteActivityPollTimer?.cancel();
    if ((!_isDirectMessageChat() && !_isDiscussionsChat()) ||
        _isReservedOrdersChat()) {
      return;
    }
    if (_isRealtimeSocketConnected) {
      _remoteActivityPollTimer = null;
      return;
    }
    _remoteActivityPollTimer = Timer.periodic(
      _remoteActivityFallbackPollInterval,
      (_) => unawaited(_pollRemoteChatActivity()),
    );
    unawaited(_pollRemoteChatActivity());
  }

  void _startChannelPublicationLiveSync({bool resetWindow = false}) {
    if (!_isPublicationLiveSyncChannel()) {
      _channelLiveLog('live-sync start skipped: not publication channel', {
        'reset_window': resetWindow,
      });
      _stopChannelPublicationLiveSync();
      return;
    }
    final now = DateTime.now();
    if (resetWindow ||
        _channelPublicationLiveSyncWarmUntil == null ||
        now.isAfter(_channelPublicationLiveSyncWarmUntil!)) {
      _channelPublicationLiveSyncWarmUntil = now.add(
        _channelPublicationLiveSyncWarmWindow,
      );
    }
    _channelLiveLog('live-sync started/scheduled', {
      'reset_window': resetWindow,
      'warm_until': _channelPublicationLiveSyncWarmUntil?.toIso8601String(),
    });
    _scheduleNextChannelPublicationLiveSync(
      delay: const Duration(milliseconds: 650),
    );
  }

  void _stopChannelPublicationLiveSync() {
    _channelLiveLog('live-sync stopped');
    _channelPublicationLiveSyncTimer?.cancel();
    _channelPublicationLiveSyncTimer = null;
    _channelPublicationImmediateSyncTimer?.cancel();
    _channelPublicationImmediateSyncTimer = null;
    _channelPublicationLiveSyncWarmUntil = null;
    _channelPublicationForceLatestFallback = false;
    _channelPublicationLiveSyncInFlight = false;
  }

  void _scheduleChannelPublicationImmediateSync({
    Duration delay = const Duration(milliseconds: 140),
    bool forceLatest = false,
  }) {
    if (!mounted || !_isPublicationLiveSyncChannel()) return;
    if (forceLatest) {
      _channelPublicationForceLatestFallback = true;
    }
    _channelLiveLog('immediate sync scheduled', {
      'delay_ms': delay.inMilliseconds,
      'force_latest': forceLatest,
    });
    _channelPublicationImmediateSyncTimer?.cancel();
    _channelPublicationImmediateSyncTimer = Timer(delay, () {
      if (!mounted || !_isPublicationLiveSyncChannel()) return;
      if (_channelPublicationForceLatestFallback) {
        _channelLiveLog('immediate sync running silent latest reload');
        unawaited(_loadMessages(showLoader: false));
        return;
      }
      _channelLiveLog('immediate sync running silent reload');
      unawaited(_loadMessages(showLoader: false));
    });
  }

  void _scheduleNextChannelPublicationLiveSync({Duration? delay}) {
    _channelPublicationLiveSyncTimer?.cancel();
    if (!mounted || !_isPublicationLiveSyncChannel()) {
      _channelLiveLog(
        'next live-sync skipped: not mounted/publication channel',
      );
      _stopChannelPublicationLiveSync();
      return;
    }
    final now = DateTime.now();
    final warmUntil = _channelPublicationLiveSyncWarmUntil;
    final isWarm = warmUntil != null && now.isBefore(warmUntil);
    final nextDelay =
        delay ??
        (isWarm
            ? _channelPublicationLiveSyncFastInterval
            : _channelPublicationLiveSyncSlowInterval);
    _channelLiveLog('next live-sync scheduled', {
      'delay_ms': nextDelay.inMilliseconds,
      'is_warm': isWarm,
      'warm_until': warmUntil?.toIso8601String(),
    });
    _channelPublicationLiveSyncTimer = Timer(nextDelay, () {
      unawaited(_runChannelPublicationLiveSyncTick());
    });
  }

  Future<void> _runChannelPublicationLiveSyncTick() async {
    if (!mounted || !_isPublicationLiveSyncChannel()) {
      _channelLiveLog(
        'live-sync tick skipped: not mounted/publication channel',
      );
      _stopChannelPublicationLiveSync();
      return;
    }
    if (_channelPublicationLiveSyncInFlight ||
        _loadingNewerMessages ||
        _messagesLoadInFlight) {
      _channelLiveLog('live-sync tick skipped: busy', {
        'sync_in_flight': _channelPublicationLiveSyncInFlight,
        'loading_newer': _loadingNewerMessages,
        'messages_load_in_flight': _messagesLoadInFlight,
      });
      _scheduleNextChannelPublicationLiveSync();
      return;
    }
    _channelPublicationLiveSyncInFlight = true;
    try {
      _channelLiveLog('live-sync tick running silent latest reload');
      await _loadMessages(showLoader: false);
    } finally {
      _channelPublicationLiveSyncInFlight = false;
      if (mounted) {
        _channelLiveLog('live-sync tick finished');
        _scheduleNextChannelPublicationLiveSync();
      }
    }
  }

  Future<void> _pollRemoteChatActivity() async {
    if ((!_isDirectMessageChat() && !_isDiscussionsChat()) ||
        _isReservedOrdersChat()) {
      return;
    }
    if (_isRealtimeSocketConnected) return;
    if (_remoteActivityPollInFlight || !mounted) return;
    _remoteActivityPollInFlight = true;
    try {
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/activity',
        options: Options(
          connectTimeout: const Duration(seconds: 3),
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true) return;
      final raw = data['data'];
      final activities = raw is List ? raw : const [];
      for (final item in activities) {
        if (item is! Map) continue;
        final type = (item['type'] ?? '').toString().trim();
        if (type != 'chat:typing') continue;
        final userId = (item['user_id'] ?? item['userId'] ?? '')
            .toString()
            .trim();
        if (userId.isEmpty || userId == _myUserId()) continue;
        final ttl = _socketTtlMs(
          item['ttl_ms'] ?? item['ttlMs'],
          fallback: 1600,
        );
        _applyRemoteTypingEvent(userId, active: true, ttlMs: ttl);
        _setRemoteActivityLabel('Печатает...', ttlMs: ttl);
      }
    } catch (_) {
      // Socket remains the primary path; polling is a narrow fallback for open DMs.
    } finally {
      _remoteActivityPollInFlight = false;
    }
  }

  Future<void> _syncLatestDirectMessages({bool forceLatest = false}) async {
    if ((!_isDirectMessageChat() && !_isDiscussionsChat()) ||
        _isReservedOrdersChat()) {
      return;
    }
    if (_isRealtimeSocketConnected && !forceLatest) return;
    if (_directMessageLiveSyncInFlight || _messagesLoadInFlight || _loading) {
      return;
    }
    if (!mounted) return;

    final newestCreatedAt = _newestLoadedCreatedAt;
    final newestMessageId = _newestLoadedMessageId;
    final canUseAfterCursor =
        !forceLatest &&
        newestCreatedAt != null &&
        newestCreatedAt.trim().isNotEmpty &&
        newestMessageId != null &&
        newestMessageId.trim().isNotEmpty;
    if (!canUseAfterCursor && _messages.isNotEmpty && !forceLatest) {
      return;
    }

    _directMessageLiveSyncInFlight = true;
    try {
      final query = <String, dynamic>{
        'limit': canUseAfterCursor ? 40 : (kIsWeb ? 60 : 80),
        if (kIsWeb) 'view': 'summary',
        if (canUseAfterCursor) 'after_created_at': newestCreatedAt,
        if (canUseAfterCursor) 'after_id': newestMessageId,
      };
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages',
        queryParameters: query,
        options: Options(
          connectTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final data = resp.data;
      if (data is! Map || data['ok'] != true || data['data'] is! List) return;

      final pageMessages = List<Map<String, dynamic>>.from(data['data'])
        ..sort(_compareByCreatedAt);
      final state = _chatStateMapOf(data['state']);
      final shouldScroll = _isNearBottom();
      final incomingFromOthers = pageMessages.any((message) {
        final normalized = _normalizeMessage(
          Map<String, dynamic>.from(message),
        );
        return !_isOwnMessage(normalized);
      });

      if (pageMessages.isNotEmpty) {
        for (final message in pageMessages) {
          _upsertMessage(Map<String, dynamic>.from(message), autoScroll: false);
        }
        if (shouldScroll) {
          _scrollToBottom(animated: true);
        }
      }

      if (state.isNotEmpty && mounted) {
        setState(() {
          _applyServerChatState(
            state,
            restoreDraft: false,
            restoreScroll: false,
          );
        });
      }
      if (incomingFromOthers) {
        _scheduleReadSync();
      }
    } catch (e, st) {
      unawaited(
        MonitoringService.captureError(
          e,
          st,
          subsystem: 'chat',
          code: 'direct_message_live_sync_failed',
          level: _isTransientMessageLoadError(e) ? 'warn' : 'error',
          details: <String, dynamic>{'chat_id': widget.chatId},
        ),
      );
    } finally {
      _directMessageLiveSyncInFlight = false;
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
      nextMessages[index] = {...message, 'meta': nextMeta};
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

  void _scheduleMessageAppearanceClear(String messageId) {
    if (messageId.isEmpty) return;
    Future.delayed(const Duration(milliseconds: 780), () {
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
    final shouldScroll =
        _isPublicationLiveSyncChannel() || _isNearBottom() || fromMe;
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
    _readDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_markChatAsRead());
    });
  }

  bool _shouldReadWholeOpenChat() {
    return _isDirectMessageChat() ||
        _isSupportTicketChat() ||
        _isReservedOrdersChat() ||
        _isBugReportsChat();
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
    final pinKey = (_activePin?['message_id'] ?? '').toString();
    final reducedMotion =
        performanceModeNotifier.value ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    return GestureDetector(
      onTap: _jumpToPinnedMessage,
      child: PhoenixSlideFadeIn(
        key: ValueKey('active-pin-$pinKey'),
        enabled: !reducedMotion,
        beginOffset: const Offset(0, -14),
        duration: const Duration(milliseconds: 260),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.22),
            ),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.07),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
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
      ),
    );
  }

  bool _isMessagePinned(String messageId) {
    final pin = _activePin;
    if (pin == null) return false;
    return (pin['message_id'] ?? '').toString() == messageId;
  }

  Key _messageKeyFor(String messageId) {
    // Search navigation uses approximate offsets; keeping GlobalKeys for every
    // message made large chats expensive and could trigger inherited-widget
    // disposal assertions during rapid search/exit.
    return ValueKey<String>('message-$messageId');
  }

  Future<bool> _approximateScrollToMessageId(
    String messageId, {
    Duration duration = const Duration(milliseconds: 220),
    Curve curve = Curves.easeOutCubic,
  }) async {
    if (!_scrollController.hasClients) return false;
    final visibleMessages = _visibleMessages();
    if (visibleMessages.isEmpty) return false;
    final targetIndex = visibleMessages.indexWhere(
      (message) => (message['id'] ?? '').toString().trim() == messageId,
    );
    if (targetIndex < 0) return false;
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (targetIndex <= 0 || maxExtent <= 0 || visibleMessages.length <= 1) {
      final clamped = 0.0.clamp(0.0, maxExtent).toDouble();
      if (duration == Duration.zero) {
        _scrollController.jumpTo(clamped);
      } else {
        await _scrollController.animateTo(
          clamped,
          duration: duration,
          curve: curve,
        );
      }
      return true;
    }
    final ratio = targetIndex / (visibleMessages.length - 1);
    final targetPixels = (maxExtent * ratio).clamp(0.0, maxExtent).toDouble();
    if (duration == Duration.zero) {
      _scrollController.jumpTo(targetPixels);
    } else {
      await _scrollController.animateTo(
        targetPixels,
        duration: duration,
        curve: curve,
      );
    }
    return true;
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
        final top = _renderBoxTopInViewport(itemObject, viewportObject);
        if (top == null) continue;
        builtAnchors.add((index: builtIndex, top: top));
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
    if (!mounted) {
      _jumpedToFirstUnread = true;
    } else {
      setState(() => _jumpedToFirstUnread = true);
    }
    await _jumpToMessageById(messageId);
  }

  Future<void> _jumpToMessageById(String messageId) async {
    final trimmedMessageId = messageId.trim();
    if (trimmedMessageId.isEmpty) return;
    _manualBottomLockSuppressed = true;
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

    if (_useApproximateViewportTracking) {
      var moved = await _approximateScrollToMessageId(trimmedMessageId);
      if (!moved) {
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
            moved = await _approximateScrollToMessageId(trimmedMessageId);
          }
        } catch (_) {}
      }
      if (!moved) {
        showGlobalAppNotice(
          'Не удалось перейти: сообщение недоступно',
          tone: AppNoticeTone.warning,
        );
        return;
      }
      _handleScroll();
      return;
    }

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
          targetContext = await _resolveMessageContextWithScroll(
            trimmedMessageId,
          );
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

  Future<void> _flushReadStateOnExit() async {
    if (_readFlushOnExitInFlight) return;
    _readFlushOnExitInFlight = true;
    try {
      await _markChatAsRead(flushOnExit: true);
    } finally {
      _readFlushOnExitInFlight = false;
    }
  }

  Future<bool> _handleWillPop() async {
    if (_unreadCount > 0) {
      await _flushReadStateOnExit();
    }
    return true;
  }

  Future<void> _markChatAsRead({bool flushOnExit = false}) async {
    if (_readSyncInFlight) {
      _readSyncPending = true;
      return;
    }
    final readWholeChat = _shouldReadWholeOpenChat();
    if (!_initialViewportReady && !flushOnExit && !readWholeChat) return;
    if (_messages.isEmpty) return;
    final visibleUntilMessageId = readWholeChat
        ? ''
        : ((_isNearBottom()
                      ? _newestLoadedMessageId
                      : _lastVisibleMessageId()) ??
                  _newestLoadedMessageId ??
                  '')
              .trim();
    if (!readWholeChat && visibleUntilMessageId.isEmpty) {
      return;
    }
    final payload = readWholeChat
        ? const <String, dynamic>{}
        : <String, dynamic>{'visible_until_message_id': visibleUntilMessageId};
    _readSyncInFlight = true;
    try {
      final resp = await authService.dio.post(
        '/api/chats/${widget.chatId}/read',
        data: payload,
      );
      final data = resp.data;
      if (data is Map && data['data'] is Map) {
        final resultData = Map<String, dynamic>.from(data['data'] as Map);
        final ids = ((resultData['message_ids'] ?? const []) as List)
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toSet();
        final unreadCount =
            int.tryParse('${resultData['unread_count'] ?? 0}') ?? 0;
        _applyReadState(ids, readByMe: true);
        if (!mounted) {
          _firstUnreadMessageId = unreadCount <= 0
              ? null
              : _firstUnreadMessageId;
          _unreadCount = unreadCount;
          _jumpedToFirstUnread = false;
        } else {
          setState(() {
            _firstUnreadMessageId = unreadCount <= 0
                ? null
                : _firstUnreadMessageId;
            _unreadCount = unreadCount;
            _jumpedToFirstUnread = false;
          });
        }
        chatEventsController.add({
          'type': 'chat:message:read',
          'data': {
            'chatId': widget.chatId,
            'chat_id': widget.chatId,
            'unread_count': unreadCount,
          },
        });
        if (unreadCount > 0) {
          unawaited(_loadServerChatState());
        }
      }
    } catch (e, st) {
      debugPrint('markChatAsRead failed: $e');
      unawaited(
        MonitoringService.captureError(
          e,
          st,
          subsystem: 'chat',
          code: 'chat_mark_read_failed',
          level: 'warn',
          details: <String, dynamic>{
            'chat_id': widget.chatId,
            'read_whole_chat': readWholeChat,
            'flush_on_exit': flushOnExit,
          },
        ),
      );
    } finally {
      _readSyncInFlight = false;
      if (_readSyncPending) {
        _readSyncPending = false;
        if (mounted) {
          _scheduleReadSync();
        }
      }
    }
  }

  void _enqueueIncomingMessage(Map<String, dynamic> msg, {String action = ''}) {
    _clearRemoteTypingUser(
      (msg['sender_id'] ?? msg['senderId'] ?? '').toString(),
    );
    if (_isHiddenForAll(msg)) {
      final messageId = msg['id']?.toString() ?? '';
      if (messageId.isNotEmpty) {
        _removeMessageLocally(messageId);
      }
      return;
    }

    if (_isDirectMessageChat()) {
      final fromMe = _isOwnMessage(msg);
      final shouldScroll = _isNearBottom() || fromMe;
      _upsertMessage(msg, autoScroll: shouldScroll);
      if (!fromMe) {
        _scheduleReadSync();
      }
      return;
    }

    // Server publication is already sequential. Keeping channel messages in a
    // client-side queue can make an open channel look stale until a full reload.
    if (_shouldApplyChannelRealtimeImmediately(msg, action: action)) {
      final fromMe = _isOwnMessage(msg);
      final normalizedAction = action.trim().toLowerCase();
      final shouldScroll =
          (_isPublicationLiveSyncChannel() &&
              normalizedAction == 'message_published' &&
              (_isNearBottom() ||
                  (_stickToBottom && !_manualBottomLockSuppressed))) ||
          _isNearBottom() ||
          fromMe;
      _upsertMessage(msg, autoScroll: shouldScroll);
      _startChannelPublicationLiveSync(resetWindow: true);
      if (_isPublicationLiveSyncChannel()) {
        _scheduleChannelPublicationImmediateSync(forceLatest: true);
        if (shouldScroll) {
          _forceChannelPublicationViewportToLatest(animated: true);
        }
      }
      if (!fromMe) {
        _scheduleReadSync();
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

  bool _shouldApplyChannelRealtimeImmediately(
    Map<String, dynamic> msg, {
    required String action,
  }) {
    if (!_isChannelChat() && !_isPublicationLiveSyncChannel()) return false;
    final normalizedAction = action.trim().toLowerCase();
    if (normalizedAction == 'message_hidden') return true;
    if (normalizedAction == 'message_published') return true;
    final type = (msg['type'] ?? '').toString().trim().toLowerCase();
    final meta = _metaMapOf(msg['meta']);
    final kind = (meta['kind'] ?? meta['message_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return type == 'product' ||
        kind == 'product' ||
        kind == 'product_card' ||
        meta['product_id'] != null;
  }

  bool _isHiddenForAll(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final raw = meta['hidden_for_all'];
    if (raw is bool) return raw;
    final normalized = raw?.toString().toLowerCase().trim() ?? '';
    return normalized == 'true' || normalized == '1';
  }

  bool _isPublicChannel() {
    if (!_isChannelChat()) return false;
    final settings = _effectiveChatSettings();
    final visibility = (settings['visibility'] ?? 'public')
        .toString()
        .toLowerCase()
        .trim();
    return visibility != 'private';
  }

  bool _isChannelChat() {
    final type = (widget.chatType ?? '').toLowerCase().trim();
    final settings = _effectiveChatSettings();
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    if (systemKey == 'main_channel' ||
        kind == 'main_channel' ||
        _flagFrom(settings['is_main_channel']) ||
        _flagFrom(settings['is_post_channel'])) {
      return true;
    }
    final title = _chatTitle.toLowerCase().trim();
    if (title == 'основной' ||
        title == 'основной канал' ||
        title.contains('канал')) {
      return true;
    }
    if (type == 'channel') return true;
    if (type == 'public') return true;
    final visibility = (settings['visibility'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    return visibility == 'public' &&
        !_isReservedOrdersChat() &&
        !_isBugReportsChat() &&
        !_isSupportTicketChat();
  }

  bool _isPublicationLiveSyncChannel() {
    if (!_isChannelChat()) return false;
    if (_isReservedOrdersChat() ||
        _isBugReportsChat() ||
        _isSupportTicketChat()) {
      return false;
    }
    final settings = _effectiveChatSettings();
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    const excludedKinds = <String>{
      'reserved_orders',
      'bug_reports',
      'support_ticket',
      'system',
      'system_chat',
      'system_channel',
    };
    if (excludedKinds.contains(systemKey) || excludedKinds.contains(kind)) {
      return false;
    }
    final type = (widget.chatType ?? '').toLowerCase().trim();
    final title = _chatTitle.toLowerCase().trim();
    final explicitlyMain =
        systemKey == 'main_channel' ||
        kind == 'main_channel' ||
        _flagFrom(settings['is_main_channel']) ||
        _flagFrom(settings['is_post_channel']) ||
        title == 'основной' ||
        title == 'основной канал';
    if (explicitlyMain) return true;

    // Existing tenants can have the main sales channel renamed and without the
    // newer settings flags. For realtime publication, any regular channel must
    // be able to merge freshly published messages while it is already open.
    final visibility = (settings['visibility'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    return type == 'channel' ||
        type == 'public' ||
        visibility == 'public' ||
        title.contains('канал');
  }

  bool _isSupportTicketChat() {
    final settings = _effectiveChatSettings();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    return kind == 'support_ticket' || settings['support_ticket'] == true;
  }

  bool _isArchivedSupportTicketChat() {
    if (!_isSupportTicketChat()) return false;
    final settings = _effectiveChatSettings();
    if (settings['support_archived'] == true) return true;
    final status = (settings['support_ticket_status'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    return status == 'archived';
  }

  String _supportTicketStatusLabel() {
    final settings = _effectiveChatSettings();
    return messengerSupportStatusLabel(
      (settings['support_ticket_status'] ?? '').toString(),
      hasAssignee: _supportTicketAssigneeName().isNotEmpty,
    );
  }

  String _supportTicketAssigneeName() {
    final settings = _effectiveChatSettings();
    return (settings['support_assignee_name'] ?? '').toString().trim();
  }

  bool _supportTicketWaitingCustomer() {
    final settings = _effectiveChatSettings();
    final raw = settings['support_waiting_customer'];
    if (raw is bool) return raw;
    final normalized = raw?.toString().trim().toLowerCase() ?? '';
    return normalized == 'true' || normalized == '1';
  }

  ({Color background, Color foreground, Color border, IconData icon})
  _supportBannerPalette(String statusRaw, ThemeData theme) {
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
    final statusRaw = ((_effectiveChatSettings()['support_ticket_status'] ?? '')
        .toString()
        .trim()
        .toLowerCase());
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

    final bannerKey =
        '$statusRaw|$assigneeName|${_supportTicketWaitingCustomer()}';
    final reducedMotion =
        performanceModeNotifier.value ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    final content = Container(
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
                  Wrap(spacing: 8, runSpacing: 8, children: chips),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return PhoenixSlideFadeIn(
      key: ValueKey('support-handoff-$bannerKey'),
      enabled: !reducedMotion,
      beginOffset: const Offset(0, -10),
      duration: const Duration(milliseconds: 260),
      child: PhoenixOneShotHighlight(
        enabled: !reducedMotion,
        color: foreground,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        duration: const Duration(milliseconds: 720),
        child: content,
      ),
    );
  }

  Widget _buildDirectRequestBanner() {
    if (!_isDirectMessageChat()) return const SizedBox.shrink();
    final status = _directRequestStatus();
    if (status != 'pending') return const SizedBox.shrink();
    final theme = Theme.of(context);
    final peer = _contactCard?['peer'];
    final inContacts = peer is Map ? _flagFrom(peer['is_in_contacts']) : false;
    final title = _isPendingDirectRequestForMe()
        ? 'Запрос на переписку'
        : 'Запрос отправлен';
    final body = _isPendingDirectRequestForMe()
        ? 'Незнакомый контакт написал первым. Примите запрос, отклоните его или сразу добавьте человека в контакты.'
        : _directRequestFirstMessageSent()
        ? 'Первое сообщение уже отправлено. Дальше чат разблокируется после принятия запроса.'
        : 'Можно отправить первое сообщение. После этого чат дождётся принятия запроса.';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.secondary.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.mark_email_unread_outlined,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isPendingDirectRequestForMe()) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _respondToDirectRequest('accept'),
                  child: const Text('Принять'),
                ),
                OutlinedButton(
                  onPressed: () => _respondToDirectRequest('decline'),
                  child: const Text('Отклонить'),
                ),
                OutlinedButton(
                  onPressed: inContacts ? null : _addPeerToContactsFromCard,
                  child: Text(
                    inContacts ? 'Уже в контактах' : 'Добавить в контакты',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _isDirectMessageChat() {
    if (_isSupportTicketChat()) return false;
    final settings = _effectiveChatSettings();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    final savedMessages =
        settings['saved_messages'] == true || kind == 'saved_messages';
    if (savedMessages) return false;
    if (kind == 'direct_message') return true;
    if (kind.isNotEmpty) return false;
    final type = (widget.chatType ?? '').toLowerCase().trim();
    if (type == 'private') return true;
    final visibility = (settings['visibility'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (type.isEmpty && visibility == 'private') return true;
    final peer = _contactCard?['peer'];
    return peer is Map &&
        (peer['id'] ?? peer['contact_user_id'] ?? '')
            .toString()
            .trim()
            .isNotEmpty;
  }

  bool _canCompose() {
    if (_isArchivedSupportTicketChat()) {
      return false;
    }
    if (_isPendingDirectRequestForMe()) {
      return false;
    }
    if (_isPendingDirectRequestFromMe() && _directRequestFirstMessageSent()) {
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
    if (_isPendingDirectRequestForMe()) {
      return 'Сначала примите запрос на переписку или отклоните его.';
    }
    if (_isPendingDirectRequestFromMe() && _directRequestFirstMessageSent()) {
      return 'Запрос отправлен. Дальше можно писать после принятия собеседником.';
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
      final activeSocket = socket;
      if (activeSocket == null || !activeSocket.connected) {
        _channelLiveLog('join_chat skipped: socket not connected', {
          'socket_exists': activeSocket != null,
          'socket_connected': activeSocket?.connected == true,
        });
        return;
      }
      _channelLiveLog('join_chat emit', {'socket_id': activeSocket.id});
      activeSocket.emit('join_chat', widget.chatId);
    } catch (e, st) {
      _channelLiveLog('join_chat error', {'error': e.toString()});
      unawaited(
        MonitoringService.captureError(
          e,
          st,
          subsystem: 'realtime',
          code: 'chat_room_join_emit_failed',
          details: <String, dynamic>{'chat_id': widget.chatId},
        ),
      );
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
    final isPublicationChannel = _isPublicationLiveSyncChannel();
    final wasNearBottomBeforeLoad = _isNearBottom();
    final shouldKeepPublicationAtBottom =
        showLoader ||
        wasNearBottomBeforeLoad ||
        (_stickToBottom && !_manualBottomLockSuppressed);
    final existingIdsBeforeLoad = isPublicationChannel
        ? _messages.map(_messageIdOf).where((id) => id.isNotEmpty).toSet()
        : <String>{};
    var appearingIdsFromLoad = <String>[];
    if (isPublicationChannel) {
      _channelLiveLog('loadMessages start', {
        'show_loader': showLoader,
        'messages_before': _messages.length,
        'was_near_bottom': wasNearBottomBeforeLoad,
        'stick_to_bottom': _stickToBottom,
        'manual_bottom_lock_suppressed': _manualBottomLockSuppressed,
        'should_keep_at_bottom': shouldKeepPublicationAtBottom,
      });
    }
    if (mounted && showLoader) {
      setState(() => _loading = true);
    }
    try {
      const maxAttempts = 3;
      Object? lastError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          final initialLimit = kIsWeb ? 60 : 80;
          final resp = await authService.dio.get(
            '/api/chats/${widget.chatId}/messages',
            queryParameters: <String, dynamic>{
              'limit': initialLimit,
              if (kIsWeb) 'view': 'summary',
              if (kIsWeb) '_ts': DateTime.now().millisecondsSinceEpoch,
            },
            options: Options(
              headers: kIsWeb
                  ? const {
                      'Cache-Control': 'no-cache, no-store, must-revalidate',
                      'Pragma': 'no-cache',
                      'Expires': '0',
                    }
                  : null,
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );
          final data = resp.data;
          if (data is Map && data['ok'] == true && data['data'] is List) {
            final serverMessages = List<Map<String, dynamic>>.from(data['data'])
              ..sort(_compareByCreatedAt);
            if (isPublicationChannel) {
              _channelLiveLog('loadMessages response', {
                'attempt': attempt,
                'server_count': serverMessages.length,
                'first_id': serverMessages.isEmpty
                    ? null
                    : _messageIdOf(serverMessages.first),
                'last_id': serverMessages.isEmpty
                    ? null
                    : _messageIdOf(serverMessages.last),
                'last_created_at': serverMessages.isEmpty
                    ? null
                    : (serverMessages.last['created_at'] ?? '').toString(),
                'paging': data['paging'],
                'state': data['state'],
              });
            }
            final messages = _mergeServerMessagesWithLocalState(serverMessages);
            final messageIdsAfterLoad = messages
                .map(_messageIdOf)
                .where((id) => id.isNotEmpty)
                .toSet();
            appearingIdsFromLoad = isPublicationChannel && !showLoader
                ? messageIdsAfterLoad
                      .where((id) => !existingIdsBeforeLoad.contains(id))
                      .toList()
                : <String>[];
            final paging = _chatStateMapOf(data['paging']);
            final state = _chatStateMapOf(data['state']);
            if (mounted) {
              setState(() {
                _messages = messages;
                _incomingQueue.clear();
                if (!isPublicationChannel || showLoader) {
                  _appearingMessageIds.clear();
                } else {
                  _appearingMessageIds.removeWhere(
                    (id) => !messageIdsAfterLoad.contains(id),
                  );
                  _appearingMessageIds.addAll(appearingIdsFromLoad);
                }
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
                _applyServerChatState(
                  state,
                  restoreDraft: false,
                  restoreScroll: !isPublicationChannel,
                );
                _refreshLoadedMessageBounds();
              });
            } else {
              _messages = messages;
              _hasMoreBefore = paging['has_more_before'] == true;
              _applyServerChatState(
                state,
                restoreDraft: false,
                restoreScroll: !isPublicationChannel,
              );
              _refreshLoadedMessageBounds();
            }
            _incomingTimer?.cancel();
            _incomingTimer = null;
            _recomputeSearchResults(keepCurrent: false);
            if (kIsWeb) {
              unawaited(
                primeWebImageCache(_initialChannelImageBatch(messages)),
              );
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
          if (isPublicationChannel) {
            _channelLiveLog('loadMessages attempt failed', {
              'attempt': attempt,
              'error': e.toString(),
            });
          }
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
        if (isPublicationChannel) {
          _channelLiveLog('loadMessages failed after retries', {
            'error': lastError.toString(),
          });
        }
        debugPrint('Error loading messages: $lastError');
        unawaited(
          MonitoringService.captureError(
            lastError,
            null,
            subsystem: 'chat',
            code: 'chat_messages_load_failed',
            level: _isTransientMessageLoadError(lastError) ? 'warn' : 'error',
            details: <String, dynamic>{
              'chat_id': widget.chatId,
              'transient': _isTransientMessageLoadError(lastError),
            },
          ),
        );
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
        if (isPublicationChannel) {
          _channelLiveLog('loadMessages success applied', {
            'messages_after': _messages.length,
            'has_more_before': _hasMoreBefore,
            'appearing_count': appearingIdsFromLoad.length,
            'should_keep_at_bottom': shouldKeepPublicationAtBottom,
          });
          _initialViewportApplied = true;
          _initialViewportFailsafeTimer?.cancel();
          _markInitialViewportReady();
          for (final id in appearingIdsFromLoad) {
            _scheduleMessageAppearanceClear(id);
          }
          _startChannelPublicationLiveSync(
            resetWindow: showLoader || appearingIdsFromLoad.isNotEmpty,
          );
          if (shouldKeepPublicationAtBottom) {
            _forceChannelPublicationViewportToLatest(
              animated: false,
              respectUserScroll: !showLoader,
            );
          }
        } else {
          _applyInitialViewportAfterLoad();
        }
        if (_shouldReadWholeOpenChat()) {
          _scheduleReadSync();
        }
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
    final viewportAnchor = hadClients ? _currentScrollAnchor() : null;
    try {
      final olderLimit = kIsWeb ? 45 : 60;
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages',
        queryParameters: {
          'before_created_at': _oldestLoadedCreatedAt,
          'before_id': _oldestLoadedMessageId,
          'limit': olderLimit,
          if (kIsWeb) 'view': 'summary',
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
            _applyServerChatState(
              state,
              restoreDraft: false,
              restoreScroll: false,
            );
          });
        } else {
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(
            state,
            restoreDraft: false,
            restoreScroll: false,
          );
        }
        return;
      }
      final existingIds = _messages
          .map(_messageIdOf)
          .where((id) => id.isNotEmpty)
          .toSet();
      final toInsert = pageMessages
          .where((message) => !existingIds.contains(_messageIdOf(message)))
          .toList(growable: false);
      if (toInsert.isEmpty) {
        if (mounted) {
          setState(() {
            _hasMoreBefore = paging['has_more_before'] == true;
            _applyServerChatState(
              state,
              restoreDraft: false,
              restoreScroll: false,
            );
          });
        } else {
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(
            state,
            restoreDraft: false,
            restoreScroll: false,
          );
        }
        return;
      }
      if (mounted) {
        setState(() {
          _messages = _dedupeMessages([...toInsert, ..._messages]);
          _hasMoreBefore = paging['has_more_before'] == true;
          _applyServerChatState(
            state,
            restoreDraft: false,
            restoreScroll: false,
          );
          _messageIds
            ..clear()
            ..addAll(_messages.map(_messageIdOf).where((id) => id.isNotEmpty));
          _refreshLoadedMessageBounds();
        });
      } else {
        _messages = _dedupeMessages([...toInsert, ..._messages]);
        _hasMoreBefore = paging['has_more_before'] == true;
        _applyServerChatState(state, restoreDraft: false, restoreScroll: false);
        _refreshLoadedMessageBounds();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _restoreViewportAfterPrepending(
          previousPixels: previousPixels,
          previousMaxExtent: previousMaxExtent,
          viewportAnchor: viewportAnchor,
          passes: 3,
        );
      });
    } catch (_) {
      // ignore transient older-page failures
    } finally {
      _loadingOlderMessages = false;
    }
  }

  void _restoreViewportAfterPrepending({
    required double previousPixels,
    required double previousMaxExtent,
    ({String messageId, double offset})? viewportAnchor,
    int passes = 2,
  }) {
    if (!mounted || !_scrollController.hasClients) return;

    void fallbackToDelta() {
      if (!mounted || !_scrollController.hasClients) return;
      final nextMaxExtent = _scrollController.position.maxScrollExtent;
      final delta = nextMaxExtent - previousMaxExtent;
      final target = (previousPixels + max(0.0, delta))
          .clamp(0.0, nextMaxExtent)
          .toDouble();
      _scrollController.jumpTo(target);
      _handleScroll();
    }

    final anchorId = viewportAnchor?.messageId.trim() ?? '';
    if (anchorId.isEmpty) {
      fallbackToDelta();
      return;
    }

    final viewportContext = _messagesViewportKey.currentContext;
    final viewportObject = viewportContext?.findRenderObject();
    final targetContext = _messageItemKeys[anchorId]?.currentContext;
    final targetObject = targetContext?.findRenderObject();
    final canUseAnchor =
        viewportObject is RenderBox &&
        targetObject is RenderBox &&
        targetObject.hasSize &&
        targetContext != null &&
        targetContext.mounted;

    if (!canUseAnchor) {
      if (passes <= 1) {
        fallbackToDelta();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreViewportAfterPrepending(
          previousPixels: previousPixels,
          previousMaxExtent: previousMaxExtent,
          viewportAnchor: viewportAnchor,
          passes: passes - 1,
        );
      });
      return;
    }

    final currentTop = _renderBoxTopInViewport(targetObject, viewportObject);
    if (currentTop == null) {
      if (passes <= 1) {
        fallbackToDelta();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreViewportAfterPrepending(
          previousPixels: previousPixels,
          previousMaxExtent: previousMaxExtent,
          viewportAnchor: viewportAnchor,
          passes: passes - 1,
        );
      });
      return;
    }
    final correction = currentTop - viewportAnchor!.offset;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final nextOffset = (_scrollController.offset + correction)
        .clamp(0.0, maxExtent)
        .toDouble();
    _scrollController.jumpTo(nextOffset);
    _handleScroll();
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
      final newerLimit = kIsWeb ? 60 : 80;
      final resp = await authService.dio.get(
        '/api/chats/${widget.chatId}/messages',
        queryParameters: {
          'after_created_at': newestCreatedAt,
          'after_id': newestId,
          'limit': newerLimit,
          if (kIsWeb) 'view': 'summary',
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
      final wasNearBottom = _isNearBottom();
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
          _applyServerChatState(
            state,
            restoreDraft: false,
            restoreScroll: false,
          );
          _messageIds
            ..clear()
            ..addAll(_messages.map(_messageIdOf).where((id) => id.isNotEmpty));
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
      if (pageMessages.isNotEmpty) {
        unawaited(
          MonitoringService.captureEvent(
            subsystem: 'realtime',
            code: 'replay_fallback_used',
            level: 'info',
            message: 'Replay fallback restored messages after reconnect',
            details: <String, dynamic>{
              'chat_id': widget.chatId,
              'restored_count': pageMessages.length,
            },
          ),
        );
      }
      _recomputeSearchResults();
      if (pageMessages.isNotEmpty && wasNearBottom) {
        _scrollToBottom(animated: true);
      }
      if (wasNearBottom) {
        _scheduleReadSync();
      }
    } catch (e, st) {
      unawaited(
        MonitoringService.captureError(
          e,
          st,
          subsystem: 'realtime',
          code: 'replay_fallback_failed',
          level: 'warn',
          details: <String, dynamic>{'chat_id': widget.chatId},
        ),
      );
      // ignore replay issues; next socket/API refresh will recover
    } finally {
      _loadingNewerMessages = false;
    }
  }

  void _scheduleRealtimeChatRefresh({String reason = 'realtime_update'}) {
    if (!mounted) return;
    if (_isPublicationLiveSyncChannel()) {
      _scheduleChannelPublicationImmediateSync(forceLatest: true);
      return;
    }
    final delay = reason.trim() == 'chat_updated'
        ? const Duration(milliseconds: 220)
        : const Duration(milliseconds: 280);
    _realtimeChatRefreshTimer?.cancel();
    _realtimeChatRefreshTimer = Timer(delay, () {
      if (!mounted) return;
      if (_loadingNewerMessages || _messagesLoadInFlight) {
        _scheduleRealtimeChatRefresh(reason: reason);
        return;
      }
      unawaited(_replayMissedMessagesAfterReconnect());
    });
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
    final messagesSnapshot = List<Map<String, dynamic>>.from(_messages);
    final entries = <ChatMediaViewerEntry>[];
    for (final item in messagesSnapshot) {
      final meta = _metaMapOf(item['meta']);
      final imageUrl = _resolveImageUrl(meta['image_url']?.toString());
      if (imageUrl == null || imageUrl.isEmpty) continue;
      if (_isHiddenForAll(item)) continue;
      entries.add(
        ChatMediaViewerEntry(
          id: _mediaViewerEntryIdForMessage(item, fallbackImageUrl: imageUrl),
          imageUrl: imageUrl,
          caption: _captionTextOf(item, meta),
          senderName: _senderNameOf(item),
          timeLabel: _formatMessageTime(item['created_at']),
        ),
      );
    }
    return entries;
  }

  String _mediaViewerEntryIdForMessage(
    Map<String, dynamic> message, {
    String? fallbackImageUrl,
  }) {
    final messageId = _messageIdOf(message).trim();
    if (messageId.isNotEmpty) return messageId;
    final clientMessageId = (message['client_msg_id'] ?? '').toString().trim();
    final createdAt = (message['created_at'] ?? '').toString().trim();
    final imageToken = (fallbackImageUrl ?? '').trim();
    if (clientMessageId.isNotEmpty ||
        createdAt.isNotEmpty ||
        imageToken.isNotEmpty) {
      return '$clientMessageId|$createdAt|$imageToken';
    }
    return 'fallback-${identityHashCode(message)}';
  }

  Future<void> _openImagePreviewForMessage(
    Map<String, dynamic> message,
    String imageUrl,
  ) async {
    final targetEntryId = _mediaViewerEntryIdForMessage(
      message,
      fallbackImageUrl: imageUrl,
    );
    final singleEntry = ChatMediaViewerEntry(
      id: targetEntryId,
      imageUrl: imageUrl,
      caption: _captionTextOf(message, _metaMapOf(message['meta'])),
      senderName: _senderNameOf(message),
      timeLabel: _formatMessageTime(message['created_at']),
    );
    final gallery = _chatMediaViewerEntries();
    if (gallery.isEmpty) {
      await showChatMediaViewer(
        context,
        entries: <ChatMediaViewerEntry>[singleEntry],
      );
      return;
    }

    final initialIndex = gallery.indexWhere(
      (entry) => entry.id == targetEntryId,
    );
    if (initialIndex < 0) {
      await showChatMediaViewer(
        context,
        entries: <ChatMediaViewerEntry>[singleEntry],
      );
      return;
    }

    await showChatMediaViewer(
      context,
      entries: gallery,
      initialIndex: initialIndex,
    );
  }

  bool get _cameraSupported {
    return _captureProfile.cameraSupported;
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

  bool get _isWifiLikeConnection =>
      _connectivityResults.contains(ConnectivityResult.wifi) ||
      _connectivityResults.contains(ConnectivityResult.ethernet);

  String _autoDownloadPolicyForKind(String kind) {
    switch (kind) {
      case 'audio':
        return _messengerPrefs.mediaAutoDownloadAudio;
      case 'video':
        return _messengerPrefs.mediaAutoDownloadVideo;
      case 'document':
        return _messengerPrefs.mediaAutoDownloadDocuments;
      case 'image':
      default:
        return _messengerPrefs.mediaAutoDownloadImages;
    }
  }

  bool _allowsAutoDownloadPolicy(String policy) {
    switch (policy.trim().toLowerCase()) {
      case 'never':
        return false;
      case 'wifi':
        return _isWifiLikeConnection;
      case 'wifi_cellular':
      default:
        return true;
    }
  }

  String _mediaLoadKey(
    Map<String, dynamic> message, {
    required String kind,
    String? fallbackToken,
  }) {
    final messageId = _messageIdOf(message).trim();
    if (messageId.isNotEmpty) return '$kind:$messageId';
    final clientMsgId = (message['client_msg_id'] ?? '').toString().trim();
    if (clientMsgId.isNotEmpty) return '$kind:$clientMsgId';
    final token = (fallbackToken ?? '').trim();
    if (token.isNotEmpty) return '$kind:$token';
    return '$kind:${identityHashCode(message)}';
  }

  bool _canAutoLoadMedia(
    Map<String, dynamic> message, {
    required String kind,
    String? fallbackToken,
  }) {
    final key = _mediaLoadKey(
      message,
      kind: kind,
      fallbackToken: fallbackToken,
    );
    return _manualMediaLoads.contains(key) ||
        _allowsAutoDownloadPolicy(_autoDownloadPolicyForKind(kind));
  }

  void _allowManualMediaLoad(
    Map<String, dynamic> message, {
    required String kind,
    String? fallbackToken,
  }) {
    final key = _mediaLoadKey(
      message,
      kind: kind,
      fallbackToken: fallbackToken,
    );
    if (_manualMediaLoads.contains(key)) return;
    if (!mounted) {
      _manualMediaLoads.add(key);
      return;
    }
    setState(() => _manualMediaLoads.add(key));
  }

  Future<void> _loadMessengerPreferences() async {
    try {
      final prefs = await messengerPreferencesService.load();
      if (!mounted) {
        _messengerPrefs = prefs;
        return;
      }
      setState(() => _messengerPrefs = prefs);
    } catch (_) {}
  }

  Future<void> _refreshConnectivityState() async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (!mounted) {
        _connectivityResults = List<ConnectivityResult>.from(results);
        return;
      }
      setState(() {
        _connectivityResults = List<ConnectivityResult>.from(results);
      });
    } catch (_) {}
  }

  Future<String> _recommendedMediaQualityMode() async {
    try {
      final prefs = await messengerPreferencesService.load();
      final connectivity = await _connectivity.checkConnectivity();
      final onWifi =
          connectivity.contains(ConnectivityResult.wifi) ||
          connectivity.contains(ConnectivityResult.ethernet);
      final quality = onWifi
          ? prefs.mediaSendQualityWifi
          : prefs.mediaSendQualityCellular;
      final normalized = quality.trim().toLowerCase();
      if (normalized == 'hd' || normalized == 'file') return normalized;
      return 'standard';
    } catch (_) {
      return 'standard';
    }
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
    if (text.contains('missingplugin') ||
        text.contains('no implementation found')) {
      return 'камера недоступна в этой сборке приложения';
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

  String? _guessMimeTypeFromFilename(String filename) {
    final lower = filename.trim().toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic')) return 'image/heic';
    if (lower.endsWith('.heif')) return 'image/heif';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.opus')) return 'audio/ogg';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.m4v')) return 'video/x-m4v';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.zip')) return 'application/zip';
    return null;
  }

  Future<_ChatUploadFile?> _pickRawImageUpload(ImageSource source) async {
    if (kIsWeb ||
        (source == ImageSource.gallery && _preferFilePickerForImages)) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      final picked = result?.files.single;
      if (picked == null) return null;
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) return null;
      return _ChatUploadFile(
        filename: picked.name.isNotEmpty ? picked.name : 'image.jpg',
        path: picked.path,
        bytes: bytes,
        mimeType: _guessMimeTypeFromFilename(picked.name),
        fileSize: picked.size,
      );
    }

    final picked = await _imagePicker.pickImage(source: source);
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return null;
    return _ChatUploadFile(
      filename: picked.name.isNotEmpty
          ? picked.name
          : picked.path.split('/').last,
      path: picked.path.trim().isNotEmpty ? picked.path : null,
      bytes: bytes,
      mimeType: (picked.mimeType ?? '').trim().isNotEmpty == true
          ? picked.mimeType!.trim()
          : _guessMimeTypeFromFilename(
              picked.name.isNotEmpty
                  ? picked.name
                  : picked.path.split('/').last,
            ),
      fileSize: bytes.length,
    );
  }

  Future<_ImageSendMode> _recommendedImageSendMode() async {
    try {
      final prefs = await messengerPreferencesService.load();
      final connectivity = await Connectivity().checkConnectivity();
      final onWifi =
          connectivity.contains(ConnectivityResult.wifi) ||
          connectivity.contains(ConnectivityResult.ethernet);
      final quality = onWifi
          ? prefs.mediaSendQualityWifi
          : prefs.mediaSendQualityCellular;
      switch (quality) {
        case 'file':
          return _ImageSendMode.file;
        case 'hd':
          return _ImageSendMode.hd;
        case 'standard':
        default:
          return _ImageSendMode.standard;
      }
    } catch (_) {
      return _ImageSendMode.standard;
    }
  }

  Future<_ImageSendMode?> _promptImageSendMode(
    _ImageSendMode recommended,
  ) async {
    if (!mounted) return null;
    final orderedModes = <_ImageSendMode>[
      recommended,
      ..._ImageSendMode.values.where((mode) => mode != recommended),
    ];

    String titleFor(_ImageSendMode mode) {
      switch (mode) {
        case _ImageSendMode.standard:
          return 'Стандарт';
        case _ImageSendMode.hd:
          return 'HD';
        case _ImageSendMode.file:
          return 'Как файл';
      }
    }

    String subtitleFor(_ImageSendMode mode) {
      final suffix = mode == recommended
          ? ' • рекомендовано для текущей сети'
          : '';
      switch (mode) {
        case _ImageSendMode.standard:
          return 'Сжать и отправить как обычное фото$suffix';
        case _ImageSendMode.hd:
          return 'Лучше качество, файл будет тяжелее$suffix';
        case _ImageSendMode.file:
          return 'Без сжатия, как документ$suffix';
      }
    }

    IconData iconFor(_ImageSendMode mode) {
      switch (mode) {
        case _ImageSendMode.standard:
          return Icons.photo_outlined;
        case _ImageSendMode.hd:
          return Icons.hd_outlined;
        case _ImageSendMode.file:
          return Icons.insert_drive_file_outlined;
      }
    }

    return showModalBottomSheet<_ImageSendMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: orderedModes
              .map(
                (mode) => ListTile(
                  leading: Icon(iconFor(mode)),
                  title: Text(titleFor(mode)),
                  subtitle: Text(subtitleFor(mode)),
                  onTap: () => Navigator.of(ctx).pop(mode),
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  Future<_ChatUploadFile?> _prepareImageUploadForMode(
    _ChatUploadFile rawUpload,
    _ImageSendMode mode,
  ) async {
    if (mode == _ImageSendMode.file) {
      return _ChatUploadFile(
        filename: rawUpload.filename,
        path: rawUpload.path,
        bytes: rawUpload.bytes,
        mimeType:
            rawUpload.mimeType ??
            _guessMimeTypeFromFilename(rawUpload.filename),
        fileSize: rawUpload.fileSize ?? rawUpload.bytes?.length,
        qualityMode: 'file',
      );
    }

    Uint8List? bytes = rawUpload.bytes;
    if ((bytes == null || bytes.isEmpty) &&
        !kIsWeb &&
        (rawUpload.path ?? '').trim().isNotEmpty) {
      bytes = Uint8List.fromList(await XFile(rawUpload.path!).readAsBytes());
    }
    if (bytes == null || bytes.isEmpty) return null;

    final preprocessed = await preprocessChatImageForMessage(
      bytes: bytes,
      filename: rawUpload.filename,
      maxSide: mode == _ImageSendMode.hd ? 2400 : 1600,
      jpegQuality: mode == _ImageSendMode.hd ? 94 : 88,
    );
    return _ChatUploadFile(
      filename: preprocessed.filename,
      bytes: preprocessed.bytes,
      mimeType: preprocessed.mimeType,
      fileSize: preprocessed.bytes.length,
      qualityMode: mode == _ImageSendMode.hd ? 'hd' : 'standard',
      width: preprocessed.width,
      height: preprocessed.height,
      preprocessTag: preprocessed.preprocessTag,
    );
  }

  Future<_ChatUploadFile?> _pickVideoUpload({ImageSource? source}) async {
    final shouldUsePicker =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        source == null;
    if (shouldUsePicker) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
        withData: kIsWeb,
      );
      final picked = result?.files.single;
      if (picked == null) return null;
      final bytes = picked.bytes;
      return _ChatUploadFile(
        filename: picked.name.isNotEmpty ? picked.name : 'video.mp4',
        path: (picked.path ?? '').trim().isNotEmpty
            ? picked.path!.trim()
            : null,
        bytes: bytes == null || bytes.isEmpty ? null : bytes,
        mimeType: _guessMimeTypeFromFilename(picked.name),
        fileSize: picked.size,
        qualityMode: await _recommendedMediaQualityMode(),
      );
    }

    final picked = await _imagePicker.pickVideo(source: source);
    if (picked == null) return null;
    final bytes = kIsWeb ? await picked.readAsBytes() : null;
    return _ChatUploadFile(
      filename: picked.name.isNotEmpty
          ? picked.name
          : picked.path.split('/').last,
      path: picked.path.trim().isNotEmpty ? picked.path : null,
      bytes: bytes == null || bytes.isEmpty ? null : bytes,
      mimeType: (picked.mimeType ?? '').trim().isNotEmpty == true
          ? picked.mimeType!.trim()
          : _guessMimeTypeFromFilename(
              picked.name.isNotEmpty
                  ? picked.name
                  : picked.path.split('/').last,
            ),
      fileSize: bytes?.length,
      qualityMode: await _recommendedMediaQualityMode(),
    );
  }

  Future<Uint8List> _readUploadBytes(_ChatUploadFile upload) async {
    final bytes = upload.bytes;
    if (bytes != null && bytes.isNotEmpty) return bytes;
    final path = (upload.path ?? '').trim();
    if (path.isEmpty) {
      throw Exception('Не удалось прочитать файл для отправки');
    }
    final read = await XFile(path).readAsBytes();
    if (read.isEmpty) {
      throw Exception('Файл пустой');
    }
    return Uint8List.fromList(read);
  }

  String _sha256Hex(Uint8List bytes) {
    return crypto.sha256.convert(bytes).toString();
  }

  int _uploadChunkSizeForBytes(int totalBytes) {
    if (totalBytes >= 20 * 1024 * 1024) return 1024 * 1024;
    if (totalBytes >= 5 * 1024 * 1024) return 768 * 1024;
    return 512 * 1024;
  }

  int _nonNegativeIntOf(dynamic value) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse((value ?? '').toString().trim());
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }

  Future<Map<String, dynamic>> _createUploadSession({
    required _ChatUploadFile upload,
    required String attachmentType,
    required String clientMsgId,
    required Uint8List bytes,
    int? durationMs,
    bool isVideoNote = false,
    bool listenOnce = false,
  }) async {
    final response = await authService.dio.post(
      '/api/chats/uploads/sessions',
      data: {
        'chat_id': widget.chatId,
        'client_msg_id': clientMsgId,
        'attachment_kind': attachmentType,
        'quality_mode': (upload.qualityMode ?? '').trim(),
        'original_file_name': upload.filename,
        'mime_type': (upload.mimeType ?? '').trim(),
        'total_bytes': bytes.length,
        'sha256': _sha256Hex(bytes),
        if ((upload.width ?? 0) > 0) 'image_width': upload.width,
        if ((upload.height ?? 0) > 0) 'image_height': upload.height,
        if ((upload.preprocessTag ?? '').trim().isNotEmpty)
          'image_preprocess': upload.preprocessTag,
        if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
        if (isVideoNote) 'is_video_note': true,
        if (listenOnce) 'listen_once': true,
      },
    );
    final data = response.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data'] as Map);
    }
    throw Exception('Не удалось создать upload session');
  }

  Future<Map<String, dynamic>> _appendUploadChunk({
    required String sessionId,
    required Uint8List bytes,
    required int offset,
  }) async {
    final response = await authService.dio.patch(
      '/api/chats/uploads/sessions/$sessionId',
      data: FormData.fromMap({
        'offset': offset,
        'chunk': MultipartFile.fromBytes(
          bytes,
          filename: 'chunk-${offset + bytes.length}.bin',
        ),
      }),
    );
    final data = response.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data'] as Map);
    }
    throw Exception('Не удалось отправить chunk');
  }

  Future<Map<String, dynamic>> _completeUploadSession(String sessionId) async {
    final response = await authService.dio.post(
      '/api/chats/uploads/sessions/$sessionId/complete',
    );
    final data = response.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data'] as Map);
    }
    throw Exception('Не удалось завершить upload session');
  }

  Future<Map<String, dynamic>> _commitUploadSession({
    required String sessionId,
    required String caption,
    required Map<String, dynamic> replyPayload,
  }) async {
    final response = await authService.dio.post(
      '/api/chats/${widget.chatId}/messages/media/commit',
      data: {
        'session_id': sessionId,
        if (caption.trim().isNotEmpty) 'text': caption.trim(),
        ...replyPayload,
      },
    );
    final data = response.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data'] as Map);
    }
    throw Exception('Не удалось опубликовать медиа-сообщение');
  }

  bool _shouldFallbackToLegacyMediaUpload(Object error) {
    if (error is StateError &&
        error.toString().contains('предыдущую загрузку')) {
      return true;
    }
    if (error is DioException) {
      final statusCode = error.response?.statusCode ?? 0;
      if (statusCode == 409) return true;
      if (statusCode >= 500) return true;
    }
    return false;
  }

  Future<void> _postLegacyMediaMessage({
    required _ChatUploadFile upload,
    required Uint8List bytes,
    required String attachmentType,
    required String clientMsgId,
    required String caption,
    required Map<String, dynamic> replyPayload,
    int? durationMs,
    bool isVideoNote = false,
    bool listenOnce = false,
  }) async {
    final fieldName = switch (attachmentType) {
      'image' => 'image',
      'voice' => 'voice',
      'video' => 'video',
      'file' => 'file',
      _ => 'file',
    };
    final form = FormData.fromMap({
      'client_msg_id': clientMsgId,
      if (caption.trim().isNotEmpty) 'text': caption.trim(),
      if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
      if (isVideoNote) 'is_video_note': 'true',
      if (listenOnce) 'listen_once': 'true',
      if ((upload.qualityMode ?? '').trim().isNotEmpty)
        'quality_mode': upload.qualityMode!.trim(),
      if (upload.width != null) 'image_width': upload.width,
      if (upload.height != null) 'image_height': upload.height,
      if ((upload.preprocessTag ?? '').trim().isNotEmpty)
        'image_preprocess': upload.preprocessTag!.trim(),
      ...replyPayload,
      fieldName: MultipartFile.fromBytes(bytes, filename: upload.filename),
    });
    final response = await authService.dio.post(
      '/api/chats/${widget.chatId}/messages/media',
      data: form,
    );
    final data = response.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      _upsertMessage(
        Map<String, dynamic>.from(data['data'] as Map),
        autoScroll: true,
      );
      return;
    }
    throw Exception('Не удалось отправить медиа-сообщение');
  }

  Future<void> _postMediaMessage({
    required _ChatUploadFile upload,
    required String attachmentType,
    required String clientMsgId,
    required String caption,
    required Map<String, dynamic> replyPayload,
    int? durationMs,
    bool isVideoNote = false,
    bool listenOnce = false,
  }) async {
    final bytes = await _readUploadBytes(upload);
    if (attachmentType == 'voice' || isVideoNote) {
      // Voice notes and round videos are short, interactive messages. Keeping
      // them on the simple multipart path avoids resumable-session drift where
      // a message can point at a file that was never finalized.
      await _postLegacyMediaMessage(
        upload: upload,
        bytes: bytes,
        clientMsgId: clientMsgId,
        attachmentType: attachmentType,
        caption: caption,
        replyPayload: replyPayload,
        durationMs: durationMs,
        isVideoNote: isVideoNote,
        listenOnce: listenOnce,
      );
      return;
    }
    try {
      final session = await _createUploadSession(
        upload: upload,
        attachmentType: attachmentType,
        clientMsgId: clientMsgId,
        bytes: bytes,
        durationMs: durationMs,
        isVideoNote: isVideoNote,
        listenOnce: listenOnce,
      );
      final sessionId = (session['id'] ?? '').toString().trim();
      if (sessionId.isEmpty) {
        throw Exception('Сервер не вернул upload session id');
      }
      final sessionStatus = (session['status'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (sessionStatus == 'failed' || sessionStatus == 'failed_permanent') {
        throw StateError('Сервер отклонил предыдущую загрузку файла');
      }
      final sessionStorageUrl = (session['storage_url'] ?? '')
          .toString()
          .trim();
      if (sessionStatus == 'committed' ||
          (sessionStorageUrl.isNotEmpty &&
              (sessionStatus == 'ready' || sessionStatus == 'processing'))) {
        final message = await _commitUploadSession(
          sessionId: sessionId,
          caption: caption,
          replyPayload: replyPayload,
        );
        _upsertMessage(message, autoScroll: true);
        return;
      }
      final chunkSize = _uploadChunkSizeForBytes(bytes.length);
      final uploadedBytes = _nonNegativeIntOf(session['uploaded_bytes']);
      if (uploadedBytes > bytes.length) {
        throw StateError('Upload session size mismatch');
      }
      var offset = uploadedBytes;
      if (offset > 0) {
        final progress = (offset / bytes.length).clamp(0.0, 1.0).toDouble();
        _patchMessageLocally(
          clientMsgId: clientMsgId,
          transform: (current) {
            final nextMeta = _metaMapOf(current['meta']);
            nextMeta['delivery_status'] = progress >= 0.995
                ? 'sending'
                : 'uploading';
            nextMeta['local_upload_progress'] = progress;
            nextMeta.remove('error_message');
            return {...current, 'meta': nextMeta};
          },
        );
      }
      while (offset < bytes.length) {
        final end = math.min(bytes.length, offset + chunkSize);
        final chunk = Uint8List.sublistView(bytes, offset, end);
        await _appendUploadChunk(
          sessionId: sessionId,
          bytes: chunk,
          offset: offset,
        );
        offset = end;
        final progress = (offset / bytes.length).clamp(0.0, 1.0).toDouble();
        _patchMessageLocally(
          clientMsgId: clientMsgId,
          transform: (current) {
            final nextMeta = _metaMapOf(current['meta']);
            nextMeta['delivery_status'] = progress >= 0.995
                ? 'sending'
                : 'uploading';
            nextMeta['local_upload_progress'] = progress;
            nextMeta.remove('error_message');
            return {...current, 'meta': nextMeta};
          },
        );
      }
      await _completeUploadSession(sessionId);
      final message = await _commitUploadSession(
        sessionId: sessionId,
        caption: caption,
        replyPayload: replyPayload,
      );
      _upsertMessage(message, autoScroll: true);
    } catch (e) {
      if (!_shouldFallbackToLegacyMediaUpload(e)) rethrow;
      await _postLegacyMediaMessage(
        upload: upload,
        bytes: bytes,
        clientMsgId: clientMsgId,
        attachmentType: attachmentType,
        caption: caption,
        replyPayload: replyPayload,
        durationMs: durationMs,
        isVideoNote: isVideoNote,
        listenOnce: listenOnce,
      );
    }
  }

  Future<void> _sendMediaMessage({
    required _ChatUploadFile upload,
    required String attachmentType,
    int? durationMs,
    bool isVideoNote = false,
    bool listenOnce = false,
  }) async {
    if (!_canCompose()) return;
    final clientMsgId = _generateClientMessageId();
    final replyPayload = _currentReplyPayload();
    final caption =
        attachmentType == 'image' ||
            attachmentType == 'video' ||
            attachmentType == 'file'
        ? _controller.text.trim()
        : '';
    final optimisticMessage = _buildOptimisticMediaMessage(
      clientMsgId: clientMsgId,
      upload: upload,
      attachmentType: attachmentType,
      caption: caption,
      replyPayload: replyPayload,
      durationMs: durationMs,
      isVideoNote: isVideoNote,
      listenOnce: listenOnce,
    );
    if (attachmentType == 'image' ||
        attachmentType == 'video' ||
        attachmentType == 'file') {
      _controller.clear();
    }
    _clearReplyComposer();
    _upsertMessage(optimisticMessage, autoScroll: true);
    await _persistOutboxItem(
      message: optimisticMessage,
      retryPayload: _retryPayloadOf(_metaMapOf(optimisticMessage['meta'])),
      status: 'queued',
    );
    unawaited(_flushPersistentOutbox());
  }

  // ignore: unused_element
  Future<void> _pickAndSendImage(ImageSource source) async {
    if (!_canCompose() ||
        _mediaUploading ||
        _voiceSending ||
        _voiceRecording ||
        _videoRecording) {
      return;
    }
    try {
      final rawUpload = await _pickRawImageUpload(source);
      if (rawUpload == null) return;
      final recommendedMode = await _recommendedImageSendMode();
      final sendMode = await _promptImageSendMode(recommendedMode);
      if (sendMode == null) return;
      final upload = await _prepareImageUploadForMode(rawUpload, sendMode);
      if (upload == null) return;
      await _sendMediaMessage(
        upload: upload,
        attachmentType: sendMode == _ImageSendMode.file ? 'file' : 'image',
      );
    } catch (e) {
      if (!mounted) return;
      final errorText = _extractDioError(e);
      showAppNotice(
        context,
        errorText.isNotEmpty && errorText != e.toString()
            ? 'Не удалось отправить изображение: $errorText'
            : 'Не удалось выбрать изображение',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 3),
      );
      debugPrint('pickAndSendImage error: $e');
    }
  }

  // ignore: unused_element
  Future<void> _pickAndSendVideo({ImageSource? source}) async {
    if (!_canCompose() || _mediaUploading || _voiceSending || _voiceRecording) {
      return;
    }
    try {
      final upload = await _pickVideoUpload(source: source);
      if (upload == null) return;
      await _sendMediaMessage(upload: upload, attachmentType: 'video');
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось выбрать видео',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('pickAndSendVideo error: $e');
    }
  }

  Future<List<ChatRecentGalleryItem>> _loadAttachmentRecentGallery() async {
    if (_preferFilePickerForImages) {
      return const <ChatRecentGalleryItem>[];
    }
    try {
      return await ChatRecentGalleryService.loadRecent(limit: 72);
    } catch (e) {
      debugPrint('loadAttachmentRecentGallery error: $e');
      return const <ChatRecentGalleryItem>[];
    }
  }

  Future<List<_AttachmentPickedUpload>>
  _pickAttachmentImagesFromDevice() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    final files = result?.files ?? const <PlatformFile>[];
    final uploads = <_AttachmentPickedUpload>[];
    for (final picked in files) {
      final bytes = picked.bytes;
      if ((bytes == null || bytes.isEmpty) &&
          (picked.path ?? '').trim().isEmpty) {
        continue;
      }
      final filename = picked.name.trim().isNotEmpty
          ? picked.name.trim()
          : 'image-${DateTime.now().millisecondsSinceEpoch}.jpg';
      uploads.add(
        _AttachmentPickedUpload(
          id: 'device-${picked.identifier ?? filename}-${uploads.length}',
          kind: 'image',
          upload: _ChatUploadFile(
            filename: filename,
            path: (picked.path ?? '').trim().isNotEmpty
                ? picked.path!.trim()
                : null,
            bytes: bytes == null || bytes.isEmpty ? null : bytes,
            mimeType: _guessMimeTypeFromFilename(filename),
            fileSize: picked.size,
          ),
          previewBytes: bytes,
        ),
      );
    }
    return uploads;
  }

  Future<_AttachmentPickedUpload?> _attachmentUploadFromRecent(
    ChatRecentGalleryItem item,
  ) async {
    try {
      final source = await ChatRecentGalleryService.loadUpload(item);
      if (source == null) return null;
      final kind = source.kind == 'video' ? 'video' : 'image';
      return _AttachmentPickedUpload(
        id: 'recent-${item.id}',
        kind: kind,
        upload: _ChatUploadFile(
          filename: source.filename,
          path: source.path,
          bytes: source.bytes,
          mimeType:
              source.mimeType ?? _guessMimeTypeFromFilename(source.filename),
          fileSize: source.fileSize,
          qualityMode: kind == 'video'
              ? await _recommendedMediaQualityMode()
              : null,
        ),
        previewBytes: item.thumbnailBytes,
      );
    } catch (e) {
      debugPrint('attachmentUploadFromRecent error: $e');
      return null;
    }
  }

  Future<bool> _startAttachmentCameraPreview() async {
    if (NativeVideoNoteCaptureService.shouldUseNativeCapture) {
      try {
        final supported = await NativeVideoNoteCaptureService.isSupported();
        if (!supported) return false;
        await NativeVideoNoteCaptureService.startPreview();
        return true;
      } catch (e) {
        debugPrint('startAttachmentCameraPreview error: $e');
        return false;
      }
    }
    return _ensureVideoCameraReady();
  }

  Future<void> _stopAttachmentCameraPreview() async {
    if (!NativeVideoNoteCaptureService.shouldUseNativeCapture) return;
    try {
      await NativeVideoNoteCaptureService.stopPreview();
    } catch (e) {
      debugPrint('stopAttachmentCameraPreview error: $e');
    }
  }

  bool get _attachmentCameraPreviewAvailable {
    final controller = _videoCameraController;
    return controller != null && controller.value.isInitialized;
  }

  Future<_AttachmentPickedUpload?> _captureAttachmentCameraPhoto() async {
    if (NativeVideoNoteCaptureService.shouldUseNativeCapture) {
      final bytes = await NativeVideoNoteCaptureService.capturePhoto();
      if (bytes == null || bytes.isEmpty) return null;
      final filename = 'camera-${DateTime.now().millisecondsSinceEpoch}.jpg';
      return _AttachmentPickedUpload(
        id: 'camera-photo-${DateTime.now().microsecondsSinceEpoch}',
        kind: 'image',
        upload: _ChatUploadFile(
          filename: filename,
          bytes: bytes,
          mimeType: 'image/jpeg',
          fileSize: bytes.length,
        ),
        previewBytes: bytes,
      );
    }
    final ready = await _ensureVideoCameraReady();
    final controller = _videoCameraController;
    if (!ready || controller == null || !controller.value.isInitialized) {
      throw StateError(_cameraErrorHint(_lastVideoCameraError));
    }
    final xfile = await controller.takePicture();
    final filename = xfile.name.trim().isNotEmpty
        ? xfile.name.trim()
        : 'camera-${DateTime.now().millisecondsSinceEpoch}.jpg';
    final bytes = kIsWeb ? await xfile.readAsBytes() : null;
    return _AttachmentPickedUpload(
      id: 'camera-photo-${DateTime.now().microsecondsSinceEpoch}',
      kind: 'image',
      upload: _ChatUploadFile(
        filename: filename,
        path: kIsWeb ? null : xfile.path,
        bytes: bytes == null || bytes.isEmpty ? null : bytes,
        mimeType: (xfile.mimeType ?? '').trim().isNotEmpty == true
            ? xfile.mimeType!.trim()
            : _guessMimeTypeFromFilename(filename),
        fileSize: bytes?.length,
      ),
      previewBytes: bytes,
    );
  }

  Future<_AttachmentPickedUpload?>
  _toggleAttachmentCameraVideoRecording() async {
    if (NativeVideoNoteCaptureService.shouldUseNativeCapture) {
      if (_attachmentNativeVideoRecording) {
        final startedAt = _attachmentCameraVideoStartedAt;
        final result = await NativeVideoNoteCaptureService.stop();
        _attachmentNativeVideoRecording = false;
        _attachmentCameraVideoStartedAt = null;
        final durationMs = result.durationMs > 0
            ? result.durationMs
            : DateTime.now()
                  .difference(startedAt ?? DateTime.now())
                  .inMilliseconds;
        return _AttachmentPickedUpload(
          id: 'camera-video-${DateTime.now().microsecondsSinceEpoch}',
          kind: 'video',
          upload: _ChatUploadFile(
            filename: result.filename.isNotEmpty
                ? result.filename
                : result.path.split('/').last,
            path: result.path,
            mimeType: result.mimeType,
            qualityMode: await _recommendedMediaQualityMode(),
          ),
          durationMs: durationMs,
        );
      }
      await NativeVideoNoteCaptureService.start();
      _attachmentNativeVideoRecording = true;
      _attachmentCameraVideoStartedAt = DateTime.now();
      return null;
    }

    final ready = await _ensureVideoCameraReady();
    final controller = _videoCameraController;
    if (!ready || controller == null || !controller.value.isInitialized) {
      throw StateError(_cameraErrorHint(_lastVideoCameraError));
    }
    if (controller.value.isRecordingVideo) {
      final startedAt = _attachmentCameraVideoStartedAt;
      final xfile = await controller.stopVideoRecording();
      _attachmentCameraVideoStartedAt = null;
      final durationMs = DateTime.now()
          .difference(startedAt ?? DateTime.now())
          .inMilliseconds;
      final mimeType = (xfile.mimeType ?? '').trim();
      Uint8List? bytes;
      if (kIsWeb) {
        bytes =
            await _readWebBlobBytes(xfile.path) ?? await xfile.readAsBytes();
      }
      final filename = xfile.name.trim().isNotEmpty
          ? xfile.name.trim()
          : 'camera-video-${DateTime.now().millisecondsSinceEpoch}.${_videoExtensionForMime(mimeType)}';
      return _AttachmentPickedUpload(
        id: 'camera-video-${DateTime.now().microsecondsSinceEpoch}',
        kind: 'video',
        upload: _ChatUploadFile(
          filename: filename,
          path: kIsWeb ? null : xfile.path,
          bytes: bytes == null || bytes.isEmpty ? null : bytes,
          mimeType: mimeType.isNotEmpty
              ? mimeType
              : _guessMimeTypeFromFilename(filename),
          fileSize: bytes?.length,
          qualityMode: await _recommendedMediaQualityMode(),
        ),
        durationMs: durationMs,
      );
    }
    try {
      await controller.prepareForVideoRecording();
    } catch (_) {}
    await controller.startVideoRecording();
    _attachmentCameraVideoStartedAt = DateTime.now();
    return null;
  }

  Future<void> _cancelAttachmentCameraVideoRecording() async {
    try {
      if (_attachmentNativeVideoRecording) {
        await NativeVideoNoteCaptureService.cancel();
        _attachmentNativeVideoRecording = false;
        _attachmentCameraVideoStartedAt = null;
        return;
      }
      final controller = _videoCameraController;
      if (controller?.value.isRecordingVideo == true) {
        await controller!.stopVideoRecording();
      }
    } catch (e) {
      debugPrint('cancelAttachmentCameraVideoRecording error: $e');
    } finally {
      _attachmentCameraVideoStartedAt = null;
    }
  }

  Future<void> _sendAttachmentGallerySelection(
    _AttachmentGallerySelection selection,
  ) async {
    if (!_canCompose() || selection.items.isEmpty) return;
    final images = selection.items
        .where((item) => item.kind == 'image')
        .toList(growable: false);
    _ImageSendMode? imageMode;
    if (images.isNotEmpty) {
      final recommendedMode = await _recommendedImageSendMode();
      imageMode = await _promptImageSendMode(recommendedMode);
      if (imageMode == null) return;
    }

    for (final item in selection.items) {
      if (item.kind == 'video') {
        await _sendMediaMessage(
          upload: item.upload,
          attachmentType: 'video',
          durationMs: item.durationMs,
        );
        continue;
      }

      final mode = imageMode ?? _ImageSendMode.standard;
      final upload = await _prepareImageUploadForMode(item.upload, mode);
      if (upload == null) continue;
      await _sendMediaMessage(
        upload: upload,
        attachmentType: mode == _ImageSendMode.file ? 'file' : 'image',
      );
    }
  }

  Future<void> _openAttachmentSheet() async {
    if (!_canCompose() || _mediaUploading || _voiceSending || _voiceRecording) {
      return;
    }
    final selection = await showModalBottomSheet<_AttachmentGallerySelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
      builder: (sheetContext) => _ChatAttachmentGallerySheet(
        title: 'Недавние',
        desktopMode: _preferFilePickerForImages,
        nativeMacCameraMode:
            NativeVideoNoteCaptureService.shouldUseNativeCapture,
        loadRecent: _loadAttachmentRecentGallery,
        loadRecentUpload: _attachmentUploadFromRecent,
        pickFromDevice: _pickAttachmentImagesFromDevice,
        startCamera: _startAttachmentCameraPreview,
        cameraController: () => _videoCameraController,
        cameraPreviewAvailable: () => _attachmentCameraPreviewAvailable,
        cameraHint: () => _cameraErrorHint(_lastVideoCameraError),
        capturePhoto: _captureAttachmentCameraPhoto,
        toggleRecordVideo: _toggleAttachmentCameraVideoRecording,
        cancelRecordVideo: _cancelAttachmentCameraVideoRecording,
        stopCamera: _stopAttachmentCameraPreview,
      ),
    );
    if (selection == null || selection.items.isEmpty) return;
    await _sendAttachmentGallerySelection(selection);
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
                        children: categories
                            .map((entry) {
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
                            })
                            .toList(growable: false),
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

  List<MapEntry<String, List<String>>> _composerEmojiCategories() {
    return <MapEntry<String, List<String>>>[
      if (_recentComposerEmojis.isNotEmpty)
        MapEntry<String, List<String>>(
          'Недавние',
          List<String>.from(_recentComposerEmojis),
        ),
      MapEntry<String, List<String>>('Частые', _composerPickerEmojis()),
      ..._reactionEmojiCategories.entries,
    ];
  }

  String _emojiCategoryLabel(String label) {
    switch (label) {
      case 'Недавние':
        return '⏱';
      case 'Частые':
        return '🙂';
      case 'Лица':
        return '😀';
      case 'Жесты':
        return '👍';
      case 'Сердца':
        return '❤️';
      case 'Работа':
        return '📦';
      case 'Праздник':
        return '🎉';
      default:
        return label;
    }
  }

  Widget _emojiPickerTile(
    BuildContext context,
    String emoji, {
    required VoidCallback onTap,
    bool selected = false,
    double fontSize = 27,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.82)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.58)
                  : Colors.transparent,
            ),
          ),
          child: Center(
            child: Text(emoji, style: TextStyle(fontSize: fontSize)),
          ),
        ),
      ),
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
    final categories = _composerEmojiCategories()
        .where((entry) => entry.value.isNotEmpty)
        .toList(growable: false);
    if (categories.isEmpty) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final height = min(MediaQuery.sizeOf(ctx).height * 0.58, 430.0);
        return DefaultTabController(
          length: categories.length,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                left: 10,
                right: 10,
                bottom: 10 + MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.98),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                    bottom: Radius.circular(18),
                  ),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 28,
                      offset: const Offset(0, -8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.22,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Эмодзи',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            'Unicode',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerHeight: 0,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 5),
                      indicator: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.62,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      tabs: categories
                          .map(
                            (entry) => Tab(
                              height: 38,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: Text(
                                  _emojiCategoryLabel(entry.key),
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TabBarView(
                        children: categories
                            .map((entry) {
                              final emojis = entry.value;
                              return GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  2,
                                  14,
                                  14,
                                ),
                                itemCount: emojis.length,
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 7,
                                      mainAxisSpacing: 8,
                                      crossAxisSpacing: 8,
                                      childAspectRatio: 1,
                                    ),
                                itemBuilder: (context, index) {
                                  final emoji = emojis[index];
                                  final selected =
                                      _recentComposerEmojis.isNotEmpty &&
                                      _recentComposerEmojis.first == emoji;
                                  return _emojiPickerTile(
                                    context,
                                    emoji,
                                    selected: selected,
                                    onTap: () => Navigator.of(ctx).pop(emoji),
                                  );
                                },
                              );
                            })
                            .toList(growable: false),
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
        _voiceRecordingVisualPhase = _RecordingActionVisualPhase.dragging;
        _recordingSeconds = 0;
        _recordingDragDx = 0;
        _recordingDragDy = 0;
      });
      _voiceRecordingStartedAt = DateTime.now();
      _microphonePermissionGranted = true;
      _microphonePermissionDenied = false;
      unawaited(_emitChatActivity('chat:recording_voice'));
      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordingSeconds += 1);
        unawaited(_emitChatActivity('chat:recording_voice'));
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

  void _resetVideoRecordingState() {
    _videoRecordingCancelVisualTimer?.cancel();
    _videoRecordingCancelVisualTimer = null;
    _videoRecordingTimer?.cancel();
    _videoRecordingTimer = null;
    _videoRecordingStartedAt = null;
    _stopNativeVideoPreviewStream();
    if (!mounted) {
      _videoRecording = false;
      _nativeVideoNoteRecording = false;
      _webVideoNoteRecording = false;
      _videoRecordingLocked = false;
      _videoRecordingVisualPhase = _RecordingActionVisualPhase.idle;
      _videoRecordingSeconds = 0;
      _videoRecordingDragDx = 0;
      _videoRecordingDragDy = 0;
      return;
    }
    setState(() {
      _videoRecording = false;
      _nativeVideoNoteRecording = false;
      _webVideoNoteRecording = false;
      _videoRecordingLocked = false;
      _videoRecordingVisualPhase = _RecordingActionVisualPhase.idle;
      _videoRecordingSeconds = 0;
      _videoRecordingDragDx = 0;
      _videoRecordingDragDy = 0;
    });
  }

  void _startVideoRecordingTicker() {
    _videoRecordingTimer?.cancel();
    _videoRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _videoRecordingSeconds += 1);
      unawaited(_emitChatActivity('chat:recording_video'));
    });
  }

  Future<void> _startNativeVideoCircleRecording({
    bool autoStopIfNotPressed = true,
  }) async {
    _videoStartInProgress = true;
    try {
      final supported = await NativeVideoNoteCaptureService.isSupported();
      if (!supported) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Видеокружки недоступны в этой сборке приложения',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
        return;
      }
      _startNativeVideoPreviewStream();
      await NativeVideoNoteCaptureService.start();
      _videoRecordingTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _videoRecording = true;
        _nativeVideoNoteRecording = true;
        _videoRecordingLocked = false;
        _videoRecordingVisualPhase = _RecordingActionVisualPhase.dragging;
        _videoRecordingSeconds = 0;
        _videoRecordingDragDx = 0;
        _videoRecordingDragDy = 0;
      });
      _videoRecordingStartedAt = DateTime.now();
      unawaited(_emitChatActivity('chat:recording_video'));
      _startVideoRecordingTicker();
      if (autoStopIfNotPressed && !_composerMediaPressActive) {
        await _stopVideoCircleRecordingAndSend();
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось начать видеозапись: ${_cameraErrorHint(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('startNativeVideoCircleRecording error: $e');
      _stopNativeVideoPreviewStream();
    } finally {
      _videoStartInProgress = false;
    }
  }

  void _startNativeVideoPreviewStream() {
    _nativeVideoPreviewSub?.cancel();
    _nativeVideoPreviewFrame = null;
    _nativeVideoPreviewSub = NativeVideoNoteCaptureService.previewFrames.listen(
      (frame) {
        if (!mounted || !_nativeVideoNoteRecording) return;
        setState(() => _nativeVideoPreviewFrame = frame);
      },
      onError: (Object error) {
        debugPrint('native video preview error: $error');
      },
    );
  }

  void _stopNativeVideoPreviewStream() {
    _nativeVideoPreviewSub?.cancel();
    _nativeVideoPreviewSub = null;
    _nativeVideoPreviewFrame = null;
  }

  Future<void> _startWebVideoCircleRecording({
    bool autoStopIfNotPressed = true,
  }) async {
    _videoStartInProgress = true;
    try {
      if (!WebVideoNoteCaptureService.isSupported) {
        if (!mounted) return;
        showAppNotice(
          context,
          'Видеокружки недоступны в этом браузере',
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 2),
        );
        return;
      }
      await WebVideoNoteCaptureService.start();
      _videoRecordingTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _videoRecording = true;
        _nativeVideoNoteRecording = false;
        _webVideoNoteRecording = true;
        _videoRecordingLocked = false;
        _videoRecordingVisualPhase = _RecordingActionVisualPhase.dragging;
        _videoRecordingSeconds = 0;
        _videoRecordingDragDx = 0;
        _videoRecordingDragDy = 0;
      });
      _videoRecordingStartedAt = DateTime.now();
      unawaited(_emitChatActivity('chat:recording_video'));
      _startVideoRecordingTicker();
      if (autoStopIfNotPressed && !_composerMediaPressActive) {
        await _stopVideoCircleRecordingAndSend();
      }
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось начать видеозапись: ${_cameraErrorHint(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 2),
      );
      debugPrint('startWebVideoCircleRecording error: $e');
    } finally {
      _videoStartInProgress = false;
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
    if (kIsWeb) {
      await _startWebVideoCircleRecording(
        autoStopIfNotPressed: autoStopIfNotPressed,
      );
      return;
    }
    if (NativeVideoNoteCaptureService.shouldUseNativeCapture) {
      await _startNativeVideoCircleRecording(
        autoStopIfNotPressed: autoStopIfNotPressed,
      );
      return;
    }
    if (!_captureProfile.videoNoteCaptureSupported) {
      if (mounted) {
        showAppNotice(
          context,
          _captureProfile.videoNoteFallbackReason,
          tone: AppNoticeTone.info,
          duration: const Duration(seconds: 3),
        );
      }
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
        _nativeVideoNoteRecording = false;
        _videoRecordingLocked = false;
        _videoRecordingVisualPhase = _RecordingActionVisualPhase.dragging;
        _videoRecordingSeconds = 0;
        _videoRecordingDragDx = 0;
        _videoRecordingDragDy = 0;
      });
      _videoRecordingStartedAt = DateTime.now();
      unawaited(_emitChatActivity('chat:recording_video'));
      _startVideoRecordingTicker();
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
    if (!_videoRecording) return;
    final startedAt = _videoRecordingStartedAt;
    final durationMs = startedAt == null
        ? _videoRecordingSeconds * 1000
        : DateTime.now().difference(startedAt).inMilliseconds;
    final nativeRecording = _nativeVideoNoteRecording;
    final webRecording = _webVideoNoteRecording;
    _resetVideoRecordingState();
    try {
      if (nativeRecording) {
        final result = await NativeVideoNoteCaptureService.stop();
        final effectiveDurationMs = result.durationMs > 0
            ? result.durationMs
            : durationMs;
        if (effectiveDurationMs < 1000) {
          if (!mounted) return;
          showAppNotice(
            context,
            'Видеосообщение отменено (меньше 1 секунды)',
            tone: AppNoticeTone.info,
            duration: const Duration(milliseconds: 900),
          );
          return;
        }
        await _sendMediaMessage(
          upload: _ChatUploadFile(
            filename: result.filename.isNotEmpty
                ? result.filename
                : result.path.split('/').last,
            path: result.path,
            mimeType: result.mimeType,
          ),
          attachmentType: 'video',
          durationMs: effectiveDurationMs,
          isVideoNote: true,
        );
        return;
      }
      if (webRecording) {
        final result = await WebVideoNoteCaptureService.stop();
        final effectiveDurationMs = result.durationMs > 0
            ? result.durationMs
            : durationMs;
        if (effectiveDurationMs < 1000) {
          if (!mounted) return;
          showAppNotice(
            context,
            'Видеосообщение отменено (меньше 1 секунды)',
            tone: AppNoticeTone.info,
            duration: const Duration(milliseconds: 900),
          );
          return;
        }
        if (result.bytes.isEmpty) {
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
            filename: result.filename.isNotEmpty
                ? result.filename
                : 'video-note-${DateTime.now().millisecondsSinceEpoch}.${_videoExtensionForMime(result.mimeType)}',
            bytes: result.bytes,
            mimeType: result.mimeType,
          ),
          attachmentType: 'video',
          durationMs: effectiveDurationMs,
          isVideoNote: true,
        );
        return;
      }
      if (_videoCameraController == null) return;
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
          isVideoNote: true,
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
          isVideoNote: true,
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
      _videoRecordingVisualPhase = _RecordingActionVisualPhase.idle;
      _videoRecordingDragDx = 0;
      _videoRecordingDragDy = 0;
      return;
    }
    final nativeRecording = _nativeVideoNoteRecording;
    final webRecording = _webVideoNoteRecording;
    _resetVideoRecordingState();
    try {
      if (nativeRecording) {
        await NativeVideoNoteCaptureService.cancel();
      } else if (webRecording) {
        await WebVideoNoteCaptureService.cancel();
      } else if (_videoCameraController?.value.isRecordingVideo == true) {
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
    _voiceRecordingCancelVisualTimer?.cancel();
    _voiceRecordingCancelVisualTimer = null;
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
      _voiceRecordingVisualPhase = _RecordingActionVisualPhase.idle;
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
        final filename = _buildWebVoiceFilename();
        await _sendMediaMessage(
          upload: _ChatUploadFile(
            filename: filename,
            bytes: bytes,
            mimeType: _guessMimeTypeFromFilename(filename),
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
    _voiceRecordingCancelVisualTimer?.cancel();
    _voiceRecordingCancelVisualTimer = null;
    if (!_voiceRecording && !_voiceStartInProgress) {
      _voiceRecordingLocked = false;
      _voiceRecordingVisualPhase = _RecordingActionVisualPhase.idle;
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
      _voiceRecordingVisualPhase = _RecordingActionVisualPhase.idle;
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

  void _beginVoiceRecordingCancelDust({String notice = 'Голосовое отменено'}) {
    if (_voiceRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust) {
      return;
    }
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();
    if (mounted) {
      setState(() {
        _voiceRecordingLocked = false;
        _voiceRecordingVisualPhase = _RecordingActionVisualPhase.cancellingDust;
        _recordingDragDx = _recordingDragDx.clamp(-118.0, -88.0).toDouble();
        _recordingDragDy = _recordingDragDy.clamp(-42.0, 42.0).toDouble();
      });
    }
    _voiceRecordingCancelVisualTimer?.cancel();
    _voiceRecordingCancelVisualTimer = Timer(_recordingCancelDustDuration, () {
      _voiceRecordingCancelVisualTimer = null;
      unawaited(_cancelVoiceRecording(notice: notice));
    });
  }

  void _beginVideoRecordingCancelDust({
    String notice = 'Видеосообщение отменено',
  }) {
    if (_videoRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust) {
      return;
    }
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();
    if (mounted) {
      setState(() {
        _videoRecordingLocked = false;
        _videoRecordingVisualPhase = _RecordingActionVisualPhase.cancellingDust;
        _videoRecordingDragDx = _videoRecordingDragDx
            .clamp(-118.0, -88.0)
            .toDouble();
        _videoRecordingDragDy = _videoRecordingDragDy
            .clamp(-42.0, 42.0)
            .toDouble();
      });
    }
    _videoRecordingCancelVisualTimer?.cancel();
    _videoRecordingCancelVisualTimer = Timer(_recordingCancelDustDuration, () {
      _videoRecordingCancelVisualTimer = null;
      unawaited(_cancelVideoCircleRecording(notice: notice));
    });
  }

  String _buildWebVoiceFilename() {
    return 'voice-${DateTime.now().millisecondsSinceEpoch}.$_activeVoiceUploadExtension';
  }

  void _toggleComposerMediaMode() {
    setState(() {
      _composerMediaMode = _composerMediaMode == _ComposerMediaMode.voice
          ? _ComposerMediaMode.camera
          : _ComposerMediaMode.voice;
    });
    if (_composerMediaMode == _ComposerMediaMode.camera &&
        !_captureProfile.videoNoteCaptureSupported &&
        mounted) {
      showAppNotice(
        context,
        _captureProfile.videoNoteFallbackReason,
        tone: AppNoticeTone.info,
        duration: const Duration(seconds: 2),
      );
    }
  }

  void _cancelComposerMediaHoldTimer() {
    _composerMediaHoldTimer?.cancel();
    _composerMediaHoldTimer = null;
  }

  void _handleTextSendPressed() {
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _composerHoldActionTriggered = false;
    _voiceRecordingCancelVisualTimer?.cancel();
    _voiceRecordingCancelVisualTimer = null;
    _videoRecordingCancelVisualTimer?.cancel();
    _videoRecordingCancelVisualTimer = null;
    _cancelComposerMediaHoldTimer();
    if (_anyComposerRecording || _anyRecorderStarting) return;
    unawaited(_send());
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
    _composerMediaPressActive = true;
    _composerPressStartGlobal = details.globalPosition;
    _composerHoldActionTriggered = false;
    _cancelComposerMediaHoldTimer();
    _composerMediaHoldTimer = Timer(_composerRecordHoldDelay, () {
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

    if (_voiceRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust ||
        _videoRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust) {
      return;
    }

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
    _composerMediaPressActive = false;
    _composerPressStartGlobal = null;
    _cancelComposerMediaHoldTimer();
  }

  void _handleRecordingPointerStart(Offset globalPosition) {
    if (!_voiceRecording && !_videoRecording) return;
    if (_voiceRecordingLocked || _videoRecordingLocked) return;
    if (_voiceRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust ||
        _videoRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust) {
      return;
    }
    _composerMediaPressActive = true;
    _composerHoldActionTriggered = true;
    _composerPressStartGlobal = globalPosition;
    _cancelComposerMediaHoldTimer();
  }

  void _handleRecordingPointerMove(Offset globalPosition) {
    if (!_voiceRecording && !_videoRecording) return;
    if (_voiceRecordingLocked || _videoRecordingLocked) return;
    final voiceCancelling =
        _voiceRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust;
    final videoCancelling =
        _videoRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust;
    if (voiceCancelling || videoCancelling) return;
    if (!_composerMediaPressActive) {
      _handleRecordingPointerStart(globalPosition);
    }
    final start = _composerPressStartGlobal ?? globalPosition;
    _composerPressStartGlobal ??= start;
    _applyComposerMediaDragDelta(
      globalPosition.dx - start.dx,
      globalPosition.dy - start.dy,
    );
  }

  void _applyComposerMediaDragDelta(double dx, double dy) {
    final voiceCancelling =
        _voiceRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust;
    final videoCancelling =
        _videoRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust;
    if (_voiceRecording &&
        !_voiceRecordingLocked &&
        !voiceCancelling &&
        mounted) {
      setState(() {
        _recordingDragDx = dx;
        _recordingDragDy = dy;
        _voiceRecordingVisualPhase = _RecordingActionVisualPhase.dragging;
      });
    }
    if (_videoRecording &&
        !_videoRecordingLocked &&
        !videoCancelling &&
        mounted) {
      setState(() {
        _videoRecordingDragDx = dx;
        _videoRecordingDragDy = dy;
        _videoRecordingVisualPhase = _RecordingActionVisualPhase.dragging;
      });
    }
    if (_voiceRecording && !_voiceRecordingLocked && !voiceCancelling) {
      if (dx <= -88) {
        _beginVoiceRecordingCancelDust(
          notice: 'Голосовое отменено (свайп влево)',
        );
        return;
      }
      if (dy <= -72) {
        setState(() {
          _voiceRecordingLocked = true;
          _voiceRecordingVisualPhase = _RecordingActionVisualPhase.lockedHover;
          _recordingDragDx = 0;
          _recordingDragDy = -96;
        });
        _composerMediaPressActive = false;
        _composerPressStartGlobal = null;
        _cancelComposerMediaHoldTimer();
        showAppNotice(
          context,
          'Запись зафиксирована',
          tone: AppNoticeTone.info,
          duration: const Duration(milliseconds: 900),
        );
      }
      return;
    }
    if (_videoRecording && !_videoRecordingLocked && !videoCancelling) {
      if (dx <= -88) {
        _beginVideoRecordingCancelDust(
          notice: 'Видеосообщение отменено (свайп влево)',
        );
        return;
      }
      if (dy <= -72) {
        setState(() {
          _videoRecordingLocked = true;
          _videoRecordingVisualPhase = _RecordingActionVisualPhase.lockedHover;
          _videoRecordingDragDx = 0;
          _videoRecordingDragDy = -96;
        });
        _composerMediaPressActive = false;
        _composerPressStartGlobal = null;
        _cancelComposerMediaHoldTimer();
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
    if (_voiceRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust ||
        _videoRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust) {
      return;
    }
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
    if (_voiceRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust ||
        _videoRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust) {
      return;
    }
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
      await _ensureVoiceSourceAvailable(voiceUrl);
      await _voicePlayer.play(
        UrlSource(voiceUrl, mimeType: _voiceMimeTypeForUrl(voiceUrl)),
      );
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

  String? _voiceMimeTypeForUrl(String url) {
    final normalized = url.split('?').first.toLowerCase();
    if (normalized.endsWith('.m4a') || normalized.endsWith('.mp4')) {
      return 'audio/mp4';
    }
    if (normalized.endsWith('.mp3')) return 'audio/mpeg';
    if (normalized.endsWith('.wav')) return 'audio/wav';
    if (normalized.endsWith('.ogg')) return 'audio/ogg';
    if (normalized.endsWith('.webm')) return 'audio/webm';
    return null;
  }

  Future<void> _ensureVoiceSourceAvailable(String voiceUrl) async {
    final normalized = voiceUrl.trim().toLowerCase();
    if (normalized.startsWith('blob:') || normalized.startsWith('data:')) {
      return;
    }
    final uri = Uri.tryParse(voiceUrl);
    if (uri == null || !uri.hasScheme) return;
    final response = await authService.dio.headUri(
      uri,
      options: Options(
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );
    final contentType = (response.headers.value('content-type') ?? '')
        .trim()
        .toLowerCase();
    if (contentType.isNotEmpty &&
        !contentType.startsWith('audio/') &&
        !contentType.contains('octet-stream')) {
      throw StateError('Voice source is not audio: $contentType');
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

  // ignore: unused_element
  Future<void> _openExpandedVideoNote(
    Map<String, dynamic> message,
    Map<String, dynamic> meta,
  ) async {
    final videoUrl = _videoUrlOf(meta);
    if (videoUrl == null || videoUrl.trim().isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (ctx) => _ExpandedVideoNoteViewer(
        videoUrl: videoUrl,
        previewImageUrl: _videoPreviewImageUrlOf(meta),
        durationMs: _videoDurationMsOf(meta),
        title: _senderNameOf(message),
        caption: _captionTextOf(message, meta),
        timeLabel: _formatMessageTime(message['created_at']),
      ),
    );
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
      if ((replyPayload['reply_to_message_id'] ?? '')
          .toString()
          .trim()
          .isNotEmpty)
        'reply_to_message_id': replyPayload['reply_to_message_id'],
      if ((replyPayload['reply_preview_text'] ?? '')
          .toString()
          .trim()
          .isNotEmpty)
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

  String _optimisticMediaText(
    String attachmentType, {
    required String caption,
  }) {
    if (caption.trim().isNotEmpty) return caption.trim();
    switch (attachmentType) {
      case 'image':
        return 'Фото';
      case 'video':
        return 'Видеосообщение';
      case 'voice':
        return 'Голосовое сообщение';
      case 'file':
        return 'Файл';
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
    bool isVideoNote = false,
    bool listenOnce = false,
  }) {
    return <String, dynamic>{
      'kind': 'media',
      'attachment_type': attachmentType,
      if (isVideoNote) 'is_video_note': true,
      if (listenOnce) 'listen_once': true,
      'filename': upload.filename,
      if ((upload.path ?? '').trim().isNotEmpty) 'path': upload.path!.trim(),
      if (upload.bytes != null) 'bytes': upload.bytes,
      if ((upload.mimeType ?? '').trim().isNotEmpty)
        'mime_type': upload.mimeType!.trim(),
      if (upload.fileSize != null) 'file_size': upload.fileSize,
      if ((upload.qualityMode ?? '').trim().isNotEmpty)
        'quality_mode': upload.qualityMode!.trim(),
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
      fileSize: retryPayload['file_size'] is num
          ? (retryPayload['file_size'] as num).toInt()
          : int.tryParse('${retryPayload['file_size'] ?? ''}'),
      qualityMode:
          (retryPayload['quality_mode'] ?? '').toString().trim().isNotEmpty
          ? (retryPayload['quality_mode'] ?? '').toString().trim()
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
    bool isVideoNote = false,
    bool listenOnce = false,
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
      isVideoNote: isVideoNote,
      listenOnce: listenOnce,
    );
    final meta = <String, dynamic>{
      'attachment_type': attachmentType,
      'local_only': true,
      'delivery_status': 'queued',
      'message_send_state': 'local_pending',
      'retry_payload': retryPayload,
      ...replyPayload,
      if (attachmentType == 'image' && previewUrl != null)
        'image_url': previewUrl,
      if (attachmentType == 'image' && (upload.width ?? 0) > 0)
        'image_width': upload.width,
      if (attachmentType == 'image' && (upload.height ?? 0) > 0)
        'image_height': upload.height,
      if (attachmentType == 'file') 'file_name': upload.filename,
      if (attachmentType == 'file' && (upload.mimeType ?? '').trim().isNotEmpty)
        'file_mime_type': upload.mimeType!.trim(),
      if (attachmentType == 'file' && (upload.fileSize ?? 0) > 0)
        'file_size': upload.fileSize,
      if ((upload.qualityMode ?? '').trim().isNotEmpty)
        'quality_mode': upload.qualityMode!.trim(),
      if (isVideoNote) 'is_video_note': true,
      if (listenOnce) 'listen_once': true,
      if (attachmentType == 'voice' && (durationMs ?? 0) > 0)
        'voice_duration_ms': durationMs,
      if (attachmentType == 'video' && (durationMs ?? 0) > 0)
        'video_duration_ms': durationMs,
      if (attachmentType == 'video' && isVideoNote) 'is_video_note': true,
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
    final clientMsgId = (message['client_msg_id'] ?? '').toString().trim();
    if (clientMsgId.isEmpty) return;

    final queuedMeta = <String, dynamic>{
      ...meta,
      'local_only': true,
      'delivery_status': 'queued',
      'message_send_state': 'local_pending',
      'retry_payload': retryPayload,
    };
    queuedMeta.remove('error_message');
    final queuedMessage = {...message, 'meta': queuedMeta};
    _upsertMessage(queuedMessage, autoScroll: true);
    await _persistOutboxItem(
      message: queuedMessage,
      retryPayload: retryPayload,
      status: 'queued',
    );
    unawaited(_flushPersistentOutbox(includeErrored: true));
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
        'message_send_state': 'local_pending',
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
    _maybeEmitTypingInactive();
    _upsertMessage(optimisticMessage, autoScroll: true);
    await _persistOutboxItem(
      message: optimisticMessage,
      retryPayload: _buildTextRetryPayload(
        text: text,
        replyPayload: replyPayload,
      ),
      status: 'sending',
    );
    unawaited(_flushPersistentOutbox());
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

  Future<void> _deleteCatalogProductFully(Map<String, dynamic> meta) async {
    final productId = (meta['product_id'] ?? '').toString().trim();
    if (productId.isEmpty || !_isAdminOrCreator()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить товар полностью?'),
        content: const Text(
          'Товар исчезнет из канала, активных корзин и очередей. История доставки сохранится, если она уже нужна для отчетов.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await authService.dio.delete('/api/admin/products/$productId/full');
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((message) {
          final messageMeta = _metaMapOf(message['meta']);
          return (messageMeta['product_id'] ?? '').toString().trim() !=
              productId;
        }).toList();
        _messageIds
          ..clear()
          ..addAll(
            _messages
                .map((message) => (message['id'] ?? '').toString().trim())
                .where((id) => id.isNotEmpty),
          );
      });
      showAppNotice(
        context,
        'Товар удален из активной системы',
        tone: AppNoticeTone.success,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка удаления товара: ${_extractDioError(e)}',
        tone: AppNoticeTone.error,
        duration: const Duration(seconds: 3),
      );
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
    final settings = _effectiveChatSettings();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    final systemKey = (settings['system_key'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    final title = _chatTitle.toLowerCase().trim();
    return kind == 'reserved_orders' ||
        systemKey == 'reserved_orders' ||
        title == 'забронированный товар';
  }

  bool _isBugReportsChat() {
    final settings = _effectiveChatSettings();
    final kind = (settings['kind'] ?? '').toString().toLowerCase().trim();
    final title = _chatTitle.toLowerCase().trim();
    return kind == 'bug_reports' || title == 'баг-репорты';
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

  String _reservedShelfDisplayOfMeta(Map<String, dynamic> meta) {
    final label = (meta['shelf_label'] ?? '').toString().trim();
    if (label.isNotEmpty) return label;
    final numberText = (meta['shelf_number'] ?? '').toString().trim();
    if (numberText.isNotEmpty) return numberText;
    return '';
  }

  int? _reservedShelfIntegerValue(String raw) {
    final normalized = raw.trim();
    if (normalized.isEmpty || !RegExp(r'^-?\d+$').hasMatch(normalized)) {
      return null;
    }
    return int.tryParse(normalized);
  }

  int _compareReservedShelfDisplays(String a, String b) {
    final left = a.trim();
    final right = b.trim();
    final leftEmpty = left.isEmpty;
    final rightEmpty = right.isEmpty;
    if (leftEmpty && rightEmpty) return 0;
    if (leftEmpty) return 1;
    if (rightEmpty) return -1;

    final leftInt = _reservedShelfIntegerValue(left);
    final rightInt = _reservedShelfIntegerValue(right);
    if (leftInt != null && rightInt != null) {
      return leftInt.compareTo(rightInt);
    }
    if (leftInt != null) return -1;
    if (rightInt != null) return 1;

    final leftLower = left.toLowerCase();
    final rightLower = right.toLowerCase();
    final primary = leftLower.compareTo(rightLower);
    if (primary != 0) return primary;
    return left.compareTo(right);
  }

  DateTime? _reservedTimelineDateOf(Map<String, dynamic> message) {
    final createdAt = _parseDate(message['created_at']);
    if (createdAt == null) return null;
    return DateTime(createdAt.year, createdAt.month, createdAt.day);
  }

  int _compareReservedTimelineDates(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final ad = _reservedTimelineDateOf(a);
    final bd = _reservedTimelineDateOf(b);
    if (ad == null && bd == null) return 0;
    if (ad == null) return -1;
    if (bd == null) return 1;
    return ad.compareTo(bd);
  }

  int _compareReservedTimelineMessages(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final byDate = _compareReservedTimelineDates(a, b);
    if (byDate != 0) return byDate;

    final aMeta = _metaMapOf(a['meta']);
    final bMeta = _metaMapOf(b['meta']);
    final aProcessingMode = (aMeta['processing_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final bProcessingMode = (bMeta['processing_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final aOversize =
        aProcessingMode == 'oversize' || aMeta['is_oversize'] == true;
    final bOversize =
        bProcessingMode == 'oversize' || bMeta['is_oversize'] == true;
    if (aOversize != bOversize) {
      return aOversize ? 1 : -1;
    }

    final byShelf = _compareReservedShelfDisplays(
      _reservedShelfDisplayOfMeta(aMeta),
      _reservedShelfDisplayOfMeta(bMeta),
    );
    if (byShelf != 0) return byShelf;

    final byTime = _compareByCreatedAt(a, b);
    if (byTime != 0) return byTime;

    final productA = int.tryParse(_reservedProductCodeOf(a) ?? '') ?? 0;
    final productB = int.tryParse(_reservedProductCodeOf(b) ?? '') ?? 0;
    return productA.compareTo(productB);
  }

  bool _reservedIsPlaced(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    if (meta['client_cancelled'] == true) return false;
    final cartItemId = (meta['cart_item_id'] ?? '').toString().trim();
    return meta['placed'] == true ||
        (cartItemId.isNotEmpty && _placedCartItemIds.contains(cartItemId));
  }

  bool _reservedIsCancelled(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final value = meta['client_cancelled'];
    if (value == true) return true;
    return value != null && value.toString().trim().toLowerCase() == 'true';
  }

  bool _reservedIsOversize(Map<String, dynamic> message) {
    final meta = _metaMapOf(message['meta']);
    final processingMode = (meta['processing_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return processingMode == 'oversize' || meta['is_oversize'] == true;
  }

  List<Map<String, dynamic>> _messagesMatchingCurrentSearch() {
    if (_searchQuery.trim().isNotEmpty && _serverSearchLoaded) {
      return [..._serverSearchMessages]..sort(_compareByCreatedAt);
    }
    final messagesSnapshot = List<Map<String, dynamic>>.from(_messages);
    return messagesSnapshot
        .where((m) => _messageMatchesSearch(m, _searchQuery))
        .toList()
      ..sort(_compareByCreatedAt);
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
    return role == 'admin' || role == 'tenant' || role == 'creator';
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
    String? messageId,
    String? reservationId,
    String? cartItemId,
    required Map<String, dynamic> patch,
  }) {
    final messageKey = (messageId ?? '').trim();
    final reservationKey = (reservationId ?? '').trim();
    final cartItemKey = (cartItemId ?? '').trim();
    if (messageKey.isEmpty && reservationKey.isEmpty && cartItemKey.isEmpty) {
      return;
    }
    setState(() {
      _messages = _messages.map((message) {
        final meta = _metaMapOf(message['meta']);
        if (meta['kind']?.toString() != 'reserved_order_item') return message;
        final currentMessageId = (message['id'] ?? '').toString().trim();
        final messageReservationId = (meta['reservation_id'] ?? '')
            .toString()
            .trim();
        final messageCartItemId = (meta['cart_item_id'] ?? '')
            .toString()
            .trim();
        final matchesMessageId =
            messageKey.isNotEmpty && currentMessageId == messageKey;
        final matchesReservation =
            reservationKey.isNotEmpty && messageReservationId == reservationKey;
        final matchesCartItem =
            cartItemKey.isNotEmpty && messageCartItemId == cartItemKey;
        if (!matchesMessageId && !matchesReservation && !matchesCartItem) {
          return message;
        }
        return {
          ...message,
          'meta': Map<String, dynamic>.from(meta)..addAll(patch),
        };
      }).toList();
    });
  }

  void _patchReservedUserShelfLocally({
    required String userId,
    required String shelfLabel,
    int? shelfNumber,
  }) {
    final userKey = userId.trim();
    final normalizedShelfLabel = shelfLabel.trim();
    if (userKey.isEmpty || normalizedShelfLabel.isEmpty) return;
    setState(() {
      _messages = _messages.map((message) {
        final meta = _metaMapOf(message['meta']);
        if (meta['kind']?.toString() != 'reserved_order_item') return message;
        final messageUserId = (meta['user_id'] ?? '').toString().trim();
        final isPlaced =
            meta['placed'] == true ||
            _placedCartItemIds.contains(
              (meta['cart_item_id'] ?? '').toString().trim(),
            );
        final rawCancelled = meta['client_cancelled'];
        final isCancelled =
            rawCancelled == true ||
            (rawCancelled != null &&
                rawCancelled.toString().trim().toLowerCase() == 'true');
        final processingMode = (meta['processing_mode'] ?? 'standard')
            .toString()
            .trim()
            .toLowerCase();
        if (messageUserId != userKey ||
            isCancelled ||
            processingMode == 'oversize' ||
            isPlaced) {
          return message;
        }
        return {
          ...message,
          'meta': Map<String, dynamic>.from(meta)
            ..['shelf_label'] = normalizedShelfLabel
            ..['shelf_number'] = shelfNumber,
        };
      }).toList();
    });
  }

  Future<String?> _promptShelfLabel({
    String title = 'Укажите полку',
    String initialValue = '',
  }) async {
    var shelfDraft = initialValue.trim();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: shelfDraft,
          onChanged: (value) => shelfDraft = value,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            labelText: 'Полка',
            hintText: 'Например: 3, 0, -1, A-01',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final normalized = shelfDraft.trim();
              if (normalized.isEmpty) {
                showAppNotice(
                  context,
                  'Введите корректную полку',
                  tone: AppNoticeTone.warning,
                  duration: const Duration(seconds: 2),
                );
                return;
              }
              Navigator.of(ctx).pop(normalized);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeReservedOrderShelf(
    Map<String, dynamic> meta, {
    String? messageId,
  }) async {
    if (!_canMarkReservedOrderPlaced()) return;
    final reservationId = (meta['reservation_id'] ?? '').toString().trim();
    final cartItemId = (meta['cart_item_id'] ?? '').toString().trim();
    if (reservationId.isEmpty && cartItemId.isEmpty) return;
    final currentShelf = _reservedShelfDisplayOfMeta(meta);
    final nextShelf = await _promptShelfLabel(
      title: 'Смена полки',
      initialValue: currentShelf,
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
      final shelfLabel = (payload['shelf_label'] ?? nextShelf)
          .toString()
          .trim();
      final shelfNumber = int.tryParse(
        (payload['shelf_number'] ?? '').toString().trim(),
      );
      final shelfDisplay = (payload['shelf_display'] ?? shelfLabel)
          .toString()
          .trim();
      if (!mounted) return;
      _patchReservedOrderMessageLocally(
        messageId: messageId,
        reservationId: reservationId,
        cartItemId: cartItemId,
        patch: {'shelf_label': shelfLabel, 'shelf_number': shelfNumber},
      );
      _patchReservedUserShelfLocally(
        userId: userId,
        shelfLabel: shelfLabel,
        shelfNumber: shelfNumber,
      );
      showAppNotice(
        context,
        'Полка изменена на $shelfDisplay',
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
      if (result == null ||
          (result['address_text'] ?? '').toString().trim().isEmpty) {
        return;
      }
      addressText = (result['address_text'] ?? '').toString().trim();
      preferredTimeFrom = (result['preferred_time_from'] ?? '')
          .toString()
          .trim();
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
    String? messageId,
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
        processingMode != 'oversize' &&
        _placedCartItemIds.contains(cartItemId)) {
      return;
    }
    final knownShelf = _reservedShelfDisplayOfMeta(meta);
    final oversize = processingMode == 'oversize';

    setState(() => _markingPlaced = true);
    try {
      final reservationIdValue = (reservationId ?? '').trim();
      final cartItemIdValue = (cartItemId ?? '').trim();
      Future<Response<dynamic>> sendMarkPlaced({
        String? shelfLabel,
        bool manualShelf = false,
      }) {
        final shelfValue = (shelfLabel ?? '').trim();
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
          shelfLabel: oversize
              ? null
              : (requiresManualByRole
                    ? null
                    : (knownShelf.isEmpty ? null : knownShelf)),
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

        final manualShelf = await _promptShelfLabel();
        if (manualShelf == null) return;
        resp = await sendMarkPlaced(shelfLabel: manualShelf, manualShelf: true);
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
          messageId: messageId,
          reservationId: reservationId,
          cartItemId: cartItemId,
          patch: {
            'placed': true,
            'processing_mode': resolvedMode,
            'is_oversize': resolvedMode == 'oversize',
            'shelf_number': payload['shelf_number'],
            'shelf_label': payload['shelf_label'],
            'processed_by_name': (payload['processed_by_name'] ?? '')
                .toString()
                .trim(),
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
      if (e is DioException) {
        final rawData = e.response?.data;
        final responseMap = rawData is Map
            ? Map<String, dynamic>.from(rawData)
            : const <String, dynamic>{};
        final errorCode = (responseMap['code'] ?? '').toString().trim();
        if (errorCode == 'client_cancelled') {
          _patchReservedOrderMessageLocally(
            messageId: messageId,
            reservationId: reservationId,
            cartItemId: cartItemId,
            patch: {'client_cancelled': true, 'placed': false},
          );
          showAppNotice(
            context,
            'Клиент уже отказался от товара',
            tone: AppNoticeTone.info,
            duration: const Duration(seconds: 2),
          );
          return;
        }
      }
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

  bool get _useApproximateViewportTracking => true;

  String _messageIdentityKey(Map<String, dynamic> message, int fallbackIndex) {
    final messageId = _messageIdOf(message);
    if (messageId.isNotEmpty) return 'id:$messageId';
    final clientMsgId = (message['client_msg_id'] ?? '').toString().trim();
    if (clientMsgId.isNotEmpty) return 'client:$clientMsgId';
    final createdAt = (message['created_at'] ?? '').toString().trim();
    final text = (message['text'] ?? '').toString().trim();
    return 'fallback:$createdAt:$text:$fallbackIndex';
  }

  List<Map<String, dynamic>> _dedupeMessages(
    Iterable<Map<String, dynamic>> messages,
  ) {
    final order = <String>[];
    final byKey = <String, Map<String, dynamic>>{};
    var fallbackIndex = 0;

    for (final rawMessage in messages) {
      final normalized = _normalizeMessage(
        Map<String, dynamic>.from(rawMessage),
      );
      final key = _messageIdentityKey(normalized, fallbackIndex);
      fallbackIndex += 1;
      final existing = byKey[key];
      if (existing == null) {
        order.add(key);
        byKey[key] = normalized;
        continue;
      }
      byKey[key] = {
        ...existing,
        ...normalized,
        'meta': {
          ..._metaMapOf(existing['meta']),
          ..._metaMapOf(normalized['meta']),
        },
      };
    }

    return order.map((key) => byKey[key]!).toList(growable: false)
      ..sort(_compareByCreatedAt);
  }

  int? _approximateViewportMessageIndex() {
    if (_messages.isEmpty) return null;
    if (!_scrollController.hasClients) return _messages.length - 1;
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (!maxExtent.isFinite || maxExtent <= 0) {
      return (_messages.length - 1).clamp(0, _messages.length - 1);
    }
    final pixels = _scrollController.position.pixels;
    if (!pixels.isFinite) return _messages.length - 1;
    final fraction = (pixels / maxExtent).clamp(0.0, 1.0);
    return (fraction * (_messages.length - 1)).round().clamp(
      0,
      _messages.length - 1,
    );
  }

  String? _approximateViewportMessageId() {
    final index = _approximateViewportMessageIndex();
    if (index == null || index < 0 || index >= _messages.length) return null;
    return _messageIdOf(_messages[index]);
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
    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
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
      if (!mounted) return;
      setState(() {
        _serverSearchMessages = results;
        _serverSearchLoaded = true;
        _serverSearchLoading = false;
      });
      _recomputeSearchResults(keepCurrent: false);
    } catch (_) {
      if (_searchQuery.trim() != query) return;
      if (!mounted) return;
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
      shelfLabel: _reservedShelfDisplayOfMeta(meta),
      price: (meta['price'] ?? '').toString(),
    );
  }

  List<Map<String, dynamic>> _visibleMessages() {
    final visible = _dedupeMessages(_messagesMatchingCurrentSearch());
    if (_isReservedOrdersChat()) {
      visible.sort(_compareReservedTimelineMessages);
      return visible;
    }
    visible.sort(_compareByCreatedAt);
    return visible;
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
    _manualBottomLockSuppressed = true;
    _stickToBottom = false;
    _clearBottomSettle();
    if (_useApproximateViewportTracking) {
      final moved = await _approximateScrollToMessageId(messageId);
      if (moved) {
        _handleScroll();
        _markSearchHitHighlighted(messageId);
      }
      return;
    }
    final targetContext = await _resolveMessageContextWithScroll(messageId);
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 240),
      alignment: 0.18,
      curve: Curves.easeOutCubic,
    );
    _handleScroll();
    _markSearchHitHighlighted(messageId);
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

  bool _shouldShowTypingIndicator() {
    return _isDirectMessageChat() &&
        !_isReservedOrdersChat() &&
        _activeRemoteTypingUserIds().isNotEmpty;
  }

  Widget _buildTypingIndicatorPlaceholder(
    ThemeData theme, {
    required int userCount,
  }) {
    final label = userCount > 1 ? 'Печатают...' : 'Печатает...';
    final reducedMotion =
        performanceModeNotifier.value ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    return PhoenixSlideFadeIn(
      enabled: !reducedMotion,
      beginOffset: const Offset(0, 12),
      duration: const Duration(milliseconds: 260),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.78,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.18),
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TypingDots(
                    color: theme.colorScheme.primary,
                    enabled: !reducedMotion,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _buildTimeline(
    List<Map<String, dynamic>> messages,
  ) {
    if (_isReservedOrdersChat()) {
      final sorted = [...messages]..sort(_compareReservedTimelineMessages);
      final items = <Map<String, dynamic>>[];
      String? prevDate;
      final unreadDividerMessageId =
          messengerShouldShowUnreadDivider(
            searchQuery: _searchQuery,
            firstUnreadMessageId: _firstUnreadMessageId,
          )
          ? (_firstUnreadMessageId ?? '').trim()
          : '';
      var insertedUnreadDivider = false;
      for (final message in sorted) {
        final messageId = _messageIdOf(message);
        if (!insertedUnreadDivider &&
            unreadDividerMessageId.isNotEmpty &&
            messageId == unreadDividerMessageId) {
          items.add({'type': 'unread_divider', 'unread_count': _unreadCount});
          insertedUnreadDivider = true;
        }
        final createdAt = _parseDate(message['created_at']);
        final dateLabel = createdAt == null
            ? 'Без даты'
            : _formatDateLabel(createdAt);
        if (dateLabel != prevDate) {
          items.add({'type': 'date', 'label': dateLabel});
          prevDate = dateLabel;
        }
        items.add({'type': 'message', 'data': message});
      }
      return items;
    }

    final items = <Map<String, dynamic>>[];
    String? prevDate;
    final unreadDividerMessageId =
        messengerShouldShowUnreadDivider(
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
        items.add({'type': 'unread_divider', 'unread_count': _unreadCount});
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
    if (_shouldShowTypingIndicator()) {
      items.add({
        'type': 'typing_indicator',
        'user_count': _activeRemoteTypingUserIds().length,
      });
    }
    return items;
  }

  Widget _buildTimelineRowSafely(Map<String, dynamic> row) {
    try {
      final type = (row['type'] ?? '').toString();
      if (type == 'date') {
        return _buildDateDivider((row['label'] ?? 'Без даты').toString());
      }
      if (type == 'unread_divider') {
        return _buildUnreadDivider();
      }
      if (type == 'typing_indicator') {
        final userCount = int.tryParse('${row['user_count'] ?? 1}') ?? 1;
        return _buildTypingIndicatorPlaceholder(
          Theme.of(context),
          userCount: userCount,
        );
      }
      final rawData = row['data'];
      if (rawData is! Map) {
        throw StateError('timeline_row_data_missing');
      }
      final message = Map<String, dynamic>.from(rawData);
      return _buildMessageItem(message);
    } catch (error, stackTrace) {
      final rowType = (row['type'] ?? '').toString();
      final rawData = row['data'];
      final message = rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : null;
      final messageId = (message?['id'] ?? '').toString().trim();
      final kind =
          _metaMapOf(message?['meta'])['kind']?.toString().trim() ?? '';
      unawaited(
        MonitoringService.captureError(
          error,
          stackTrace,
          subsystem: 'chat',
          code: 'timeline_row_build_failed',
          details: <String, dynamic>{
            'chat_id': widget.chatId,
            'row_type': rowType,
            'message_id': messageId,
            'kind': kind,
          },
        ),
      );
      return _buildBrokenTimelineRow(messageId: messageId, kind: kind);
    }
  }

  Widget _buildBrokenTimelineRow({
    required String messageId,
    required String kind,
  }) {
    final theme = Theme.of(context);
    final subtitleParts = <String>[
      if (kind.isNotEmpty) 'Тип: $kind',
      if (messageId.isNotEmpty) 'ID: $messageId',
    ];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Сообщение не удалось отрисовать',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onErrorContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitleParts.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitleParts.join(' • '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _shouldUseUnreadJumpButton() {
    final hasUnreadAnchor =
        (_firstUnreadMessageId ?? '').trim().isNotEmpty &&
        _unreadCount > 0 &&
        !_searchMode;
    return hasUnreadAnchor && !_jumpedToFirstUnread;
  }

  Widget _buildUnreadDivider() {
    final unreadLabel = _unreadCount > 0
        ? 'Непрочитанные • $_unreadCount'
        : 'Непрочитанные';
    final theme = Theme.of(context);
    final reducedMotion =
        performanceModeNotifier.value ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    return PhoenixSlideFadeIn(
      enabled: !reducedMotion,
      beginOffset: const Offset(0, 10),
      child: PhoenixOneShotHighlight(
        enabled: !reducedMotion,
        color: theme.colorScheme.primary,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        duration: const Duration(milliseconds: 780),
        child: Padding(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.22),
                  ),
                ),
                child: Text(
                  unreadLabel,
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
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
    TextStyle? labelStyle,
    TextStyle? valueStyle,
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: backgroundColor ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.9),
        ),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label · ',
              style: (labelStyle ?? theme.textTheme.labelSmall)?.copyWith(
                color: foregroundColor ?? theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
            TextSpan(
              text: value,
              style: (valueStyle ?? theme.textTheme.labelSmall)?.copyWith(
                color: foregroundColor ?? theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPickupOnlyProductNotice(ThemeData theme) {
    final warningColor = theme.colorScheme.tertiary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: warningColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: warningColor.withValues(alpha: 0.34)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.storefront_outlined, size: 18, color: warningColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Только самовывоз',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _productCardSnapshotOf(Map<String, dynamic> metaMap) {
    return _metaMapOf(metaMap['card_snapshot']);
  }

  String _formatProductLabel(
    dynamic productCode,
    dynamic shelfNumber, {
    dynamic manualShelfLabel,
  }) {
    final code = int.tryParse('${productCode ?? ''}') ?? 0;
    final shelf = int.tryParse('${shelfNumber ?? ''}') ?? 0;
    final manualShelf = (manualShelfLabel ?? '').toString().trim();
    final codePart = code > 0 ? '$code' : '—';
    final shelfPart = manualShelf.isNotEmpty
        ? manualShelf
        : (shelf > 0 ? shelf.toString().padLeft(2, '0') : '—');
    return '$codePart--$shelfPart';
  }

  String? _resolveImageUrl(String? raw) {
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
  }

  String _attachmentTypeOf(Map<String, dynamic> meta) {
    return (meta['attachment_type'] ?? '').toString().trim().toLowerCase();
  }

  bool _isVideoNoteMeta(Map<String, dynamic> meta) {
    final raw = meta['is_video_note'];
    return raw == true || raw.toString().trim().toLowerCase() == 'true';
  }

  bool _isSingleEmojiText(String raw) {
    final text = raw.trim();
    if (text.isEmpty || RegExp(r'\s').hasMatch(text)) return false;
    final emojiPattern = RegExp(
      r'^(?:'
      r'[\u{1F1E6}-\u{1F1FF}]{2}|'
      r'(?:[\u{2600}-\u{27BF}]|[\u{1F300}-\u{1FAFF}])'
      r'(?:\uFE0F|[\u{1F3FB}-\u{1F3FF}])?'
      r'(?:\u200D(?:[\u{2600}-\u{27BF}]|[\u{1F300}-\u{1FAFF}])'
      r'(?:\uFE0F|[\u{1F3FB}-\u{1F3FF}])?)*'
      r')$',
      unicode: true,
    );
    return emojiPattern.hasMatch(text);
  }

  String _captionTextOf(
    Map<String, dynamic> message,
    Map<String, dynamic> meta,
  ) {
    final caption = (meta['caption'] ?? '').toString().trim();
    if (caption.isNotEmpty) return caption;
    final text = (message['text'] ?? '').toString().trim();
    if (text.toLowerCase() == 'фото' ||
        text.toLowerCase() == 'файл' ||
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

  Widget _buildSingleEmojiMedallion(
    ThemeData theme,
    String emoji, {
    required bool fromMe,
  }) {
    final media = MediaQuery.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final size = min(
      media.size.width * 0.38,
      184.0,
    ).clamp(128.0, 184.0).toDouble();
    final accent = fromMe ? theme.colorScheme.primary : const Color(0xFF20D6E9);
    final warmAccent = const Color(0xFFFF8848);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: isDark ? 0.20 : 0.12),
            warmAccent.withValues(alpha: isDark ? 0.11 : 0.08),
            theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: isDark ? 0.92 : 0.96,
            ),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.32), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.22 : 0.12),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Text(
        emoji,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: size * 0.54, height: 1),
      ),
    );
  }

  String? _voiceUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(meta['voice_url']?.toString());
  }

  int _voiceDurationMsOf(Map<String, dynamic> meta) {
    return int.tryParse('${meta['voice_duration_ms'] ?? 0}') ?? 0;
  }

  List<double> _waveformPeaksOf(Map<String, dynamic> meta) {
    final raw = meta['waveform_peaks'];
    if (raw is! List || raw.isEmpty) return const <double>[];
    final peaks = raw
        .map(
          (value) =>
              value is num ? value.toDouble() : double.tryParse('$value'),
        )
        .whereType<double>()
        .where((value) => value.isFinite && value >= 0)
        .toList(growable: false);
    if (peaks.isEmpty) return const <double>[];
    final maxPeak = peaks.reduce(math.max);
    if (maxPeak <= 0) return const <double>[];
    return peaks
        .map((value) => 4 + ((value / maxPeak).clamp(0.0, 1.0) * 12))
        .toList(growable: false);
  }

  String? _videoUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(meta['video_url']?.toString());
  }

  int _videoDurationMsOf(Map<String, dynamic> meta) {
    return int.tryParse('${meta['video_duration_ms'] ?? 0}') ?? 0;
  }

  String? _videoPreviewImageUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(
      (meta['video_preview_image_url'] ?? meta['preview_image_url'])
          ?.toString(),
    );
  }

  String _attachmentProcessingStateOf(Map<String, dynamic> meta) {
    return (meta['attachment_processing_state'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
  }

  String? _fileUrlOf(Map<String, dynamic> meta) {
    return _resolveImageUrl(meta['file_url']?.toString());
  }

  String _fileNameOf(Map<String, dynamic> meta) {
    final direct = (meta['file_name'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final rawUrl = (meta['file_url'] ?? '').toString().trim();
    if (rawUrl.isEmpty) return 'Файл';
    final uri = Uri.tryParse(rawUrl);
    final lastSegment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last.trim()
        : rawUrl.split('/').last.trim();
    return lastSegment.isEmpty ? 'Файл' : lastSegment;
  }

  int _fileSizeOf(Map<String, dynamic> meta) {
    return int.tryParse('${meta['file_size'] ?? 0}') ?? 0;
  }

  String _formatFileSizeLabel(int bytes) {
    if (bytes <= 0) return 'Размер неизвестен';
    const units = <String>['Б', 'КБ', 'МБ', 'ГБ'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final digits = value >= 100 || unitIndex == 0
        ? 0
        : value >= 10
        ? 1
        : 2;
    return '${value.toStringAsFixed(digits)} ${units[unitIndex]}';
  }

  Future<void> _openFileAttachment(String? rawUrl) async {
    final trimmed = (rawUrl ?? '').trim();
    if (trimmed.isEmpty) return;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось открыть файл',
        tone: AppNoticeTone.error,
      );
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!opened && mounted) {
      showAppNotice(
        context,
        'Не удалось открыть файл',
        tone: AppNoticeTone.error,
      );
    }
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
    if (_isReservedOrder(message)) return 'Система';
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
    if (replyMessageId == null &&
        previewText.isEmpty &&
        previewSender.isEmpty) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: replyMessageId == null
          ? null
          : () => _jumpToMessageById(replyMessageId),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: fromMe
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.7,
                ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
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
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (ctx) {
          final sheetTheme = Theme.of(ctx);
          return SafeArea(
            child: PhoenixSlideFadeIn(
              beginOffset: const Offset(0, 26),
              duration: const Duration(milliseconds: 220),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.64,
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  decoration: BoxDecoration(
                    color: sheetTheme.colorScheme.surface.withValues(
                      alpha: 0.96,
                    ),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: sheetTheme.colorScheme.outlineVariant,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.16),
                        blurRadius: 28,
                        offset: const Offset(0, -8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 5,
                          decoration: BoxDecoration(
                            color: sheetTheme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            Icons.history_rounded,
                            color: sheetTheme.colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'История правок',
                            style: sheetTheme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (rows.isEmpty)
                        const Text('История пока пуста')
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: rows.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 18),
                            itemBuilder: (_, index) {
                              final row = rows[index];
                              final previousText = (row['previous_text'] ?? '')
                                  .toString()
                                  .trim();
                              final editedByName =
                                  (row['edited_by_name'] ?? 'Система')
                                      .toString()
                                      .trim();
                              final editedAt = formatDateTimeValue(
                                row['edited_at'],
                              );
                              return PhoenixSlideFadeIn(
                                beginOffset: const Offset(0, 10),
                                duration: Duration(
                                  milliseconds: 180 + index * 35,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      margin: const EdgeInsets.only(top: 7),
                                      decoration: BoxDecoration(
                                        color: sheetTheme.colorScheme.primary
                                            .withValues(alpha: 0.78),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '$editedByName • $editedAt',
                                            style: sheetTheme
                                                .textTheme
                                                .labelMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            previousText.isEmpty
                                                ? 'Без текста'
                                                : previousText,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
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
      'queued' => (
        Icons.cloud_queue_outlined,
        theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.78),
      ),
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

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        );
      },
      child: Icon(icon, key: ValueKey<String>(status), size: 16, color: color),
    );
  }

  Widget _buildLocalLifecycleRow(
    ThemeData theme,
    Map<String, dynamic> message,
    Map<String, dynamic> meta,
  ) {
    if (meta['local_only'] != true) return const SizedBox.shrink();
    final status = (meta['delivery_status'] ?? '').toString().trim();
    if (status != 'queued' &&
        status != 'uploading' &&
        status != 'sending' &&
        status != 'error') {
      return const SizedBox.shrink();
    }

    final retryable = _isRetryableFailedMessage(message);
    final progressRaw = meta['local_upload_progress'];
    final progress = progressRaw is num
        ? progressRaw.toDouble().clamp(0.0, 1.0)
        : double.tryParse(
            '${meta['local_upload_progress'] ?? ''}',
          )?.clamp(0.0, 1.0);
    final progressPercent = progress == null
        ? null
        : (progress * 100).round().clamp(0, 100);
    final label = messengerLocalDeliveryLabel(
      status,
      progress: progressPercent == null ? null : progress,
      retryable: retryable,
    );
    final chipBackground = switch (status) {
      'queued' => theme.colorScheme.secondaryContainer,
      'uploading' || 'sending' => theme.colorScheme.surfaceContainerHigh,
      'error' => theme.colorScheme.errorContainer,
      _ => theme.colorScheme.surfaceContainerHigh,
    };
    final chipForeground = switch (status) {
      'queued' => theme.colorScheme.onSecondaryContainer,
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
        : Icon(
            status == 'queued'
                ? Icons.cloud_queue_outlined
                : Icons.error_outline_rounded,
            size: 14,
          );

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
              border: Border.all(color: chipForeground.withValues(alpha: 0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme(
                  data: IconThemeData(color: chipForeground, size: 14),
                  child: status == 'uploading'
                      ? PhoenixProgressRingIcon(
                          icon: Icons.cloud_upload_outlined,
                          progress: progress,
                          size: 18,
                          iconSize: 10,
                          color: chipForeground,
                          backgroundColor: Colors.transparent,
                        )
                      : chipChild,
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
          if (status == 'queued' || status == 'error')
            TextButton.icon(
              onPressed: () => _deletePersistentOutboxMessage(message),
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: const Text('Удалить'),
            ),
        ],
      ),
    );
  }

  Widget _buildAttachmentStateRow(ThemeData theme, Map<String, dynamic> meta) {
    final state = _attachmentProcessingStateOf(meta);
    if (state.isEmpty || state == 'ready') {
      return const SizedBox.shrink();
    }

    final isFailed = state == 'failed';
    final label = isFailed
        ? 'Ошибка обработки вложения'
        : 'Вложение обрабатывается';
    final icon = isFailed
        ? Icons.error_outline_rounded
        : Icons.hourglass_top_rounded;
    final background = isFailed
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHigh;
    final foreground = isFailed
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isFailed)
              Icon(icon, size: 14, color: foreground)
            else
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(foreground),
                ),
              ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
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
          'Будут удалены все сообщения в чате "$_chatTitle". Это действие необратимо.',
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
      case 'file':
        final fileName = _fileNameOf(meta).trim();
        if (caption.isNotEmpty) return caption;
        return fileName.isNotEmpty ? fileName : 'Файл';
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
      final chats =
          (await loadChatsCollection())
              .where((chat) {
                final kind = (_chatStateMapOf(chat['settings'])['kind'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                return kind != 'reserved_orders' &&
                    kind != 'delivery' &&
                    kind != 'delivery_chat';
              })
              .where(
                (chat) => (chat['id'] ?? '').toString().trim() != widget.chatId,
              )
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
                      final title =
                          (chat['display_title'] ?? chat['title'] ?? 'Чат')
                              .toString()
                              .trim();
                      final subtitle = (chat['last_message'] ?? '')
                          .toString()
                          .trim();
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
      final maxPanelHeight =
          MediaQuery.sizeOf(ctx).height * (desktop ? 0.82 : 0.72);
      final maxActionListHeight = math.max(
        96.0,
        maxPanelHeight - (reactionChoices.isNotEmpty ? 118.0 : 34.0),
      );
      final topBarColor = theme.brightness == Brightness.dark
          ? const Color(0xFF172235).withValues(alpha: 0.92)
          : theme.colorScheme.primaryContainer.withValues(alpha: 0.74);
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: (color ?? theme.colorScheme.primary).withValues(
                alpha: 0.10,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 19, color: color),
          ),
          title: Text(
            title,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          onTap: () => Navigator.of(ctx).pop(value),
        );
      }

      Widget sheetHandle() {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Center(
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.22,
                ),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        );
      }

      Widget reactionOption(String emoji, {required bool mine}) {
        final selectedColor = theme.colorScheme.primary.withValues(alpha: 0.18);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: mine ? 1 : 0),
            duration: const Duration(milliseconds: 210),
            curve: Curves.easeOutBack,
            builder: (context, value, child) {
              return Transform.scale(scale: 1 + value * 0.08, child: child);
            },
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => Navigator.of(ctx).pop('react:$emoji'),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: mine ? selectedColor : Colors.transparent,
                  border: Border.all(
                    color: mine
                        ? theme.colorScheme.primary.withValues(alpha: 0.42)
                        : Colors.transparent,
                  ),
                  boxShadow: mine
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.16,
                            ),
                            blurRadius: 16,
                            spreadRadius: 3,
                          ),
                        ]
                      : null,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
          ),
        );
      }

      Widget moreReactionOption() {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => Navigator.of(ctx).pop('react:more'),
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surface.withValues(alpha: 0.86),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Icon(
                Icons.add_reaction_outlined,
                size: 23,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
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
          maxHeight: maxPanelHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sheetHandle(),
            glass(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (reactionChoices.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                      decoration: BoxDecoration(
                        color: topBarColor,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(24),
                          topRight: const Radius.circular(24),
                          bottomLeft: Radius.circular(hasMenuItems ? 18 : 24),
                          bottomRight: Radius.circular(hasMenuItems ? 18 : 24),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 6, bottom: 5),
                            child: Text(
                              'Реакция',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                ...reactionChoices.map((emoji) {
                                  final mine =
                                      currentUserId.isNotEmpty &&
                                      reactionByUser[currentUserId] == emoji;
                                  return reactionOption(emoji, mine: mine);
                                }),
                                moreReactionOption(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (hasMenuItems)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: maxActionListHeight,
                      ),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        children: actionWidgets,
                      ),
                    ),
                ],
              ),
            ),
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
              child: PhoenixSlideFadeIn(
                beginOffset: const Offset(0, 36),
                duration: const Duration(milliseconds: 220),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: buildActionPanel(ctx, desktop: false),
                ),
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

  Widget _buildFileAttachment(
    ThemeData theme,
    Map<String, dynamic> meta, {
    required Color textColor,
  }) {
    final fileUrl = _fileUrlOf(meta);
    final fileName = _fileNameOf(meta);
    final fileSize = _fileSizeOf(meta);
    final mimeType = (meta['file_mime_type'] ?? '').toString().trim();
    final extension = fileName.contains('.')
        ? fileName.split('.').last.trim().toUpperCase()
        : '';
    final badgeLabel = extension.isNotEmpty
        ? extension
        : (mimeType.isNotEmpty
              ? mimeType.split('/').last.toUpperCase()
              : 'FILE');

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: fileUrl == null ? null : () => _openFileAttachment(fileUrl),
      child: Ink(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.insert_drive_file_rounded,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
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
                          badgeLabel,
                          style: TextStyle(
                            color: textColor.withValues(alpha: 0.78),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _formatFileSizeLabel(fileSize),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor.withValues(alpha: 0.72),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.open_in_new_rounded,
              size: 20,
              color: textColor.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualMediaLoadPlaceholder(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: onTap,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Загрузить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceAttachment(
    ThemeData theme,
    Map<String, dynamic> message,
    Map<String, dynamic> meta,
  ) {
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
    final waveform = _buildVoiceWaveform(
      theme,
      _waveformPeaksOf(meta),
      messageId,
      progress,
    );
    final isDark = theme.brightness == Brightness.dark;
    final shellColor = isDark
        ? const Color(0xFF1D1C2A).withValues(alpha: 0.96)
        : Color.alphaBlend(
            theme.colorScheme.primary.withValues(alpha: 0.08),
            theme.colorScheme.surface,
          );
    final voiceTextColor = isDark
        ? Colors.white.withValues(alpha: 0.88)
        : theme.colorScheme.onSurface;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 520),
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.fromLTRB(9, 9, 13, 9),
        decoration: BoxDecoration(
          color: shellColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.26),
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.10),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.06),
              blurRadius: 20,
              offset: const Offset(0, 10),
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
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF3B82FF), Color(0xFF20D6E9)],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B82FF).withValues(alpha: 0.26),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
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
            Expanded(child: waveform),
            const SizedBox(width: 12),
            Text(
              isActive && currentPosition > Duration.zero
                  ? _formatDurationLabel(currentPosition)
                  : _formatDurationLabel(totalDuration),
              style: TextStyle(
                color: voiceTextColor,
                fontWeight: FontWeight.w800,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceWaveform(
    ThemeData theme,
    List<double> waveformBars,
    String seed,
    double progress,
  ) {
    final bars = waveformBars.isNotEmpty
        ? waveformBars
        : _voiceWaveHeights(seed, 30);
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
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 170),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.72, end: 1).animate(curved),
              child: RotationTransition(
                turns: Tween<double>(begin: -0.08, end: 0).animate(curved),
                child: child,
              ),
            ),
          );
        },
        child: Icon(
          icon,
          key: ValueKey<int>(icon.codePoint),
          color: filled ? Colors.white : color,
          size: size * 0.42,
        ),
      ),
    );
    if (onTap == null) return bubble;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: bubble,
    );
  }

  Widget _buildRecordingLockMorphBubble({
    required IconData sourceIcon,
    required bool locked,
    required double lockProgress,
    required VoidCallback? onTap,
    required Color color,
    double size = 54,
  }) {
    final reduceMotion =
        performanceModeNotifier.value ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    final rawProgress = locked
        ? 1.0
        : ((lockProgress - 0.16) / 0.84).clamp(0.0, 1.0).toDouble();
    final targetProgress = reduceMotion
        ? (locked ? 1.0 : 0.0)
        : Curves.easeOutCubic.transform(rawProgress);

    Widget buildBubble(double progress) {
      final iconSize = size * 0.42;
      final sourceOpacity = (1 - progress * 1.12).clamp(0.0, 1.0).toDouble();
      final arrowOpacity = ((progress - 0.18) / 0.82)
          .clamp(0.0, 1.0)
          .toDouble();
      final sourceScale = (1 - progress * 0.30).clamp(0.68, 1.0).toDouble();
      final arrowScale = (0.72 + progress * 0.30).clamp(0.72, 1.05).toDouble();
      final sourceOffset = Offset(0, -8 * progress);
      final arrowOffset = Offset(0, 7 * (1 - progress));
      final bubbleScale = 1 + math.sin(progress * math.pi) * 0.08;
      final glowColor = Color.lerp(color, const Color(0xFF35D399), progress)!;

      final bubble = AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: glowColor.withValues(alpha: 0.26 + progress * 0.10),
              blurRadius: 16 + progress * 8,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Transform.scale(
          scale: bubbleScale,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: sourceOpacity,
                child: Transform.translate(
                  offset: sourceOffset,
                  child: Transform.scale(
                    scale: sourceScale,
                    child: Icon(
                      sourceIcon,
                      color: Colors.white,
                      size: iconSize,
                    ),
                  ),
                ),
              ),
              Opacity(
                opacity: arrowOpacity,
                child: Transform.translate(
                  offset: arrowOffset,
                  child: Transform.scale(
                    scale: arrowScale,
                    child: const Icon(
                      Icons.arrow_upward_rounded,
                      color: Colors.white,
                      size: 23,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      if (onTap == null) return bubble;
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: bubble,
      );
    }

    return TweenAnimationBuilder<double>(
      duration: reduceMotion
          ? Duration.zero
          : locked
          ? const Duration(milliseconds: 240)
          : const Duration(milliseconds: 70),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(end: targetProgress),
      builder: (context, progress, _) => buildBubble(progress),
    );
  }

  Widget _buildComposerMediaFlipIcon({
    required bool videoMode,
    required Color color,
    required double size,
  }) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations == true;
    final iconSize = size * 0.42;
    Widget iconStack(double t) {
      final micOpacity = (1 - t).clamp(0.0, 1.0);
      final videoOpacity = t.clamp(0.0, 1.0);
      return SizedBox(
        width: size,
        height: size,
        child: Transform.rotate(
          angle: math.pi * t,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: micOpacity,
                child: Transform.translate(
                  offset: Offset(0, -18 * t),
                  child: Transform.rotate(
                    angle: -math.pi * t,
                    child: Icon(
                      Icons.mic_rounded,
                      color: color,
                      size: iconSize,
                    ),
                  ),
                ),
              ),
              Opacity(
                opacity: videoOpacity,
                child: Transform.translate(
                  offset: Offset(0, 18 * (1 - t)),
                  child: Transform.rotate(
                    angle: -math.pi * t,
                    child: Icon(
                      Icons.radio_button_unchecked_rounded,
                      color: color,
                      size: iconSize,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (reduceMotion) {
      return Icon(
        videoMode ? Icons.radio_button_unchecked_rounded : Icons.mic_rounded,
        color: color,
        size: iconSize,
      );
    }
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(end: videoMode ? 1 : 0),
      builder: (context, t, _) {
        return iconStack(t);
      },
    );
  }

  Widget _buildElasticRecordingAction({
    required Widget child,
    required double dragDx,
    required double dragDy,
    required double lockProgress,
    required double cancelProgress,
    required bool locked,
    required Color color,
    required _RecordingActionVisualPhase visualPhase,
    required Animation<double> hoverAnimation,
  }) {
    final reduceMotion =
        performanceModeNotifier.value ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    final activeProgress = max(
      lockProgress,
      cancelProgress,
    ).clamp(0.0, 1.0).toDouble();
    final isDusting = visualPhase == _RecordingActionVisualPhase.cancellingDust;
    final isLockedHover =
        locked || visualPhase == _RecordingActionVisualPhase.lockedHover;
    final isCancelling = isDusting || cancelProgress > lockProgress;
    final glowColor = isCancelling
        ? const Color(0xFFFF4D5B)
        : locked
        ? const Color(0xFF35D399)
        : color;
    final easedDx = dragDx.clamp(-88.0, 0.0).toDouble();
    final easedDy = dragDy.clamp(-116.0, 0.0).toDouble();

    List<Widget> dustParticles(double progress) {
      if (reduceMotion) return const <Widget>[];
      const vectors = <Offset>[
        Offset(-1.00, -0.42),
        Offset(-0.88, 0.10),
        Offset(-0.74, 0.52),
        Offset(-0.50, -0.70),
        Offset(-0.28, 0.72),
        Offset(0.08, -0.52),
        Offset(0.22, 0.34),
      ];
      return List<Widget>.generate(vectors.length, (index) {
        final vector = vectors[index];
        final delay = index * 0.035;
        final t = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0).toDouble();
        final size = 3.0 + (index % 3) * 1.4;
        final distance = 18 + index * 2.2 + t * 46;
        final opacity = ((1 - t) * (0.86 - index * 0.052)).clamp(0.0, 1.0);
        return Positioned(
          left: 27 + vector.dx * distance - size / 2,
          top: 27 + vector.dy * distance * 0.72 - size / 2,
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: 0.72 + t * 0.44,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      Color.lerp(glowColor, Colors.white, 0.22) ?? Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: glowColor.withValues(alpha: 0.22),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      });
    }

    Widget buildFrame(double hoverValue, double dustProgress) {
      final expandedHitArea = isLockedHover || isDusting;
      final hitWidth = expandedHitArea ? 104.0 : 54.0;
      final hitHeight = expandedHitArea ? 146.0 : 54.0;
      final hoverOffset = reduceMotion || !isLockedHover
          ? Offset.zero
          : Offset(
              math.sin(hoverValue * math.pi * 2) * 5.0,
              math.cos(hoverValue * math.pi * 2) * 2.4,
            );
      final dragOffset = Offset(easedDx * 0.46, easedDy * 0.66);
      final baseOffset = isDusting
          ? Offset(
              dragOffset.dx - dustProgress * 88,
              dragOffset.dy * 0.42 - dustProgress * 8,
            )
          : isLockedHover
          ? const Offset(0, -78)
          : dragOffset;
      final opacity = isDusting
          ? (1 - dustProgress * 0.96).clamp(0.0, 1.0).toDouble()
          : 1.0;
      final scale = isDusting
          ? (1 - dustProgress * 0.30).clamp(0.68, 1.0).toDouble()
          : isLockedHover
          ? 1.04
          : 1.0;
      final glowSize = isLockedHover
          ? 88.0 + math.sin(hoverValue * math.pi * 2) * 4.0
          : 54.0 + activeProgress * 36.0;
      final glowOpacity = reduceMotion
          ? 0.0
          : isDusting
          ? (1 - dustProgress) * 0.46
          : isLockedHover
          ? 0.44
          : activeProgress * 0.52;
      final slideDuration = isDusting
          ? Duration.zero
          : reduceMotion
          ? Duration.zero
          : isLockedHover
          ? const Duration(milliseconds: 260)
          : Duration.zero;

      return AnimatedSize(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: hitWidth,
          height: hitHeight,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              AnimatedSlide(
                duration: slideDuration,
                curve: Curves.easeOutCubic,
                offset: Offset(
                  (baseOffset.dx + hoverOffset.dx * 0.2) / 54,
                  (baseOffset.dy + hoverOffset.dy * 0.2) / 54,
                ),
                child: IgnorePointer(
                  child: Opacity(
                    opacity: glowOpacity.clamp(0.0, 1.0).toDouble(),
                    child: Container(
                      width: glowSize,
                      height: glowSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            glowColor.withValues(alpha: 0.28),
                            glowColor.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.48, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (isDusting)
                Transform.translate(
                  offset: baseOffset,
                  child: SizedBox(
                    width: 54,
                    height: 54,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: dustParticles(dustProgress),
                    ),
                  ),
                ),
              AnimatedSlide(
                duration: slideDuration,
                curve: Curves.easeOutCubic,
                offset: Offset(baseOffset.dx / 54, baseOffset.dy / 54),
                child: Transform.translate(
                  offset: hoverOffset,
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.scale(scale: scale, child: child),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (isDusting) {
      return TweenAnimationBuilder<double>(
        key: const ValueKey<String>('recording-cancel-dust'),
        duration: reduceMotion ? Duration.zero : _recordingCancelDustDuration,
        curve: Curves.easeOutCubic,
        tween: Tween<double>(begin: 0, end: 1),
        builder: (context, dustProgress, _) =>
            buildFrame(hoverAnimation.value, dustProgress),
      );
    }
    if (isLockedHover) {
      return AnimatedBuilder(
        animation: hoverAnimation,
        builder: (context, _) => buildFrame(hoverAnimation.value, 0),
      );
    }
    return buildFrame(hoverAnimation.value, 0);
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
    final isCancellingDust =
        _voiceRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust;
    final slideCancelText =
        !_voiceRecordingLocked && cancelProgress > lockProgress;
    final cancelTextShift = _voiceRecordingLocked
        ? 0.0
        : (slideCancelText ? _recordingDragDx.clamp(-54, 0).toDouble() : 0.0);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Row(
          children: [
            Expanded(
              child: IgnorePointer(
                ignoring: isCancellingDust,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  opacity: isCancellingDust ? 0 : 1,
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
                        SizedBox(
                          width: 74,
                          child: PhoenixLiveWaveform(
                            height: 22,
                            barCount: 16,
                            color: Colors.white,
                            enabled: !performanceModeNotifier.value,
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
                                      color: Colors.white.withValues(
                                        alpha: 0.55,
                                      ),
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
                              onPressed: () =>
                                  unawaited(_cancelVoiceRecording()),
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
              ),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_voiceRecordingLocked && !isCancellingDust)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildRecordingHintChip(
                      icon: Icons.lock_outline_rounded,
                      label: 'Вверх — зафиксировать',
                      progress: max(lockProgress, 0.20),
                    ),
                  ),
                Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) =>
                      _handleRecordingPointerStart(event.position),
                  onPointerMove: (event) =>
                      _handleRecordingPointerMove(event.position),
                  onPointerUp: (_) => _handleComposerMediaPanEnd(),
                  onPointerCancel: (_) => _handleComposerMediaPanCancel(),
                  child: _buildElasticRecordingAction(
                    dragDx: _recordingDragDx,
                    dragDy: _recordingDragDy,
                    lockProgress: lockProgress,
                    cancelProgress: cancelProgress,
                    locked: _voiceRecordingLocked,
                    color: const Color(0xFF2F80FF),
                    visualPhase: _voiceRecordingVisualPhase,
                    hoverAnimation: _recordingHoverController,
                    child: _buildRecordingLockMorphBubble(
                      sourceIcon: Icons.mic_rounded,
                      locked: _voiceRecordingLocked,
                      lockProgress: lockProgress,
                      onTap: _voiceRecordingLocked
                          ? () => unawaited(_stopVoiceRecordingAndSend())
                          : null,
                      color: const Color(0xFF2F80FF),
                    ),
                  ),
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
    } else if (_webVideoNoteRecording) {
      child = ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: WebVideoNoteCaptureService.previewWidget(
            key: ValueKey(
              'web-video-note-preview-${_videoRecordingStartedAt?.millisecondsSinceEpoch ?? 0}',
            ),
          ),
        ),
      );
    } else if (_nativeVideoNoteRecording && _nativeVideoPreviewFrame != null) {
      child = ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: RepaintBoundary(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(-1, 1, 1),
              child: Image.memory(
                _nativeVideoPreviewFrame!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
              ),
            ),
          ),
        ),
      );
    } else if (_nativeVideoNoteRecording || _webVideoNoteRecording) {
      child = Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3C2A68), Color(0xFF241631)],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_rounded, color: Colors.white, size: 42),
            const SizedBox(height: 10),
            Text(
              'Запись',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
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
    final isCancellingDust =
        _videoRecordingVisualPhase ==
        _RecordingActionVisualPhase.cancellingDust;
    final slideCancelText =
        !_videoRecordingLocked && cancelProgress > lockProgress;
    final cancelTextShift = _videoRecordingLocked
        ? 0.0
        : (slideCancelText
              ? _videoRecordingDragDx.clamp(-54, 0).toDouble()
              : 0.0);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Row(
          children: [
            IgnorePointer(
              ignoring: isCancellingDust,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                opacity: isCancellingDust ? 0 : 1,
                child: _buildComposerActionBubble(
                  icon: Icons.cameraswitch_rounded,
                  onTap: _videoRecording
                      ? null
                      : () => unawaited(_switchVideoCameraLens()),
                  color: Colors.white,
                  size: 44,
                  filled: false,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: IgnorePointer(
                ignoring: isCancellingDust,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  opacity: isCancellingDust ? 0 : 1,
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
                                      color: Colors.white.withValues(
                                        alpha: 0.55,
                                      ),
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
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_videoRecordingLocked && !isCancellingDust)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildRecordingHintChip(
                      icon: Icons.lock_outline_rounded,
                      label: 'Вверх — зафиксировать',
                      progress: max(lockProgress, 0.20),
                    ),
                  ),
                Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) =>
                      _handleRecordingPointerStart(event.position),
                  onPointerMove: (event) =>
                      _handleRecordingPointerMove(event.position),
                  onPointerUp: (_) => _handleComposerMediaPanEnd(),
                  onPointerCancel: (_) => _handleComposerMediaPanCancel(),
                  child: _buildElasticRecordingAction(
                    dragDx: _videoRecordingDragDx,
                    dragDy: _videoRecordingDragDy,
                    lockProgress: lockProgress,
                    cancelProgress: cancelProgress,
                    locked: _videoRecordingLocked,
                    color: const Color(0xFF2F80FF),
                    visualPhase: _videoRecordingVisualPhase,
                    hoverAnimation: _recordingHoverController,
                    child: _buildRecordingLockMorphBubble(
                      sourceIcon: Icons.radio_button_unchecked_rounded,
                      locked: _videoRecordingLocked,
                      lockProgress: lockProgress,
                      onTap: _videoRecordingLocked
                          ? () => unawaited(_stopVideoCircleRecordingAndSend())
                          : null,
                      color: const Color(0xFF2F80FF),
                    ),
                  ),
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
    Map<String, dynamic> meta,
  ) {
    final videoUrl = _videoUrlOf(meta);
    final previewImageUrl = _videoPreviewImageUrlOf(meta);
    final durationMs = _videoDurationMsOf(meta);
    final messageId = message['id']?.toString().trim() ?? '';
    final canAutoLoadVideo = _canAutoLoadMedia(
      message,
      kind: 'video',
      fallbackToken: videoUrl ?? previewImageUrl ?? messageId,
    );
    final accent = theme.colorScheme.primary;
    final isActive = _activeVideoNoteMessageId == messageId;
    final useInlineWebVideo = kIsWeb && videoUrl != null;
    final controller = isActive ? _inlineVideoNoteController : null;
    final videoDurationCacheKey = videoUrl?.trim();
    final cachedVideoDuration =
        videoDurationCacheKey == null || videoDurationCacheKey.isEmpty
        ? null
        : _videoNoteDurationCache[videoDurationCacheKey];
    const orbSize = 196.0;
    const ringPadding = 8.0;
    const ringSize = orbSize + ringPadding * 2;
    const orbLayoutWidth = ringSize + 38;
    const orbLayoutHeight = ringSize + 10;

    if (!canAutoLoadVideo) {
      return SizedBox(
        width: 196,
        child: _buildManualMediaLoadPlaceholder(
          theme,
          icon: Icons.videocam_outlined,
          title: 'Видео ожидает загрузки',
          subtitle: 'Автозагрузка видео сейчас отключена политикой сети.',
          onTap: () => _allowManualMediaLoad(
            message,
            kind: 'video',
            fallbackToken: videoUrl ?? previewImageUrl ?? messageId,
          ),
        ),
      );
    }

    Widget buildVideoOrb({
      required Widget content,
      required String durationLabel,
    }) {
      Widget durationBadge() {
        return IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Text(
              durationLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      }

      return SizedBox(
        width: orbLayoutWidth,
        height: orbLayoutHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: ringSize,
              height: ringSize,
              child: Container(
                padding: const EdgeInsets.all(ringPadding),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    startAngle: -math.pi * 0.62,
                    endAngle: math.pi * 1.38,
                    colors: const [
                      Color(0xFFFF6B1A),
                      Color(0xFFFFA53D),
                      Color(0xFFFFC36A),
                      Color(0xFFFF7A2F),
                      Color(0xFFFF6B1A),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF8A2A).withValues(alpha: 0.22),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 24,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0F131B),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
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
                                    Colors.black.withValues(alpha: 0.04),
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.18),
                                  ],
                                  stops: const [0, 0.60, 1],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(right: 0, bottom: 0, child: durationBadge()),
          ],
        ),
      );
    }

    Duration displayDuration() {
      if (cachedVideoDuration != null && cachedVideoDuration > Duration.zero) {
        return cachedVideoDuration;
      }
      return Duration(milliseconds: durationMs > 0 ? durationMs : 0);
    }

    String staticDurationLabel() {
      final duration = displayDuration();
      return duration > Duration.zero
          ? _formatDurationLabel(duration)
          : '00:00';
    }

    void cacheResolvedDuration(Duration duration) {
      final key = videoDurationCacheKey;
      if (key == null || key.isEmpty || duration <= Duration.zero) return;
      final previous = _videoNoteDurationCache[key];
      if (previous != null &&
          (previous.inMilliseconds - duration.inMilliseconds).abs() < 250) {
        return;
      }
      if (!mounted) return;
      setState(() => _videoNoteDurationCache[key] = duration);
    }

    Widget fallbackVideoPoster() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.18, -0.34),
            radius: 0.92,
            colors: [
              accent.withValues(alpha: 0.28),
              const Color(0xFF1E2732),
              const Color(0xFF0C1118),
            ],
            stops: const [0.0, 0.52, 1.0],
          ),
        ),
      );
    }

    Widget inactiveVideoBackdrop() {
      final videoPoster = videoUrl == null || kIsWeb
          ? fallbackVideoPoster()
          : _VideoNotePoster(
              key: ValueKey('video-note-poster-$videoUrl'),
              videoUrl: videoUrl,
              fallback: fallbackVideoPoster(),
              onDurationResolved: cacheResolvedDuration,
            );
      return Stack(
        children: [
          Positioned.fill(child: fallbackVideoPoster()),
          if (previewImageUrl != null)
            Positioned.fill(
              child: AdaptiveNetworkImage(
                previewImageUrl,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => videoPoster,
              ),
            )
          else if (videoUrl != null && !kIsWeb)
            Positioned.fill(child: videoPoster),
          Positioned.fill(
            child: ClipOval(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.25, -0.35),
                    radius: 1.0,
                    colors: [
                      Colors.white.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
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
        );
      }

      final activeController = controller;
      if (activeController == null) {
        return buildVideoOrb(
          content: inactiveVideoBackdrop(),
          durationLabel: staticDurationLabel(),
        );
      }
      return ValueListenableBuilder<vp.VideoPlayerValue>(
        valueListenable: activeController,
        builder: (context, value, _) {
          final initialized = value.isInitialized;
          final totalDuration = initialized && value.duration > Duration.zero
              ? value.duration
              : Duration(milliseconds: durationMs > 0 ? durationMs : 0);
          final shownDuration = displayDuration();

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
            durationLabel: shownDuration > Duration.zero
                ? _formatDurationLabel(shownDuration)
                : totalDuration > Duration.zero
                ? _formatDurationLabel(totalDuration)
                : staticDurationLabel(),
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
        width: useInlineWebVideo ? 250 : orbLayoutWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            useInlineWebVideo
                ? InlineVideoNoteOrb(
                    videoUrl: videoUrl,
                    durationMs: durationMs,
                    accentColor: accent,
                  )
                : isActive
                ? activeVideoOrb()
                : buildVideoOrb(
                    content: inactiveVideoBackdrop(),
                    durationLabel: staticDurationLabel(),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingMessageShell(
    ThemeData theme, {
    required Map<String, dynamic> message,
    required Widget child,
  }) {
    final meta = _metaMapOf(message['meta']);
    final state = (meta['message_send_state'] ?? '').toString().trim();
    final deliveryStatus = (meta['delivery_status'] ?? '').toString().trim();
    final pending = state == 'local_pending' || deliveryStatus == 'sending';
    final failed = state == 'failed' || deliveryStatus == 'error';
    if (!pending && !failed) return child;
    final uploading = deliveryStatus == 'uploading';
    final progressRaw = meta['local_upload_progress'];
    final parsedProgress = progressRaw is num
        ? progressRaw.toDouble()
        : double.tryParse((progressRaw ?? '').toString());
    final progress = parsedProgress?.clamp(0.0, 1.0).toDouble();
    final accent = failed ? theme.colorScheme.error : theme.colorScheme.primary;
    final label = failed
        ? 'Не отправлено'
        : uploading
        ? 'Загрузка${progress == null ? '' : ' ${(progress * 100).round()}%'}'
        : deliveryStatus == 'queued'
        ? 'В очереди'
        : 'Отправка';
    final fromMe = _isOwnMessage(message);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      opacity: failed ? 0.82 : 0.9,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: fromMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          child,
          const SizedBox(height: 5),
          Container(
            width: 118,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: accent.withValues(alpha: 0.18)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (failed)
                  Icon(Icons.error_outline_rounded, size: 14, color: accent)
                else
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: progress,
                      color: accent,
                    ),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapNewMessageAppearance({
    required Widget child,
    required String messageId,
    required bool reducedMotion,
    required bool useChannelPostAppearance,
    required bool isAppearing,
    required bool fromMe,
  }) {
    // Visual extension point: replace this wrapper to change message entrance motion.
    if (reducedMotion) return child;
    if (useChannelPostAppearance) {
      return _ChannelPostRevealHighlight(
        key: ValueKey<String>('channel-post-appear-$messageId'),
        child: child,
      );
    }
    return TweenAnimationBuilder<double>(
      key: isAppearing
          ? ValueKey<String>('message-appear-$messageId')
          : ValueKey<String>('message-stable-$messageId'),
      tween: Tween<double>(begin: isAppearing ? 0 : 1, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, value, animatedChild) {
        final dx = fromMe ? 18 * (1 - value) : -28 * (1 - value);
        final dy = 10 * (1 - value);
        return Opacity(
          opacity: value.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(dx, dy),
            child: animatedChild,
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildDeliveryOfferStateRail(ThemeData theme, String status) {
    final normalized = status.trim().toLowerCase();
    final activeIndex = normalized == 'accepted'
        ? 2
        : normalized == 'declined'
        ? 1
        : 1;
    final steps = normalized == 'declined'
        ? const ['Предложено', 'Отказ']
        : const ['Предложено', 'Ожидаем', 'Подтверждено'];
    final accent = normalized == 'accepted'
        ? const Color(0xFF19A36B)
        : normalized == 'declined'
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Theme(
        data: theme.copyWith(
          colorScheme: theme.colorScheme.copyWith(primary: accent),
        ),
        child: PhoenixStepperStrip(steps: steps, activeIndex: activeIndex),
      ),
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> message) {
    final theme = Theme.of(context);
    final accessibilityReducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    final reducedMotion =
        performanceModeNotifier.value || accessibilityReducedMotion;
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
    final isFileMessage =
        !isDeleted &&
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        attachmentType == 'file';
    final imageUrl = _resolveImageUrl(metaMap['image_url']?.toString());
    final captionText = _captionTextOf(message, metaMap);
    final isVideoNoteMessage = isVideoMessage && _isVideoNoteMeta(metaMap);
    final isStandaloneImageMessage = isImageMessage && captionText.isEmpty;
    final isStandaloneVideoNote =
        isVideoMessage && (isVideoNoteMessage || captionText.isEmpty);
    final isStandaloneVoiceMessage = isVoiceMessage && captionText.isEmpty;
    final isSingleEmojiTextMessage =
        !isDeleted &&
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        !isImageMessage &&
        !isVoiceMessage &&
        !isVideoMessage &&
        !isFileMessage &&
        _isSingleEmojiText(text);
    final isStandaloneMediaMessage =
        isStandaloneImageMessage ||
        isStandaloneVideoNote ||
        isStandaloneVoiceMessage ||
        isSingleEmojiTextMessage;
    final catalogTexts = _extractCatalogTexts(text);
    final catalogSnapshot = _productCardSnapshotOf(metaMap);
    final productDescriptionText =
        (catalogSnapshot['short_description'] ??
                catalogTexts['description'] ??
                '')
            .toString()
            .trim();
    final productPickupOnly =
        _flagFrom(metaMap['pickup_only']) ||
        _flagFrom(catalogSnapshot['pickup_only']);
    final productLabel = (() {
      final fromMeta = metaMap['product_label']?.toString().trim() ?? '';
      if (fromMeta.isNotEmpty) return fromMeta;
      return _formatProductLabel(
        metaMap['product_code'],
        metaMap['product_shelf_number'] ?? metaMap['shelf_number'],
        manualShelfLabel: metaMap['manual_shelf_label'],
      );
    })();
    final price = metaMap['price']?.toString() ?? '—';
    final quantity = metaMap['quantity']?.toString() ?? '—';
    final quantityInt = int.tryParse(quantity) ?? 0;
    final isPlaced = _reservedIsPlaced(message);
    final isCancelled = _reservedIsCancelled(message);
    final isOversizePlaced = _reservedIsOversize(message);
    final reservedShelfDisplay = _reservedShelfDisplayOfMeta(metaMap);
    final shelf = isOversizePlaced
        ? 'Габарит'
        : (reservedShelfDisplay.isEmpty
              ? 'не назначена'
              : reservedShelfDisplay);
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
    final isAppearing =
        messageId.isNotEmpty && _appearingMessageIds.contains(messageId);
    final isChannelChat = _isChannelChat();
    final useChannelPostAppearance =
        (isChannelChat || _isPublicationLiveSyncChannel()) && isAppearing;

    final bubbleColor = hasBuy || isReservedOrder || isStandaloneMediaMessage
        ? Colors.transparent
        : isDeliveryOffer
        ? theme.colorScheme.surfaceContainerHigh
        : (fromMe
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest);
    final textColor =
        (!hasBuy && !isReservedOrder && !isStandaloneMediaMessage && fromMe)
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    final isPlainMessage =
        !hasBuy &&
        !isReservedOrder &&
        !isDeliveryOffer &&
        !isSupportFeedback &&
        !isImageMessage &&
        !isVoiceMessage &&
        !isVideoMessage &&
        !isFileMessage;
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
        ((isImageMessage ||
                isVideoMessage ||
                isVoiceMessage ||
                isFileMessage) &&
            captionText.isNotEmpty);
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
    final showChatIdentity =
        !hasBuy && !isReservedOrder && !isStandaloneMediaMessage;
    final timeLabel = _formatMessageTime(message['created_at']);
    final deliveryStatus = fromMe && !hasBuy && !isReservedOrder
        ? _deliveryStatusOf(message)
        : '';

    final edited = metaMap['edited'] == true;
    Widget buildMessageImage({double? width}) {
      if (imageUrl == null) return const SizedBox.shrink();
      final manualKeyAllowed = _canAutoLoadMedia(
        message,
        kind: 'image',
        fallbackToken: imageUrl,
      );
      if (!manualKeyAllowed) {
        return _buildManualMediaLoadPlaceholder(
          theme,
          icon: Icons.image_outlined,
          title: 'Фото ожидает загрузки',
          subtitle: 'Автозагрузка фото сейчас отключена политикой сети.',
          onTap: () => _allowManualMediaLoad(
            message,
            kind: 'image',
            fallbackToken: imageUrl,
          ),
        );
      }
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
        heroTag: _mediaViewerEntryIdForMessage(
          message,
          fallbackImageUrl: imageUrl,
        ),
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
    final reservedMarkPlacedDisabled =
        !_canMarkReservedOrderPlaced() || _markingPlaced || isCancelled;
    final reservedOversizeDisabled =
        !_canMarkReservedOrderPlaced() || isCancelled || _markingPlaced;
    final reservedShelfChangeDisabled =
        !_canMarkReservedOrderPlaced() ||
        _markingPlaced ||
        isOversizePlaced ||
        isCancelled;
    final cancelledTooltip = 'Клиент отказался от товара';
    Widget wrapCancelledTooltip(Widget child) {
      if (!isCancelled) return child;
      return Tooltip(message: cancelledTooltip, child: child);
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
          maxWidth: isStandaloneVideoNote
              ? 258
              : isStandaloneImageMessage
              ? defaultImageWidth
              : isStandaloneVoiceMessage
              ? (maxBubbleWidth > 560 ? 560 : maxBubbleWidth)
              : isSingleEmojiTextMessage
              ? min(maxBubbleWidth, 190.0)
              : (maxBubbleWidth > 620 ? 620 : maxBubbleWidth),
        ),
        padding: hasBuy || isReservedOrder || isStandaloneMediaMessage
            ? EdgeInsets.zero
            : const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bubbleColor,
          border: Border.all(
            color: hasBuy || isReservedOrder
                ? Colors.transparent
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(
            isStandaloneVideoNote
                ? 999
                : isStandaloneMediaMessage
                ? 18
                : hasBuy || isReservedOrder
                ? 24
                : 18,
          ),
          boxShadow: hasBuy || isReservedOrder
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(
                      alpha: isAppearing ? 0.18 : 0.06,
                    ),
                    blurRadius: isAppearing ? 28 : 16,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
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
              _buildDeliveryOfferStateRail(theme, offerStatus),
              const SizedBox(height: 10),
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
                        supportFeedbackBusy
                            ? 'Сохранение...'
                            : 'Да, вопрос решён',
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
                      label: const Text('Нет, нужна помощь'),
                    ),
                  ],
                ),
              ] else ...[
                _catalogMetaBadge(
                  theme,
                  'Статус',
                  supportFeedbackStatus == 'resolved'
                      ? 'Закрыто'
                      : supportFeedbackStatus == 'reopened'
                      ? 'Снова в работе'
                      : 'Ждём ваш ответ',
                ),
              ],
            ] else if (hasBuy) ...[
              AppSurfaceCard(
                padding: EdgeInsets.zero,
                radius: 24,
                compact: true,
                highlight: isAppearing,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (imageUrl != null) ...[
                      buildMessageImage(width: double.infinity),
                      const SizedBox(height: 2),
                    ],
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (catalogSnapshot['title'] ??
                                    catalogTexts['title'] ??
                                    'Товар')
                                .toString(),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          if (productDescriptionText.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            _buildHighlightedText(
                              productDescriptionText,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (productPickupOnly) ...[
                            const SizedBox(height: 12),
                            _buildPickupOnlyProductNotice(theme),
                          ],
                          const SizedBox(height: 12),
                          Builder(
                            builder: (context) {
                              final prominentBadgeLabelStyle = theme
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(fontSize: 16, height: 1.05);
                              final prominentBadgeValueStyle = theme
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(fontSize: 16, height: 1.05);
                              const prominentBadgePadding =
                                  EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  );
                              return Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _catalogMetaBadge(
                                    theme,
                                    'Цена',
                                    '$price ₽',
                                    labelStyle: prominentBadgeLabelStyle,
                                    valueStyle: prominentBadgeValueStyle,
                                    padding: prominentBadgePadding,
                                  ),
                                  _catalogMetaBadge(
                                    theme,
                                    'В наличии',
                                    quantity,
                                    labelStyle: prominentBadgeLabelStyle,
                                    valueStyle: prominentBadgeValueStyle,
                                    padding: prominentBadgePadding,
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: Icon(
                                quantityInt > 0
                                    ? Icons.shopping_cart_checkout_outlined
                                    : Icons.block_rounded,
                              ),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                              ),
                              onPressed: (_buyLoading || quantityInt <= 0)
                                  ? null
                                  : () => _buyProduct(metaMap),
                              label: Text(
                                quantityInt <= 0
                                    ? 'Нет в наличии'
                                    : (_buyLoading
                                          ? 'Добавление...'
                                          : 'Купить'),
                              ),
                            ),
                          ),
                          if (_isAdminOrCreator()) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.delete_forever_outlined),
                                onPressed: () =>
                                    _deleteCatalogProductFully(metaMap),
                                label: const Text('Полностью удалить товар'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (isReservedOrder) ...[
              AppSurfaceCard(
                padding: EdgeInsets.zero,
                radius: 24,
                compact: true,
                highlight: isAppearing,
                borderColor: isCancelled
                    ? theme.colorScheme.error.withValues(alpha: 0.22)
                    : isPlaced
                    ? const Color(0xFF1AA36A).withValues(alpha: 0.28)
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (imageUrl != null) ...[
                      buildMessageImage(width: double.infinity),
                      const SizedBox(height: 2),
                    ],
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (isCancelled)
                                AppStatusBadge.preset(
                                  context,
                                  'client_cancelled',
                                  compact: true,
                                )
                              else if (isPlaced && isOversizePlaced) ...[
                                AppStatusBadge.preset(
                                  context,
                                  'processed',
                                  compact: true,
                                ),
                                AppStatusBadge.preset(
                                  context,
                                  'oversized',
                                  compact: true,
                                ),
                              ] else if (isPlaced)
                                AppStatusBadge.preset(
                                  context,
                                  'processed',
                                  compact: true,
                                )
                              else
                                AppStatusBadge.preset(
                                  context,
                                  'reserved',
                                  compact: true,
                                ),
                              if (timeLabel.isNotEmpty)
                                _catalogMetaBadge(theme, 'В ленте', timeLabel),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            metaMap['title']?.toString().isNotEmpty == true
                                ? metaMap['title'].toString()
                                : catalogTexts['title'] ?? 'Заказ',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          if (reservedDescription.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            _buildHighlightedText(
                              reservedDescription,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (productPickupOnly) ...[
                            const SizedBox(height: 12),
                            _buildPickupOnlyProductNotice(theme),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      clientName,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      clientPhone,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Скопировать номер',
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                visualDensity: VisualDensity.compact,
                                onPressed:
                                    clientPhone.trim().isEmpty ||
                                        clientPhone == '—'
                                    ? null
                                    : () => _copyText(clientPhone),
                              ),
                            ],
                          ),
                          if (isPlaced) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Обработал: ${processedByName.isNotEmpty ? processedByName : '—'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Builder(
                            builder: (context) {
                              final prominentBadgeLabelStyle = theme
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(fontSize: 16, height: 1.05);
                              final prominentBadgeValueStyle = theme
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(fontSize: 16, height: 1.05);
                              const prominentBadgePadding =
                                  EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  );
                              return Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _catalogMetaBadge(
                                    theme,
                                    'ID',
                                    productLabel,
                                    labelStyle: prominentBadgeLabelStyle,
                                    valueStyle: prominentBadgeValueStyle,
                                    padding: prominentBadgePadding,
                                  ),
                                  _catalogMetaBadge(
                                    theme,
                                    'Цена',
                                    '$price ₽',
                                    labelStyle: prominentBadgeLabelStyle,
                                    valueStyle: prominentBadgeValueStyle,
                                    padding: prominentBadgePadding,
                                  ),
                                  _catalogMetaBadge(
                                    theme,
                                    'Куплено',
                                    quantity,
                                    labelStyle: prominentBadgeLabelStyle,
                                    valueStyle: prominentBadgeValueStyle,
                                    padding: prominentBadgePadding,
                                  ),
                                  _catalogMetaBadge(
                                    theme,
                                    'Полка',
                                    shelf,
                                    labelStyle: prominentBadgeLabelStyle,
                                    valueStyle: prominentBadgeValueStyle,
                                    padding: prominentBadgePadding,
                                  ),
                                  if (isOversizePlaced)
                                    _catalogMetaBadge(
                                      theme,
                                      'Режим',
                                      'Габарит',
                                      labelStyle: prominentBadgeLabelStyle,
                                      valueStyle: prominentBadgeValueStyle,
                                      padding: prominentBadgePadding,
                                    ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              SizedBox(
                                width: 190,
                                child: wrapCancelledTooltip(
                                  ElevatedButton.icon(
                                    icon: Icon(
                                      isPlaced
                                          ? Icons.print_outlined
                                          : Icons.inventory_2_outlined,
                                    ),
                                    onPressed: reservedMarkPlacedDisabled
                                        ? null
                                        : isPlaced
                                        ? (_canUseDesktopStickerPrinting
                                              ? () =>
                                                    _openReservedOrderStickerPrint(
                                                      metaMap,
                                                      oversize:
                                                          isOversizePlaced,
                                                    )
                                              : null)
                                        : () => _markReservedOrderPlaced(
                                            metaMap,
                                            messageId: messageId,
                                            processingMode: 'standard',
                                          ),
                                    label: Text(
                                      isPlaced
                                          ? 'Дай стикер'
                                          : (_markingPlaced
                                                ? 'Сохранение...'
                                                : 'Положил'),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 190,
                                child: wrapCancelledTooltip(
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.all_inbox_outlined),
                                    onPressed: reservedOversizeDisabled
                                        ? null
                                        : () => _markReservedOrderPlaced(
                                            metaMap,
                                            messageId: messageId,
                                            processingMode: 'oversize',
                                          ),
                                    label: Text(
                                      isPlaced && isOversizePlaced
                                          ? 'Габарит'
                                          : (_markingPlaced
                                                ? 'Сохранение...'
                                                : 'Габарит'),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 190,
                                child: wrapCancelledTooltip(
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.swap_horiz_outlined),
                                    onPressed: reservedShelfChangeDisabled
                                        ? null
                                        : () => _changeReservedOrderShelf(
                                            metaMap,
                                            messageId: messageId,
                                          ),
                                    label: const Text('Смена полки'),
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
              ),
            ] else ...[
              if (isVoiceMessage) ...[
                _buildVoiceAttachment(theme, message, metaMap),
                if (captionText.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _buildHighlightedText(
                    captionText,
                    style: TextStyle(color: textColor),
                  ),
                ],
              ] else if (isFileMessage) ...[
                _buildFileAttachment(theme, metaMap, textColor: textColor),
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
                  widthFactor: isStandaloneVideoNote ? 1 : null,
                  child: _buildVideoNoteAttachment(theme, message, metaMap),
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
                if (isSingleEmojiTextMessage)
                  _buildSingleEmojiMedallion(theme, text.trim(), fromMe: fromMe)
                else if (isPlainMessage || captionText.isNotEmpty)
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
                        child: PhoenixMicroburst(
                          enabled: mine && !reducedMotion,
                          color: theme.colorScheme.secondary,
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
                        ),
                      );
                    }).toList(),
                  ),
                ),
              _buildAttachmentStateRow(theme, metaMap),
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
                          color: isStandaloneMediaMessage
                              ? theme.colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.82,
                                )
                              : fromMe
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
          Flexible(
            child: _buildPendingMessageShell(
              theme,
              message: message,
              child: bubble,
            ),
          ),
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

    final animatedItem = _wrapNewMessageAppearance(
      child: bubbleRow,
      messageId: messageId,
      reducedMotion: accessibilityReducedMotion,
      useChannelPostAppearance: useChannelPostAppearance,
      isAppearing: isAppearing,
      fromMe: fromMe,
    );
    final highlightedItem =
        hasMessageId && _highlightedSearchMessageId == messageId
        ? PhoenixOneShotHighlight(
            key: ValueKey('search-hit-$messageId'),
            enabled: !reducedMotion,
            color: theme.colorScheme.tertiary,
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            child: animatedItem,
          )
        : animatedItem;

    if (hasMessageId) {
      return KeyedSubtree(
        key: _messageKeyFor(messageId),
        child: highlightedItem,
      );
    }
    return highlightedItem;
  }

  @override
  Widget build(BuildContext context) {
    if (_isPublicationLiveSyncChannel() &&
        _channelPublicationLiveSyncTimer == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isPublicationLiveSyncChannel()) return;
        _startChannelPublicationLiveSync(resetWindow: true);
      });
    }
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
    final recordingCancelDismissing =
        _voiceRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust ||
        _videoRecordingVisualPhase ==
            _RecordingActionVisualPhase.cancellingDust;
    final composerHiddenByRecording =
        recordingOverlayActive && !recordingCancelDismissing;
    final media = MediaQuery.of(context);
    final scrollButtonBottom =
        media.viewInsets.bottom +
        media.viewPadding.bottom +
        (_searchMode ? 18 : 92);

    // ignore: deprecated_member_use
    return WillPopScope(
      onWillPop: _handleWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: _searchMode
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: withInputLanguageBadge(
                    InputDecoration(
                      hintText: _isReservedOrdersChat()
                          ? 'ID, клиент, цена'
                          : 'Поиск по чату',
                      border: InputBorder.none,
                    ),
                    controller: _searchController,
                  ),
                )
              : _buildAppBarTitle(theme),
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
                    _searchDebounceTimer?.cancel();
                    _searchController.clear();
                    _searchQuery = '';
                    _serverSearchMessages = const [];
                    _serverSearchLoaded = false;
                    _serverSearchLoading = false;
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
            Positioned.fill(
              child: ValueListenableBuilder<String>(
                valueListenable: chatBackgroundEffectNotifier,
                builder: (context, mode, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: performanceModeNotifier,
                    builder: (context, performanceMode, _) {
                      return PhoenixAmbientBackground(
                        mode: mode,
                        chat: true,
                        enabled: !performanceMode,
                        opacity: theme.brightness == Brightness.dark
                            ? 0.68
                            : 0.52,
                      );
                    },
                  );
                },
              ),
            ),
            Column(
              children: [
                _buildDirectRequestBanner(),
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
                              : AppEmptyState(
                                  badge: _searchQuery.isEmpty ? 'Чат' : 'Поиск',
                                  title: _searchQuery.isEmpty
                                      ? 'Здесь пока нет сообщений'
                                      : 'Ничего не найдено',
                                  subtitle: _searchQuery.isEmpty
                                      ? 'Когда в переписке появятся сообщения, они будут показаны здесь.'
                                      : 'Попробуйте изменить запрос или очистить поиск.',
                                  icon: _searchQuery.isEmpty
                                      ? Icons.chat_bubble_outline_rounded
                                      : Icons.search_off_rounded,
                                  assetPath: _searchQuery.isEmpty
                                      ? PhoenixAssets.emptyStateNoChats
                                      : null,
                                  compact: true,
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
                                            parent:
                                                AlwaysScrollableScrollPhysics(),
                                          ),
                                    keyboardDismissBehavior:
                                        ScrollViewKeyboardDismissBehavior
                                            .onDrag,
                                    cacheExtent:
                                        media.size.height *
                                        _timelineCacheExtentMultiplier(),
                                    itemCount: timeline.length,
                                    itemBuilder: (context, i) {
                                      return _buildTimelineRowSafely(
                                        timeline[i],
                                      );
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
                            if ((_stickyDateLabel ?? '').trim().isNotEmpty)
                              Positioned(
                                top: 10,
                                left: 0,
                                right: 0,
                                child: IgnorePointer(
                                  child: Center(
                                    child: _StickyDateTimelineCapsule(
                                      label: _stickyDateLabel!,
                                    ),
                                  ),
                                ),
                              ),
                            if (_scrollRestoredHintVisible)
                              Positioned(
                                top: (_stickyDateLabel ?? '').trim().isNotEmpty
                                    ? 54
                                    : 12,
                                left: 0,
                                right: 0,
                                child: IgnorePointer(
                                  child: _buildEphemeralChatHint(
                                    icon: Icons.my_location_rounded,
                                    label: 'Вернулись к месту чтения',
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                if (!_searchMode) ...[
                  if (_draftRestoredHintVisible)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: _buildEphemeralChatHint(
                        icon: Icons.edit_note_rounded,
                        label: 'Черновик восстановлен',
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
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
                      child: PhoenixSlideFadeIn(
                        key: ValueKey<String>(_replyToMessageId ?? ''),
                        beginOffset: const Offset(0, 14),
                        duration: const Duration(milliseconds: 240),
                        child: PhoenixOneShotHighlight(
                          borderRadius: BorderRadius.circular(16),
                          color: Theme.of(context).colorScheme.primary,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 4,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Icon(
                                  Icons.subdirectory_arrow_right_rounded,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        (_replyPreviewSenderName ?? '')
                                                .trim()
                                                .isEmpty
                                            ? 'Ответ'
                                            : (_replyPreviewSenderName ?? '')
                                                  .trim(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
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
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  IgnorePointer(
                    ignoring:
                        composerHiddenByRecording && !_composerMediaPressActive,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 170),
                      curve: Curves.easeOutCubic,
                      opacity: composerHiddenByRecording ? 0 : 1,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              IconButton(
                                tooltip: 'Вложение',
                                icon: _mediaUploading
                                    ? PhoenixProgressRingIcon(
                                        icon: Icons.cloud_upload_outlined,
                                        showSpinner: true,
                                        size: 34,
                                        iconSize: 16,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
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
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  constraints: const BoxConstraints(
                                    minHeight: 44,
                                  ),
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
                                      enabled:
                                          canCompose && !_anyComposerRecording,
                                      minLines: 1,
                                      maxLines: 6,
                                      keyboardType: TextInputType.multiline,
                                      textInputAction: TextInputAction.newline,
                                      decoration: InputDecoration(
                                        hintText: _anyComposerRecording
                                            ? 'Говорите... отпустите кнопку для отправки'
                                            : canCompose
                                            ? 'Сообщение...'
                                            : 'Отправка сообщений недоступна',
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        errorBorder: InputBorder.none,
                                        focusedErrorBorder: InputBorder.none,
                                        filled: false,
                                        fillColor: Colors.transparent,
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
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
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: _controller,
                                builder: (context, value, _) {
                                  final hasDraftText = value.text
                                      .trim()
                                      .isNotEmpty;
                                  return hasDraftText
                                      ? IconButton(
                                          key: const ValueKey<String>(
                                            'composer-send',
                                          ),
                                          icon: _voiceSending
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : const Icon(Icons.send_rounded),
                                          onPressed:
                                              !canCompose ||
                                                  _mediaUploading ||
                                                  _voiceSending ||
                                                  _anyComposerRecording ||
                                                  _anyRecorderStarting
                                              ? null
                                              : _handleTextSendPressed,
                                        )
                                      : Builder(
                                          key: const ValueKey<String>(
                                            'composer-record',
                                          ),
                                          builder: (context) {
                                            final disabled =
                                                !canCompose ||
                                                _mediaUploading ||
                                                _voiceSending ||
                                                _anyComposerRecording ||
                                                _anyRecorderStarting;
                                            final activeColor = Theme.of(
                                              context,
                                            ).colorScheme.primary;
                                            final icon = _voiceRecording
                                                ? Icons.stop_circle_outlined
                                                : (_composerMediaMode ==
                                                          _ComposerMediaMode
                                                              .camera
                                                      ? Icons
                                                            .radio_button_unchecked_rounded
                                                      : Icons.mic_rounded);
                                            final isArmed =
                                                _anyComposerRecording ||
                                                _anyRecorderStarting;
                                            final isVideoMode =
                                                _composerMediaMode ==
                                                _ComposerMediaMode.camera;
                                            final buttonBaseColor =
                                                _voiceRecording
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.error
                                                : (_videoRecording ||
                                                      isVideoMode)
                                                ? const Color(0xFF2F80FF)
                                                : activeColor;
                                            final iconColor = disabled
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.onSurfaceVariant
                                                : Colors.white;
                                            return Listener(
                                              behavior: HitTestBehavior.opaque,
                                              onPointerDown: (event) =>
                                                  _handleComposerMediaTapDown(
                                                    disabled: disabled,
                                                    context: context,
                                                    canCompose: canCompose,
                                                    details: TapDownDetails(
                                                      globalPosition:
                                                          event.position,
                                                    ),
                                                  ),
                                              onPointerMove: (event) {
                                                if (_anyComposerRecording &&
                                                    !_voiceRecordingLocked &&
                                                    !_videoRecordingLocked) {
                                                  _handleRecordingPointerMove(
                                                    event.position,
                                                  );
                                                }
                                              },
                                              onPointerUp: (_) => unawaited(
                                                _handleComposerMediaTapUp(
                                                  disabled: disabled,
                                                  context: context,
                                                  canCompose: canCompose,
                                                ),
                                              ),
                                              onPointerCancel: (_) =>
                                                  _handleComposerMediaTapCancel(),
                                              child: TweenAnimationBuilder<double>(
                                                duration: const Duration(
                                                  milliseconds: 180,
                                                ),
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
                                                            begin: Alignment
                                                                .topLeft,
                                                            end: Alignment
                                                                .bottomRight,
                                                            colors: [
                                                              buttonBaseColor
                                                                  .withValues(
                                                                    alpha: 0.9,
                                                                  ),
                                                              buttonBaseColor
                                                                  .withValues(
                                                                    alpha: 0.72,
                                                                  ),
                                                            ],
                                                          ),
                                                    color: disabled
                                                        ? Theme.of(context)
                                                              .colorScheme
                                                              .surfaceContainerHigh
                                                        : null,
                                                    boxShadow: disabled
                                                        ? null
                                                        : [
                                                            BoxShadow(
                                                              color: buttonBaseColor
                                                                  .withValues(
                                                                    alpha: 0.30,
                                                                  ),
                                                              blurRadius: 14,
                                                              offset:
                                                                  const Offset(
                                                                    0,
                                                                    5,
                                                                  ),
                                                            ),
                                                          ],
                                                  ),
                                                  child:
                                                      _voiceSending ||
                                                          _anyRecorderStarting
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
                                                      : (_voiceRecording ||
                                                            _videoRecording)
                                                      ? Icon(
                                                          icon,
                                                          color: iconColor,
                                                        )
                                                      : _buildComposerMediaFlipIcon(
                                                          videoMode:
                                                              isVideoMode,
                                                          color: iconColor,
                                                          size: 46,
                                                        ),
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                },
                              ),
                            ],
                          ),
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
              child: Builder(
                builder: (context) {
                  final shouldUseUnreadJumpButton =
                      _shouldUseUnreadJumpButton();
                  final showActionButton =
                      shouldUseUnreadJumpButton || _showScrollToBottomButton;
                  return IgnorePointer(
                    ignoring: !showActionButton,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 180),
                      offset: showActionButton
                          ? Offset.zero
                          : const Offset(0, 0.6),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: showActionButton ? 1 : 0,
                        child: FloatingActionButton.small(
                          heroTag: 'chat-scroll-action',
                          tooltip: shouldUseUnreadJumpButton
                              ? 'К первому непрочитанному'
                              : 'В конец чата',
                          onPressed: shouldUseUnreadJumpButton
                              ? _jumpToFirstUnread
                              : () => _scrollToBottom(animated: true),
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                shouldUseUnreadJumpButton
                                    ? Icons.mark_chat_unread_outlined
                                    : Icons.keyboard_double_arrow_down_rounded,
                              ),
                              if (shouldUseUnreadJumpButton && _unreadCount > 0)
                                Positioned(
                                  top: -7,
                                  right: -10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _unreadCount > 99
                                          ? '99+'
                                          : '$_unreadCount',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
      ),
    );
  }
}

class _ChannelPostRevealHighlight extends StatelessWidget {
  const _ChannelPostRevealHighlight({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final eased = Curves.easeOutCubic.transform(
          value.clamp(0.0, 1.0).toDouble(),
        );
        final glowPhase = value < 0.55
            ? value / 0.55
            : 1 - ((value - 0.55) / 0.45);
        final glow = Curves.easeOut.transform(
          glowPhase.clamp(0.0, 1.0).toDouble(),
        );
        return RepaintBoundary(
          child: Opacity(
            opacity: (0.42 + eased * 0.58).clamp(0.0, 1.0).toDouble(),
            child: Transform.translate(
              offset: Offset(0, 18 * (1 - eased)),
              child: Transform.scale(
                alignment: Alignment.bottomCenter,
                scale: 0.985 + 0.015 * eased,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: scheme.primary.withValues(
                                  alpha: 0.12 * glow,
                                ),
                                blurRadius: 24 * glow,
                                spreadRadius: 1 * glow,
                                offset: Offset(0, 10 * glow),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    child!,
                    Positioned(
                      left: 38,
                      right: 38,
                      bottom: 3,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: glow,
                          child: Container(
                            height: 2.5,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  scheme.primary.withValues(alpha: 0.56),
                                  scheme.tertiary.withValues(alpha: 0.44),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color, required this.enabled});

  final Color color;
  final bool enabled;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 980),
    );
    if (widget.enabled) _controller.repeat();
  }

  @override
  void didUpdateWidget(_TypingDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final phase = (index * 0.18 + _controller.value) % 1.0;
            final lift = widget.enabled
                ? math.sin(phase * math.pi * 2).clamp(0.0, 1.0).toDouble()
                : 0.0;
            return Transform.translate(
              offset: Offset(0, -3 * lift),
              child: Container(
                width: 5,
                height: 5,
                margin: EdgeInsets.only(right: index == 2 ? 0 : 4),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.46 + lift * 0.38),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _StickyDateTimelineCapsule extends StatelessWidget {
  const _StickyDateTimelineCapsule({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final reducedMotion =
        performanceModeNotifier.value ||
        (MediaQuery.maybeOf(context)?.disableAnimations == true);
    final duration = reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 260);

    return AnimatedSize(
      duration: duration,
      curve: Curves.easeOutCubic,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            top: -12,
            bottom: -12,
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: Container(
                key: ValueKey('timeline-$label'),
                width: 3,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      scheme.primary.withValues(alpha: dark ? 0.40 : 0.30),
                      scheme.tertiary.withValues(alpha: dark ? 0.34 : 0.24),
                      Colors.transparent,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(
                        alpha: dark ? 0.20 : 0.12,
                      ),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    scheme.primary.withValues(alpha: dark ? 0.18 : 0.08),
                    scheme.surfaceContainerHighest.withValues(
                      alpha: dark ? 0.90 : 0.96,
                    ),
                  ),
                  scheme.surfaceContainerHigh.withValues(
                    alpha: dark ? 0.86 : 0.92,
                  ),
                ],
              ),
              border: Border.all(
                color: scheme.primary.withValues(alpha: dark ? 0.38 : 0.24),
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: dark ? 0.28 : 0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: scheme.primary.withValues(alpha: dark ? 0.12 : 0.07),
                  blurRadius: 24,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 14, 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: Container(
                              key: ValueKey('ring-$label'),
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: scheme.primary.withValues(
                                  alpha: dark ? 0.16 : 0.10,
                                ),
                              ),
                            ),
                          ),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.primary,
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary.withValues(alpha: 0.36),
                                  blurRadius: 9,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: duration,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        final offsetAnimation = Tween<Offset>(
                          begin: const Offset(0, 0.35),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: offsetAnimation,
                            child: child,
                          ),
                        );
                      },
                      child: Text(
                        label,
                        key: ValueKey(label),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: duration,
                      child: Container(
                        key: ValueKey('tail-$label'),
                        width: 20,
                        height: 3,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            colors: [
                              scheme.primary.withValues(alpha: 0.48),
                              scheme.primary.withValues(alpha: 0.03),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandedVideoNoteViewer extends StatefulWidget {
  const _ExpandedVideoNoteViewer({
    required this.videoUrl,
    required this.previewImageUrl,
    required this.durationMs,
    required this.title,
    required this.caption,
    required this.timeLabel,
  });

  final String videoUrl;
  final String? previewImageUrl;
  final int durationMs;
  final String title;
  final String caption;
  final String timeLabel;

  @override
  State<_ExpandedVideoNoteViewer> createState() =>
      _ExpandedVideoNoteViewerState();
}

class _ExpandedVideoNoteViewerState extends State<_ExpandedVideoNoteViewer> {
  vp.VideoPlayerController? _controller;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    final uri = Uri.tryParse(widget.videoUrl);
    if (uri == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Некорректная ссылка на видео';
      });
      return;
    }
    final controller = vp.VideoPlayerController.networkUrl(
      uri,
      videoPlayerOptions: vp.VideoPlayerOptions(mixWithOthers: false),
    );
    try {
      await controller.initialize();
      await controller.setLooping(false);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (_) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось открыть видеокружок';
      });
    }
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds.clamp(0, 99 * 3600);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final resolvedTitle = widget.title.trim().isEmpty
        ? 'Видеокружок'
        : widget.title.trim();
    final fallbackDuration = widget.durationMs > 0
        ? Duration(milliseconds: widget.durationMs)
        : Duration.zero;

    Widget bodyChild;
    if (_loading) {
      bodyChild = const Center(child: CircularProgressIndicator());
    } else if (_error.isNotEmpty) {
      bodyChild = Center(
        child: Text(
          _error,
          style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      );
    } else if (controller == null) {
      bodyChild = const SizedBox.shrink();
    } else {
      bodyChild = ValueListenableBuilder<vp.VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final initialized = value.isInitialized;
          final duration = initialized && value.duration > Duration.zero
              ? value.duration
              : fallbackDuration;
          final position = initialized ? value.position : Duration.zero;
          final progress = duration.inMilliseconds > 0
              ? (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0)
                    .toDouble()
              : 0.0;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: initialized && value.aspectRatio > 0
                    ? value.aspectRatio
                    : 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.previewImageUrl != null && !value.isPlaying)
                        AdaptiveNetworkImage(
                          widget.previewImageUrl!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      if (initialized)
                        FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: value.size.width > 0
                                ? value.size.width
                                : 320,
                            height: value.size.height > 0
                                ? value.size.height
                                : 320,
                            child: vp.VideoPlayer(controller),
                          ),
                        ),
                      Center(
                        child: IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.36,
                            ),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.all(20),
                          ),
                          onPressed: () async {
                            if (!initialized) return;
                            if (value.isPlaying) {
                              await controller.pause();
                              return;
                            }
                            final total = controller.value.duration;
                            final current = controller.value.position;
                            if (total > Duration.zero &&
                                current >=
                                    total - const Duration(milliseconds: 200)) {
                              await controller.seekTo(Duration.zero);
                            }
                            await controller.play();
                          },
                          icon: Icon(
                            value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 38,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    _formatDuration(position),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatDuration(duration),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white70,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      backgroundColor: const Color(0xFF0E1218),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          resolvedTitle,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            'Видеокружок',
                            if (widget.timeLabel.trim().isNotEmpty)
                              widget.timeLabel.trim(),
                          ].join(' • '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              bodyChild,
              if (widget.caption.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  widget.caption.trim(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoNotePoster extends StatefulWidget {
  const _VideoNotePoster({
    super.key,
    required this.videoUrl,
    required this.fallback,
    this.onDurationResolved,
  });

  final String videoUrl;
  final Widget fallback;
  final ValueChanged<Duration>? onDurationResolved;

  @override
  State<_VideoNotePoster> createState() => _VideoNotePosterState();
}

class _VideoNotePosterState extends State<_VideoNotePoster> {
  vp.VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant _VideoNotePoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl == widget.videoUrl) return;
    unawaited(_controller?.dispose());
    _controller = null;
    _ready = false;
    unawaited(_initialize());
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    final requestedUrl = widget.videoUrl.trim();
    final uri = Uri.tryParse(requestedUrl);
    if (uri == null || !uri.hasScheme) return;
    final controller = vp.VideoPlayerController.networkUrl(
      uri,
      videoPlayerOptions: vp.VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await controller.initialize();
      await controller.pause();
      await controller.seekTo(Duration.zero);
      if (!mounted || widget.videoUrl.trim() != requestedUrl) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
      final duration = controller.value.duration;
      if (duration > Duration.zero) {
        widget.onDurationResolved?.call(duration);
      }
    } catch (_) {
      await controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return widget.fallback;
    }
    final size = controller.value.size;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.fallback,
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width > 0 ? size.width : 320,
            height: size.height > 0 ? size.height : 320,
            child: vp.VideoPlayer(controller),
          ),
        ),
      ],
    );
  }
}

class _AttachmentPickedUpload {
  const _AttachmentPickedUpload({
    required this.id,
    required this.kind,
    required this.upload,
    this.previewBytes,
    this.durationMs,
  });

  final String id;
  final String kind;
  final _ChatUploadFile upload;
  final Uint8List? previewBytes;
  final int? durationMs;
}

class _AttachmentGallerySelection {
  const _AttachmentGallerySelection({required this.items});

  final List<_AttachmentPickedUpload> items;
}

class _ChatAttachmentGallerySheet extends StatefulWidget {
  const _ChatAttachmentGallerySheet({
    required this.title,
    required this.desktopMode,
    required this.nativeMacCameraMode,
    required this.loadRecent,
    required this.loadRecentUpload,
    required this.pickFromDevice,
    required this.startCamera,
    required this.cameraController,
    required this.cameraPreviewAvailable,
    required this.cameraHint,
    required this.capturePhoto,
    required this.toggleRecordVideo,
    required this.cancelRecordVideo,
    required this.stopCamera,
  });

  final String title;
  final bool desktopMode;
  final bool nativeMacCameraMode;
  final Future<List<ChatRecentGalleryItem>> Function() loadRecent;
  final Future<_AttachmentPickedUpload?> Function(ChatRecentGalleryItem)
  loadRecentUpload;
  final Future<List<_AttachmentPickedUpload>> Function() pickFromDevice;
  final Future<bool> Function() startCamera;
  final cam.CameraController? Function() cameraController;
  final bool Function() cameraPreviewAvailable;
  final String Function() cameraHint;
  final Future<_AttachmentPickedUpload?> Function() capturePhoto;
  final Future<_AttachmentPickedUpload?> Function() toggleRecordVideo;
  final Future<void> Function() cancelRecordVideo;
  final Future<void> Function() stopCamera;

  @override
  State<_ChatAttachmentGallerySheet> createState() =>
      _ChatAttachmentGallerySheetState();
}

class _ChatAttachmentGallerySheetState
    extends State<_ChatAttachmentGallerySheet> {
  final Set<String> _selectedPickedIds = <String>{};
  final Set<String> _selectedRecentIds = <String>{};
  final List<_AttachmentPickedUpload> _picked = <_AttachmentPickedUpload>[];
  List<ChatRecentGalleryItem> _recent = const <ChatRecentGalleryItem>[];
  bool _loadingRecent = true;
  bool _cameraStarting = true;
  bool _cameraReady = false;
  bool _busy = false;
  bool _recording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  StreamSubscription<Uint8List>? _nativePreviewSub;
  Uint8List? _nativePreviewFrame;

  int get _selectedCount =>
      _selectedPickedIds.length + _selectedRecentIds.length;

  String _formatSheetDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes < 10 ? '0$minutes' : '$minutes';
    final ss = seconds < 10 ? '0$seconds' : '$seconds';
    return '$mm:$ss';
  }

  @override
  void initState() {
    super.initState();
    if (widget.nativeMacCameraMode) {
      _startNativePreviewFrames();
    }
    unawaited(_loadRecent());
    unawaited(_startCamera());
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _nativePreviewSub?.cancel();
    unawaited(_disposeCameraSession());
    super.dispose();
  }

  Future<void> _disposeCameraSession() async {
    try {
      await widget.cancelRecordVideo();
    } finally {
      await widget.stopCamera();
    }
  }

  void _startNativePreviewFrames() {
    _nativePreviewSub?.cancel();
    _nativePreviewSub = NativeVideoNoteCaptureService.previewFrames.listen(
      (frame) {
        if (!mounted) return;
        setState(() => _nativePreviewFrame = frame);
      },
      onError: (Object error) {
        debugPrint('attachment native preview error: $error');
      },
    );
  }

  Future<void> _loadRecent() async {
    try {
      final recent = await widget.loadRecent();
      if (!mounted) return;
      setState(() {
        _recent = recent;
        _loadingRecent = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingRecent = false);
    }
  }

  Future<void> _startCamera() async {
    setState(() {
      _cameraStarting = true;
      _cameraReady = false;
    });
    try {
      final ready = await widget.startCamera();
      if (!mounted) return;
      setState(() {
        _cameraReady = ready;
        _cameraStarting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraReady = false;
        _cameraStarting = false;
      });
    }
  }

  void _showSheetNotice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pickFromDevice() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final uploads = await widget.pickFromDevice();
      if (!mounted) return;
      setState(() {
        _picked.insertAll(0, uploads);
        for (final upload in uploads) {
          _selectedPickedIds.add(upload.id);
        }
      });
      if (uploads.isEmpty) {
        _showSheetNotice('Фото не выбрано');
      }
    } catch (_) {
      _showSheetNotice('Не удалось выбрать фото');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _capturePhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final upload = await widget.capturePhoto();
      if (!mounted) return;
      if (upload != null) {
        setState(() {
          _picked.insert(0, upload);
          _selectedPickedIds.add(upload.id);
        });
      }
    } catch (_) {
      _showSheetNotice('Не удалось сделать фото');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleRecording() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final upload = await widget.toggleRecordVideo();
      if (!mounted) return;
      if (_recording) {
        _recordingTimer?.cancel();
        _recordingTimer = null;
        setState(() {
          _recording = false;
          _recordingSeconds = 0;
          if (upload != null) {
            _picked.insert(0, upload);
            _selectedPickedIds.add(upload.id);
          }
        });
      } else {
        setState(() {
          _recording = true;
          _recordingSeconds = 0;
        });
        _recordingTimer?.cancel();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          setState(() => _recordingSeconds += 1);
        });
      }
    } catch (_) {
      _showSheetNotice('Не удалось записать видео');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendSelected() async {
    if (_selectedCount == 0 || _busy) {
      _showSheetNotice('Выберите фото или видео');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_recording) {
        final upload = await widget.toggleRecordVideo();
        _recordingTimer?.cancel();
        _recordingTimer = null;
        _recording = false;
        if (upload != null) {
          _picked.insert(0, upload);
          _selectedPickedIds.add(upload.id);
        }
      }

      final items = <_AttachmentPickedUpload>[];
      for (final upload in _picked) {
        if (_selectedPickedIds.contains(upload.id)) {
          items.add(upload);
        }
      }
      for (final item in _recent) {
        if (!_selectedRecentIds.contains(item.id)) continue;
        final upload = await widget.loadRecentUpload(item);
        if (upload != null) items.add(upload);
      }
      if (!mounted) return;
      Navigator.of(context).pop(_AttachmentGallerySelection(items: items));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSheetNotice('Не удалось подготовить медиа');
    }
  }

  void _togglePicked(String id) {
    setState(() {
      if (!_selectedPickedIds.remove(id)) {
        _selectedPickedIds.add(id);
      }
    });
  }

  void _toggleRecent(String id) {
    setState(() {
      if (!_selectedRecentIds.remove(id)) {
        _selectedRecentIds.add(id);
      }
    });
  }

  int _selectionOrder(String id) {
    final ordered = <String>[..._selectedPickedIds, ..._selectedRecentIds];
    final index = ordered.indexOf(id);
    return index < 0 ? 0 : index + 1;
  }

  Widget _buildCameraPreview() {
    if (widget.nativeMacCameraMode && _nativePreviewFrame != null) {
      return RepaintBoundary(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(-1, 1, 1),
          child: Image.memory(
            _nativePreviewFrame!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        ),
      );
    }
    final controller = widget.cameraController();
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final previewSize = controller.value.previewSize;
    Widget preview = cam.CameraPreview(controller);
    if (controller.description.lensDirection == cam.CameraLensDirection.front) {
      preview = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: preview,
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: previewSize?.height ?? 320,
        height: previewSize?.width ?? 320,
        child: preview,
      ),
    );
  }

  Widget _buildCameraTile(ThemeData theme, {double borderRadius = 2}) {
    final nativePreviewReady =
        widget.nativeMacCameraMode && _nativePreviewFrame != null;
    final previewReady = widget.cameraPreviewAvailable() || nativePreviewReady;
    final enabledForVideo = _cameraReady || previewReady;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF101827), Color(0xFF1B2440)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (previewReady) _buildCameraPreview(),
            if (!previewReady)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.35),
                    radius: 0.95,
                    colors: [
                      theme.colorScheme.primary.withValues(alpha: 0.30),
                      const Color(0xFF121827),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_cameraStarting)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        widget.nativeMacCameraMode
                            ? Icons.laptop_mac_rounded
                            : Icons.photo_camera_outlined,
                        color: Colors.white,
                        size: 34,
                      ),
                    const SizedBox(height: 8),
                    Text(
                      _cameraStarting
                          ? 'Запуск камеры'
                          : widget.nativeMacCameraMode && _cameraReady
                          ? 'Камера Mac'
                          : _cameraReady
                          ? 'Камера готова'
                          : widget.cameraHint(),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.48),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  _recording
                      ? _formatSheetDuration(
                          Duration(seconds: _recordingSeconds),
                        )
                      : 'LIVE',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundCameraAction(
                    icon: Icons.radio_button_unchecked_rounded,
                    onPressed: previewReady && !_recording && !_busy
                        ? _capturePhoto
                        : null,
                  ),
                  const SizedBox(width: 10),
                  _RoundCameraAction(
                    recording: _recording,
                    icon: _recording
                        ? Icons.stop_rounded
                        : Icons.fiber_manual_record_rounded,
                    onPressed: enabledForVideo && !_busy
                        ? _toggleRecording
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPickedTile(_AttachmentPickedUpload item, ThemeData theme) {
    final selected = _selectedPickedIds.contains(item.id);
    return _AttachmentMediaTile(
      selected: selected,
      selectionOrder: _selectionOrder(item.id),
      kind: item.kind,
      previewBytes: item.previewBytes,
      label: item.kind == 'video' ? 'Видео' : 'Фото',
      onTap: () => _togglePicked(item.id),
    );
  }

  Widget _buildRecentTile(ChatRecentGalleryItem item, ThemeData theme) {
    final selected = _selectedRecentIds.contains(item.id);
    return _AttachmentMediaTile(
      selected: selected,
      selectionOrder: _selectionOrder(item.id),
      kind: item.kind,
      previewBytes: item.thumbnailBytes,
      label: item.kind == 'video' ? 'Видео' : '',
      onTap: () => _toggleRecent(item.id),
    );
  }

  Widget _buildEmptyRecent(ThemeData theme) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 110),
        child: Column(
          children: [
            Icon(
              widget.desktopMode
                  ? Icons.folder_open_rounded
                  : Icons.photo_library_outlined,
              size: 42,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              widget.desktopMode
                  ? 'На desktop браузер и приложение не могут показать “Недавние” без выбора пользователя.'
                  : 'Нет доступа к недавним медиа',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : _pickFromDevice,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Выбрать фото'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyRecentPanel(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.desktopMode
                  ? Icons.folder_open_rounded
                  : Icons.photo_library_outlined,
              size: 42,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              widget.desktopMode
                  ? 'Выберите фото с устройства, чтобы заполнить desktop-галерею.'
                  : 'Нет доступа к недавним медиа',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : _pickFromDevice,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Выбрать фото'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryGrid(
    ThemeData theme, {
    required int columns,
    required bool includeCamera,
    required EdgeInsets padding,
  }) {
    final mediaCount = _picked.length + (_loadingRecent ? 9 : _recent.length);
    if (!includeCamera && !_loadingRecent && mediaCount == 0) {
      return _buildEmptyRecentPanel(theme);
    }
    return GridView.builder(
      padding: padding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: (includeCamera ? 1 : 0) + mediaCount,
      itemBuilder: (context, index) {
        if (includeCamera && index == 0) return _buildCameraTile(theme);
        final mediaIndex = index - (includeCamera ? 1 : 0);
        if (mediaIndex < _picked.length) {
          return _buildPickedTile(_picked[mediaIndex], theme);
        }
        final recentIndex = mediaIndex - _picked.length;
        if (_loadingRecent) {
          return const _AttachmentSkeletonTile();
        }
        return _buildRecentTile(_recent[recentIndex], theme);
      },
    );
  }

  Widget _buildDesktopCameraPanel(ThemeData theme, {required bool compact}) {
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.78),
        ),
      ),
      child: compact
          ? Row(
              children: [
                SizedBox(
                  width: 150,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Камера',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Запускается сразу при открытии скрепки.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _buildCameraTile(theme, borderRadius: 18)),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Камера',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Запускается сразу при открытии скрепки.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: _buildCameraTile(theme, borderRadius: 22)),
              ],
            ),
    );
  }

  Widget _buildDesktopGalleryPanel(ThemeData theme, {required int columns}) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.62),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Недавние',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        widget.desktopMode
                            ? 'Выбранные локальные фото появятся здесь'
                            : 'Фото и видео с устройства',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _pickFromDevice,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Фото'),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
          Expanded(
            child: _buildGalleryGrid(
              theme,
              columns: columns,
              includeCamera: false,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 118),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopMediaBody(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          if (compact) {
            final galleryColumns = constraints.maxWidth >= 560 ? 4 : 3;
            final cameraHeight = min(260.0, constraints.maxHeight * 0.38);
            return Column(
              children: [
                SizedBox(
                  height: cameraHeight,
                  child: _buildDesktopCameraPanel(theme, compact: true),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _buildDesktopGalleryPanel(
                    theme,
                    columns: galleryColumns,
                  ),
                ),
              ],
            );
          }
          final cameraWidth = min(
            360.0,
            max(280.0, constraints.maxWidth * 0.32),
          );
          final galleryColumns = constraints.maxWidth >= 1000
              ? 5
              : constraints.maxWidth >= 860
              ? 4
              : 3;
          return Row(
            children: [
              SizedBox(
                width: cameraWidth,
                child: _buildDesktopCameraPanel(theme, compact: false),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDesktopGalleryPanel(
                  theme,
                  columns: galleryColumns,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobileMediaBody(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 680
            ? 5
            : constraints.maxWidth >= 520
            ? 4
            : 3;
        final count = 1 + _picked.length + _recent.length;
        if (!_loadingRecent && count == 1) {
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverGrid(
                  delegate: SliverChildListDelegate([_buildCameraTile(theme)]),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                ),
              ),
              _buildEmptyRecent(theme),
            ],
          );
        }
        return _buildGalleryGrid(
          theme,
          columns: columns,
          includeCamera: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 118),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final useDesktopLayout = widget.desktopMode && size.width >= 760;
    final maxWidth = useDesktopLayout
        ? min(size.width - 32, 1280.0)
        : (size.width >= 760 ? 760.0 : size.width);
    final height = useDesktopLayout
        ? min(size.height * 0.78, 860.0)
        : min(size.height * 0.78, 680.0);
    final surface = theme.colorScheme.surface.withValues(alpha: 0.98);

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: height),
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            child: Container(
              height: height,
              decoration: BoxDecoration(
                color: surface,
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.8,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.26),
                    blurRadius: 40,
                    offset: const Offset(0, -18),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 52,
                        height: 5,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.30,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                        child: Row(
                          children: [
                            IconButton.filledTonal(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w900),
                                  ),
                                  Text(
                                    widget.desktopMode
                                        ? 'MacBook / desktop режим'
                                        : 'Галерея',
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton.filledTonal(
                              onPressed: _busy ? null : _pickFromDevice,
                              tooltip: 'Выбрать фото',
                              icon: _busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.add_photo_alternate_outlined,
                                    ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: useDesktopLayout
                            ? _buildDesktopMediaBody(theme)
                            : _buildMobileMediaBody(theme),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        decoration: BoxDecoration(
                          color: surface.withValues(alpha: 0.92),
                          border: Border(
                            top: BorderSide(
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 11,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.14,
                                  ),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.22,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.photo_library_outlined,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(width: 9),
                                    Text(
                                      'Галерея',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 84,
                    child: IgnorePointer(
                      ignoring: _selectedCount == 0,
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 180),
                        offset: _selectedCount > 0
                            ? Offset.zero
                            : const Offset(0, 0.35),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: _selectedCount > 0 ? 1 : 0,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.inverseSurface
                                  .withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(22),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.26),
                                  blurRadius: 24,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Выбрано $_selectedCount',
                                        style: TextStyle(
                                          color: theme
                                              .colorScheme
                                              .onInverseSurface,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      Text(
                                        'Будет отправлено в чат',
                                        style: TextStyle(
                                          color: theme
                                              .colorScheme
                                              .onInverseSurface
                                              .withValues(alpha: 0.70),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                FilledButton.icon(
                                  onPressed: _busy ? null : _sendSelected,
                                  icon: _busy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                          ),
                                        )
                                      : const Icon(Icons.send_rounded),
                                  label: const Text('Отправить'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundCameraAction extends StatelessWidget {
  const _RoundCameraAction({
    required this.icon,
    required this.onPressed,
    this.recording = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(
                alpha: onPressed == null ? 0.35 : 0.9,
              ),
              width: 2,
            ),
          ),
          child: Icon(
            icon,
            color: recording ? const Color(0xFFFF4D43) : Colors.white,
            size: recording ? 22 : 20,
          ),
        ),
      ),
    );
  }
}

class _AttachmentMediaTile extends StatelessWidget {
  const _AttachmentMediaTile({
    required this.selected,
    required this.selectionOrder,
    required this.kind,
    required this.previewBytes,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final int selectionOrder;
  final String kind;
  final Uint8List? previewBytes;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget preview;
    if (previewBytes != null && previewBytes!.isNotEmpty) {
      preview = Image.memory(
        previewBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      preview = Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF22325C), Color(0xFF22D3EE)],
          ),
        ),
        child: Icon(
          kind == 'video' ? Icons.videocam_outlined : Icons.image_outlined,
          color: Colors.white,
          size: 30,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              if (kind == 'video')
                Positioned(
                  left: 7,
                  top: 7,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.48),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'VIDEO',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              if (label.trim().isNotEmpty && kind != 'video')
                Positioned(
                  left: 7,
                  bottom: 7,
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      shadows: [Shadow(blurRadius: 6)],
                    ),
                  ),
                ),
              Positioned(
                top: 7,
                right: 7,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 170),
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: selected
                        ? const LinearGradient(
                            colors: [Color(0xFF3B82F6), Color(0xFF22D3EE)],
                          )
                        : null,
                    color: selected
                        ? null
                        : Colors.black.withValues(alpha: 0.18),
                    border: Border.all(
                      color: selected ? Colors.transparent : Colors.white,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: selected
                      ? Text(
                          '$selectionOrder',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentSkeletonTile extends StatelessWidget {
  const _AttachmentSkeletonTile();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: DecoratedBox(
        decoration: BoxDecoration(color: color),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscussionChatSettingsSheet extends StatefulWidget {
  const _DiscussionChatSettingsSheet({
    required this.chatId,
    required this.title,
    required this.settings,
    required this.canManage,
  });

  final String chatId;
  final String title;
  final Map<String, dynamic> settings;
  final bool canManage;

  @override
  State<_DiscussionChatSettingsSheet> createState() =>
      _DiscussionChatSettingsSheetState();
}

class _DiscussionChatSettingsSheetState
    extends State<_DiscussionChatSettingsSheet> {
  late final TextEditingController _titleController;
  bool _loading = false;
  bool _saving = false;
  String _error = '';
  Map<String, dynamic>? _chat;
  List<Map<String, dynamic>> _members = const [];
  List<Map<String, dynamic>> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.title);
    _chat = <String, dynamic>{
      'id': widget.chatId,
      'title': widget.title,
      'type': 'private',
      'settings': widget.settings,
    };
    if (widget.canManage) {
      unawaited(_loadSettings());
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  String _extractError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) {
        return data['error'].toString();
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!;
      }
    }
    return error.toString();
  }

  Map<String, dynamic> _settingsOf(Map<String, dynamic>? chat) {
    final raw = chat?['settings'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return widget.settings;
  }

  String? _avatarUrl() {
    final raw = (_settingsOf(_chat)['avatar_url'] ?? '').toString().trim();
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
  }

  double _avatarFocus(String key, double fallback) {
    final value = double.tryParse('${_settingsOf(_chat)[key] ?? ''}');
    if (value == null || !value.isFinite) return fallback;
    return value.clamp(-1.0, 1.0).toDouble();
  }

  double _avatarZoom() {
    final value = double.tryParse('${_settingsOf(_chat)['avatar_zoom'] ?? ''}');
    if (value == null || !value.isFinite) return 1.0;
    return value.clamp(1.0, 4.0).toDouble();
  }

  String _displayName(Map<String, dynamic> user) {
    return (user['name'] ?? '').toString().trim().isNotEmpty
        ? user['name'].toString().trim()
        : (user['email'] ?? '').toString().trim().isNotEmpty
        ? user['email'].toString().trim()
        : (user['phone'] ?? '').toString().trim().isNotEmpty
        ? user['phone'].toString().trim()
        : 'Пользователь';
  }

  Future<void> _loadSettings() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final response = await authService.dio.get(
        '/api/chats/${widget.chatId}/discussion-settings',
      );
      final data = response.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data'] as Map);
        final chatRaw = payload['chat'];
        setState(() {
          _chat = chatRaw is Map
              ? Map<String, dynamic>.from(chatRaw)
              : _chat;
          _members = (payload['members'] is List)
              ? List<Map<String, dynamic>>.from(
                  (payload['members'] as List).map(
                    (item) => Map<String, dynamic>.from(item as Map),
                  ),
                )
              : const [];
          _candidates = (payload['candidates'] is List)
              ? List<Map<String, dynamic>>.from(
                  (payload['candidates'] as List).map(
                    (item) => Map<String, dynamic>.from(item as Map),
                  ),
                )
              : const [];
          _titleController.text =
              (_chat?['title'] ?? widget.title).toString().trim();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _extractError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveTitle() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Название обязательно');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final response = await authService.dio.patch(
        '/api/chats/${widget.chatId}/discussion-settings',
        data: {'title': title},
      );
      final data = response.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final chat = Map<String, dynamic>.from(data['data'] as Map);
        setState(() => _chat = chat);
        Navigator.of(context).pop(chat);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _extractError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _uploadAvatar() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
      if (picked == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final multipart = kIsWeb
          ? MultipartFile.fromBytes(
              await picked.readAsBytes(),
              filename: picked.name,
            )
          : await MultipartFile.fromFile(picked.path, filename: picked.name);
      final response = await authService.dio.post(
        '/api/chats/${widget.chatId}/discussion-settings/avatar',
        data: FormData.fromMap({'avatar': multipart}),
      );
      final data = response.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        setState(() => _chat = Map<String, dynamic>.from(data['data'] as Map));
      }
    } catch (e) {
      if (mounted) setState(() => _error = _extractError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeAvatar() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final response = await authService.dio.delete(
        '/api/chats/${widget.chatId}/discussion-settings/avatar',
      );
      final data = response.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        setState(() => _chat = Map<String, dynamic>.from(data['data'] as Map));
      }
    } catch (e) {
      if (mounted) setState(() => _error = _extractError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addMember(String userId) async {
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final response = await authService.dio.post(
        '/api/chats/${widget.chatId}/discussion-settings/members',
        data: {'user_id': userId},
      );
      final data = response.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data'] as Map);
        setState(() {
          _members = (payload['members'] is List)
              ? List<Map<String, dynamic>>.from(
                  (payload['members'] as List).map(
                    (item) => Map<String, dynamic>.from(item as Map),
                  ),
                )
              : _members;
          _candidates = (payload['candidates'] is List)
              ? List<Map<String, dynamic>>.from(
                  (payload['candidates'] as List).map(
                    (item) => Map<String, dynamic>.from(item as Map),
                  ),
                )
              : _candidates;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _extractError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeMember(String userId) async {
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final response = await authService.dio.delete(
        '/api/chats/${widget.chatId}/discussion-settings/members/$userId',
      );
      final data = response.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data'] as Map);
        setState(() {
          _members = (payload['members'] is List)
              ? List<Map<String, dynamic>>.from(
                  (payload['members'] as List).map(
                    (item) => Map<String, dynamic>.from(item as Map),
                  ),
                )
              : _members;
          _candidates = (payload['candidates'] is List)
              ? List<Map<String, dynamic>>.from(
                  (payload['candidates'] as List).map(
                    (item) => Map<String, dynamic>.from(item as Map),
                  ),
                )
              : _candidates;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _extractError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildUserTile(
    ThemeData theme,
    Map<String, dynamic> user, {
    required bool member,
  }) {
    final userId = (user['user_id'] ?? '').toString();
    final userRole = (user['user_role'] ?? '').toString();
    final canRemove = user['can_remove'] == true;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        title: _displayName(user),
        imageUrl: resolveMediaUrl(
          (user['avatar_url'] ?? '').toString(),
          apiBaseUrl: authService.dio.options.baseUrl,
        ),
        focusX: double.tryParse('${user['avatar_focus_x'] ?? 0}') ?? 0,
        focusY: double.tryParse('${user['avatar_focus_y'] ?? 0}') ?? 0,
        zoom: double.tryParse('${user['avatar_zoom'] ?? 1}') ?? 1,
        radius: 17,
      ),
      title: Text(
        _displayName(user),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if ((user['email'] ?? '').toString().trim().isNotEmpty)
            (user['email'] ?? '').toString().trim(),
          if ((user['phone'] ?? '').toString().trim().isNotEmpty)
            (user['phone'] ?? '').toString().trim(),
          if (userRole.isNotEmpty) userRole,
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: !widget.canManage
          ? null
          : member
          ? IconButton(
              tooltip: canRemove
                  ? 'Убрать доступ'
                  : 'Создатель и арендатор всегда имеют доступ',
              onPressed: canRemove && !_saving ? () => _removeMember(userId) : null,
              icon: const Icon(Icons.person_remove_alt_1_outlined),
            )
          : IconButton(
              tooltip: 'Дать доступ',
              onPressed: _saving ? null : () => _addMember(userId),
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = (_chat?['title'] ?? widget.title).toString().trim();
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  AppAvatar(
                    title: title.isEmpty ? 'Обсуждения' : title,
                    imageUrl: _avatarUrl(),
                    focusX: _avatarFocus('avatar_focus_x', 0),
                    focusY: _avatarFocus('avatar_focus_y', 0),
                    zoom: _avatarZoom(),
                    radius: 34,
                    fallbackIcon: Icons.forum_outlined,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.isEmpty ? 'Обсуждения' : title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Закрытый чат для создателя, арендаторов и выбранных пользователей',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!widget.canManage) ...[
                const SizedBox(height: 20),
                AppSurfaceCard(
                  child: Text(
                    'Настройки этого чата доступны только Создателю.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 22),
                Text('Настройки', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Название чата',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saving ? null : _saveTitle(),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _saving ? null : _saveTitle,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('Сохранить название'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _uploadAvatar,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Сменить аватарку'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving || _avatarUrl() == null
                          ? null
                          : _removeAvatar,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Убрать аватарку'),
                    ),
                  ],
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    Text('Участники', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    if (_loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_members.isEmpty && !_loading)
                  Text(
                    'Список участников пока пуст.',
                    style: theme.textTheme.bodyMedium,
                  )
                else
                  ..._members.map(
                    (member) => _buildUserTile(theme, member, member: true),
                  ),
                const SizedBox(height: 18),
                Text('Добавить доступ', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_candidates.isEmpty && !_loading)
                  Text(
                    'Нет доступных пользователей для добавления.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  ..._candidates
                      .take(80)
                      .map(
                        (candidate) =>
                            _buildUserTile(theme, candidate, member: false),
                      ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ChatTimelineLoadingView extends StatelessWidget {
  const _ChatTimelineLoadingView();

  @override
  Widget build(BuildContext context) {
    return const AppMessageSkeletonList(count: 8);
  }
}
