import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../src/utils/device_utils.dart';
import '../src/utils/local_time_zone.dart';
import 'firebase_runtime_options.dart';
import 'native_update_installer.dart';

typedef NativePushTapHandler =
    Future<void> Function(
      Map<String, dynamic> payload, {
      required bool fromTap,
      required bool coldStart,
    });

const _androidMessageChannel = AndroidNotificationChannel(
  'phoenix_messages',
  'Личные сообщения',
  description: 'Личные сообщения и ответы в чатах',
  importance: Importance.high,
);

const _androidSupportChannel = AndroidNotificationChannel(
  'phoenix_support',
  'Поддержка',
  description: 'Поддержка и служебные ответы',
  importance: Importance.high,
);

const _androidReservedChannel = AndroidNotificationChannel(
  'phoenix_reserved',
  'Забронированный товар',
  description: 'Забронированные товары и складские действия',
  importance: Importance.defaultImportance,
);

const _androidDeliveryChannel = AndroidNotificationChannel(
  'phoenix_delivery',
  'Доставка',
  description: 'Доставка и логистика',
  importance: Importance.defaultImportance,
);

const _androidPromoChannel = AndroidNotificationChannel(
  'phoenix_promo',
  'Акции и промо',
  description: 'Акции и маркетинговые уведомления',
  importance: Importance.defaultImportance,
);

const _androidUpdatesChannel = AndroidNotificationChannel(
  'phoenix_updates',
  'Обновления',
  description: 'Обновления приложения',
  importance: Importance.defaultImportance,
);

const _androidSecurityChannel = AndroidNotificationChannel(
  'phoenix_security',
  'Безопасность',
  description: 'Входы, пароли и security-события',
  importance: Importance.high,
);

@pragma('vm:entry-point')
Future<void> nativePushBackgroundMessageHandler(RemoteMessage message) async {
  await NativePushService.ensureInitializedForBackground();
  await NativePushService.showForegroundNotificationFromMessage(message);
}

@pragma('vm:entry-point')
void nativePushBackgroundNotificationTap(NotificationResponse response) {
  NativePushService.captureBackgroundTapPayload(response.payload);
}

class NativePushService {
  const NativePushService._();

  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const List<AndroidNotificationChannel> _androidChannels = <AndroidNotificationChannel>[
    _androidMessageChannel,
    _androidSupportChannel,
    _androidReservedChannel,
    _androidDeliveryChannel,
    _androidPromoChannel,
    _androidUpdatesChannel,
    _androidSecurityChannel,
  ];

  static bool _firebaseReady = false;
  static bool _localNotificationsReady = false;
  static bool _listenersAttached = false;
  static NativePushTapHandler? _tapHandler;
  static Dio? _dio;
  static Map<String, dynamic>? _pendingTapPayload;
  static bool _pendingTapPayloadIsColdStart = false;
  static StreamSubscription<String>? _tokenRefreshSub;
  static StreamSubscription<RemoteMessage>? _foregroundSub;
  static StreamSubscription<RemoteMessage>? _openedSub;
  static String? _cachedFcmToken;

  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  static bool get isConfigured => FirebaseRuntimeOptions.isConfigured;

  static Future<void> initialize({
    required Dio dio,
    required NativePushTapHandler onNotificationOpen,
  }) async {
    _dio = dio;
    _tapHandler = onNotificationOpen;
    if (!isSupported) return;

    await _ensureFirebaseInitialized();
    await _ensureLocalNotificationsInitialized();
    if (!_firebaseReady) return;

    FirebaseMessaging.onBackgroundMessage(nativePushBackgroundMessageHandler);

    if (!_listenersAttached) {
      _listenersAttached = true;
      _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((
        token,
      ) {
        _cachedFcmToken = token.trim().isEmpty ? null : token.trim();
        final localDio = _dio;
        if (localDio != null) {
          unawaited(syncCurrentEndpoint(localDio));
        }
      });
      _foregroundSub = FirebaseMessaging.onMessage.listen((message) async {
        await showForegroundNotificationFromMessage(message);
      });
      _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) async {
        final payload = _normalizeRemoteMessage(message);
        if (payload == null) return;
        _pendingTapPayload = payload;
        _pendingTapPayloadIsColdStart = false;
        await consumePendingTapPayload();
      });
    }

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      final payload = _normalizeRemoteMessage(initialMessage);
      if (payload != null) {
        _pendingTapPayload = payload;
        _pendingTapPayloadIsColdStart = true;
      }
    }

    final launchDetails =
        await _localNotifications.getNotificationAppLaunchDetails();
    final launchPayload = launchDetails?.notificationResponse?.payload;
    if (launchDetails?.didNotificationLaunchApp == true &&
        launchPayload != null &&
        launchPayload.trim().isNotEmpty) {
      captureBackgroundTapPayload(launchPayload, coldStart: true);
    }

    await syncCurrentEndpoint(dio);
  }

  static Future<void> ensureInitializedForBackground() async {
    if (!isSupported) return;
    await _ensureFirebaseInitialized();
    await _ensureLocalNotificationsInitialized();
  }

  static Future<bool> ensurePermissionInContext(BuildContext context) async {
    if (!isSupported) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final alreadyAllowed = await NativeUpdateInstaller.canPostNotifications();
      if (alreadyAllowed) return true;
      final granted = await NativeUpdateInstaller.requestNotificationPermission();
      if (granted) {
        final localDio = _dio;
        if (localDio != null) {
          await syncCurrentEndpoint(localDio);
        }
      }
      return granted;
    }

    await _ensureFirebaseInitialized();
    if (!_firebaseReady) return false;
    if (!context.mounted) return false;
    final current = await FirebaseMessaging.instance.getNotificationSettings();
    if (current.authorizationStatus == AuthorizationStatus.authorized ||
        current.authorizationStatus == AuthorizationStatus.provisional) {
      return true;
    }
    if (!context.mounted) return false;

    final accepted = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Разрешить уведомления Феникс?'),
              content: const Text(
                'Мы будем присылать только важные уведомления: сообщения, поддержку, безопасность, обновления и выбранные вами акции.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Не сейчас'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Разрешить'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!accepted) return false;

    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      sound: true,
      provisional: true,
      criticalAlert: false,
      carPlay: false,
      providesAppNotificationSettings: false,
    );
    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (granted) {
      final localDio = _dio;
      if (localDio != null) {
        await syncCurrentEndpoint(localDio);
      }
    }
    return granted;
  }

  static Future<void> syncCurrentEndpoint(Dio dio) async {
    if (!isSupported) return;
    await _ensureFirebaseInitialized();
    if (!_firebaseReady) return;

    final token = (await FirebaseMessaging.instance.getToken())?.trim() ?? '';
    if (token.isEmpty) return;
    _cachedFcmToken = token;

    try {
      final deviceKey = await generateDeviceFingerprint();
      final packageInfo = await PackageInfo.fromPlatform();
      await dio.post(
        '/api/notifications/endpoints/register',
        data: <String, dynamic>{
          'platform': _platformName(),
          'transport': 'fcm',
          'device_key': deviceKey,
          'push_token': token,
          'permission_state': await _permissionState(),
          'capabilities': _capabilities(),
          'app_version': '${packageInfo.version}+${packageInfo.buildNumber}',
          'locale': PlatformDispatcher.instance.locale.toLanguageTag(),
          'timezone': await resolveLocalTimeZoneId(),
        },
      );
    } catch (e) {
      debugPrint('NativePushService.syncCurrentEndpoint skipped: $e');
    }
  }

  static Future<void> unregisterCurrentEndpoint(Dio dio) async {
    if (!isSupported) return;
    final token = _cachedFcmToken?.trim();
    if (token == null || token.isEmpty) return;
    try {
      final deviceKey = await generateDeviceFingerprint();
      await dio.post(
        '/api/notifications/endpoints/unregister',
        data: <String, dynamic>{
          'platform': _platformName(),
          'transport': 'fcm',
          'device_key': deviceKey,
          'push_token': token,
        },
      );
    } catch (e) {
      debugPrint('NativePushService.unregisterCurrentEndpoint skipped: $e');
    }
  }

  static Future<void> consumePendingTapPayload() async {
    final payload = _pendingTapPayload;
    final handler = _tapHandler;
    if (payload == null || handler == null) return;
    _pendingTapPayload = null;
    final coldStart = _pendingTapPayloadIsColdStart;
    _pendingTapPayloadIsColdStart = false;
    try {
      await handler(payload, fromTap: true, coldStart: coldStart);
    } catch (e) {
      debugPrint('NativePushService.consumePendingTapPayload failed: $e');
      _pendingTapPayload = payload;
      _pendingTapPayloadIsColdStart = coldStart;
    }
  }

  static void captureBackgroundTapPayload(
    String? rawPayload, {
    bool coldStart = false,
  }) {
    final decoded = _decodePayload(rawPayload);
    if (decoded == null) return;
    _pendingTapPayload = decoded;
    _pendingTapPayloadIsColdStart = coldStart;
  }

  static Future<void> showForegroundNotificationFromMessage(
    RemoteMessage message,
  ) async {
    final payload = _normalizeRemoteMessage(message);
    if (payload == null) return;

    final category = _normalizeCategory(payload['category']);
    if (defaultTargetPlatform == TargetPlatform.android &&
        (category == 'chat' ||
            category == 'support' ||
            category == 'security' ||
            category == 'reserved' ||
            category == 'delivery')) {
      await _ensureLocalNotificationsInitialized();
      if (_localNotificationsReady) {
        final details = NotificationDetails(
          android: _buildAndroidDetails(payload),
          iOS: _buildDarwinDetails(payload),
          macOS: _buildDarwinDetails(payload),
        );
        final title = (payload['title'] ?? 'Проект Феникс').toString().trim();
        final body = (payload['body'] ?? '').toString().trim();
        final id = _stableNotificationId(payload);
        await _localNotifications.show(
          id: id,
          title: title,
          body: body.isEmpty ? null : body,
          notificationDetails: details,
          payload: jsonEncode(payload),
        );
      }
    }

    final handler = _tapHandler;
    if (handler != null) {
      await handler(payload, fromTap: false, coldStart: false);
    }
  }

  static Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    await _foregroundSub?.cancel();
    await _openedSub?.cancel();
    _tokenRefreshSub = null;
    _foregroundSub = null;
    _openedSub = null;
    _listenersAttached = false;
  }

  static Future<void> _ensureFirebaseInitialized() async {
    if (_firebaseReady || !isConfigured) return;
    try {
      if (Firebase.apps.isEmpty) {
        final options = FirebaseRuntimeOptions.currentPlatform;
        if (options == null) return;
        await Firebase.initializeApp(options: options);
      }
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
          alert: false,
          badge: true,
          sound: true,
        );
      }
      _firebaseReady = true;
    } catch (e) {
      debugPrint('NativePushService._ensureFirebaseInitialized failed: $e');
      _firebaseReady = false;
    }
  }

  static Future<void> _ensureLocalNotificationsInitialized() async {
    if (_localNotificationsReady || !isSupported) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      defaultPresentAlert: false,
      defaultPresentBanner: false,
      defaultPresentBadge: true,
      defaultPresentSound: true,
      defaultPresentList: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );
    await _localNotifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) async {
        final payload = _decodePayload(response.payload);
        if (payload == null) return;
        _pendingTapPayload = payload;
        _pendingTapPayloadIsColdStart = false;
        await consumePendingTapPayload();
      },
      onDidReceiveBackgroundNotificationResponse:
          nativePushBackgroundNotificationTap,
    );

    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      for (final channel in _androidChannels) {
        await androidPlugin.createNotificationChannel(channel);
      }
    }
    _localNotificationsReady = true;
  }

  static String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      default:
        return 'unknown';
    }
  }

  static Future<String> _permissionState() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final allowed = await NativeUpdateInstaller.canPostNotifications();
      return allowed ? 'granted' : 'denied';
    }
    if (!_firebaseReady) {
      return 'unknown';
    }
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    switch (settings.authorizationStatus) {
      case AuthorizationStatus.authorized:
        return 'granted';
      case AuthorizationStatus.denied:
        return 'denied';
      case AuthorizationStatus.notDetermined:
        return 'default';
      case AuthorizationStatus.provisional:
        return 'provisional';
    }
  }

  static Map<String, dynamic> _capabilities() {
    return <String, dynamic>{
      'push': true,
      'in_app': true,
      'badge': defaultTargetPlatform != TargetPlatform.android,
      'media_rich': true,
      'conversation': defaultTargetPlatform == TargetPlatform.android,
    };
  }

  static Map<String, dynamic>? _normalizeRemoteMessage(RemoteMessage message) {
    final data = Map<String, dynamic>.from(message.data);
    final notification = message.notification;
    final media = _decodeNestedMap(data['media']) ??
        <String, dynamic>{
          if ((notification?.android?.imageUrl ?? '').trim().isNotEmpty)
            'image_url': notification!.android!.imageUrl,
          if ((notification?.apple?.imageUrl ?? '').trim().isNotEmpty)
            'image_url': notification!.apple!.imageUrl,
        };
    final payload = _decodeNestedMap(data['payload']) ?? <String, dynamic>{};
    final category = _normalizeCategory(data['category'] ?? payload['category']);
    final inboxItemId =
        (data['inbox_item_id'] ?? payload['inbox_item_id'] ?? '').toString()
            .trim();
    return <String, dynamic>{
      'id': (data['id'] ?? data['message_id'] ?? message.messageId ?? '')
          .toString()
          .trim(),
      'category': category,
      'priority': (data['priority'] ?? payload['priority'] ?? 'normal')
          .toString()
          .trim()
          .toLowerCase(),
      'title': (data['title'] ?? notification?.title ?? '').toString().trim(),
      'body': (data['body'] ?? notification?.body ?? '').toString().trim(),
      'deep_link': (data['deep_link'] ?? payload['deep_link'] ?? data['url'] ?? '/')
          .toString()
          .trim(),
      'media': media,
      'payload': payload,
      'force_show':
          (data['force_show'] ?? payload['force_show'] ?? 'false')
                  .toString()
                  .toLowerCase() ==
              'true',
      'badge_count': int.tryParse(
            (data['badge_count'] ?? payload['badge_count'] ?? '').toString(),
          ) ??
          0,
      'inbox_item_id': inboxItemId,
      'campaign_id': (data['campaign_id'] ?? payload['campaign_id'] ?? '')
          .toString()
          .trim(),
      'cta_label': (data['cta_label'] ?? payload['cta_label'] ?? '')
          .toString()
          .trim(),
      'version': (data['version'] ?? payload['version'] ?? '')
          .toString()
          .trim(),
      'required_update':
          (data['required_update'] ?? payload['required_update'] ?? 'false')
                  .toString()
                  .toLowerCase() ==
              'true',
      'thread_id': (data['thread_id'] ??
              payload['thread_id'] ??
              payload['chat_id'] ??
              '')
          .toString()
          .trim(),
      if (inboxItemId.isNotEmpty) 'message_id': inboxItemId,
    };
  }

  static Map<String, dynamic>? _decodePayload(String? rawPayload) {
    final normalized = rawPayload?.trim() ?? '';
    if (normalized.isEmpty) return null;
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic>? _decodeNestedMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  static AndroidNotificationDetails _buildAndroidDetails(
    Map<String, dynamic> payload,
  ) {
    final category = _normalizeCategory(payload['category']);
    final threadId =
        (payload['thread_id'] ?? payload['payload']?['chat_id'] ?? '')
            .toString()
            .trim();
    final body = (payload['body'] ?? '').toString().trim();
    final title = (payload['title'] ?? 'Проект Феникс').toString().trim();

    final sender = Person(
      key: threadId.isEmpty ? category : threadId,
      name: title.isEmpty ? 'Феникс' : title,
      important: category == 'chat' || category == 'support',
    );

    final style = (category == 'chat' || category == 'support')
        ? MessagingStyleInformation(
            const Person(name: 'Вы'),
            conversationTitle: threadId.isEmpty ? null : title,
            groupConversation: false,
            messages: <Message>[
              Message(
                body.isEmpty ? 'Новое сообщение' : body,
                DateTime.now(),
                sender,
              ),
            ],
          )
        : BigTextStyleInformation(body.isEmpty ? title : body);

    return AndroidNotificationDetails(
      _androidChannelForCategory(category).id,
      _androidChannelForCategory(category).name,
      channelDescription: _androidChannelForCategory(category).description,
      importance: _importanceForCategory(category),
      priority: _priorityForCategory(category),
      styleInformation: style,
      category: _androidCategoryFor(category),
      tag: (payload['inbox_item_id'] ?? payload['id'] ?? category).toString(),
      channelShowBadge: category != 'promo' && category != 'updates',
      icon: '@mipmap/ic_launcher',
      colorized: category == 'security',
    );
  }

  static DarwinNotificationDetails _buildDarwinDetails(
    Map<String, dynamic> payload,
  ) {
    final category = _normalizeCategory(payload['category']);
    final badge = int.tryParse(
      (payload['badge_count'] ?? '').toString().trim(),
    );
    return DarwinNotificationDetails(
      presentBanner: false,
      presentList: false,
      presentAlert: false,
      presentSound: category != 'promo',
      presentBadge: true,
      badgeNumber: badge != null && badge >= 0 ? badge : null,
      threadIdentifier: (payload['thread_id'] ?? '').toString().trim().isEmpty
          ? null
          : (payload['thread_id'] ?? '').toString().trim(),
      interruptionLevel: _darwinInterruptionLevel(category, payload['priority']),
    );
  }

  static Importance _importanceForCategory(String category) {
    switch (category) {
      case 'chat':
      case 'support':
      case 'security':
        return Importance.high;
      case 'promo':
      case 'updates':
      case 'reserved':
      case 'delivery':
      default:
        return Importance.defaultImportance;
    }
  }

  static Priority _priorityForCategory(String category) {
    switch (category) {
      case 'chat':
      case 'support':
      case 'security':
        return Priority.high;
      default:
        return Priority.defaultPriority;
    }
  }

  static AndroidNotificationChannel _androidChannelForCategory(String category) {
    switch (category) {
      case 'chat':
        return _androidMessageChannel;
      case 'support':
        return _androidSupportChannel;
      case 'reserved':
        return _androidReservedChannel;
      case 'delivery':
        return _androidDeliveryChannel;
      case 'promo':
        return _androidPromoChannel;
      case 'updates':
        return _androidUpdatesChannel;
      case 'security':
      default:
        return _androidSecurityChannel;
    }
  }

  static AndroidNotificationCategory? _androidCategoryFor(String category) {
    switch (category) {
      case 'chat':
      case 'support':
        return AndroidNotificationCategory.message;
      case 'delivery':
        return AndroidNotificationCategory.progress;
      case 'security':
        return AndroidNotificationCategory.alarm;
      case 'promo':
        return AndroidNotificationCategory.recommendation;
      case 'updates':
        return AndroidNotificationCategory.status;
      default:
        return null;
    }
  }

  static InterruptionLevel _darwinInterruptionLevel(
    String category,
    dynamic rawPriority,
  ) {
    final priority = rawPriority.toString().trim().toLowerCase();
    if (category == 'security' || priority == 'critical') {
      return InterruptionLevel.timeSensitive;
    }
    if (category == 'support' || category == 'delivery') {
      return InterruptionLevel.active;
    }
    if (category == 'promo' || category == 'updates') {
      return InterruptionLevel.passive;
    }
    return InterruptionLevel.active;
  }

  static String _normalizeCategory(dynamic raw) {
    final normalized = raw.toString().trim().toLowerCase();
    switch (normalized) {
      case 'chat':
      case 'support':
      case 'reserved':
      case 'delivery':
      case 'promo':
      case 'updates':
      case 'security':
        return normalized;
      default:
        return 'support';
    }
  }

  static int _stableNotificationId(Map<String, dynamic> payload) {
    final raw = (payload['inbox_item_id'] ?? payload['id'] ?? payload['deep_link'] ?? '')
        .toString()
        .trim();
    if (raw.isEmpty) {
      return DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    }
    return raw.hashCode & 0x7fffffff;
  }
}
