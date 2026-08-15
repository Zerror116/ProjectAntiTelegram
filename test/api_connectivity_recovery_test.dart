import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projectphoenix/main.dart' as app;

DioException _connectionError(String message) {
  return DioException(
    requestOptions: RequestOptions(
      path: '/api/worker/channels',
      baseUrl: 'https://garphoenix.com',
    ),
    type: DioExceptionType.connectionError,
    message: message,
  );
}

void main() {
  group('API connectivity recovery', () {
    test('treats connection refused as recoverable connectivity failure', () {
      final error = _connectionError(
        'The connection errored: Connection refused. '
        'This indicates an error which most likely cannot be solved by the library.',
      );

      expect(
        app.debugIsRecoverableApiConnectivityFailureForTesting(error),
        isTrue,
      );
    });

    test('falls back between production API hosts', () {
      expect(
        app.debugFallbackApiBaseForConnectivityFailureForTesting(
          'https://garphoenix.com',
        ),
        'https://www.garphoenix.com',
      );
      expect(
        app.debugFallbackApiBaseForConnectivityFailureForTesting(
          'https://www.garphoenix.com',
        ),
        'https://garphoenix.com',
      );
    });
  });

  group('chat web media stability', () {
    test('blob fallback is bounded and does not use raw Dio get', () {
      final source = File('lib/screens/chat_screen.dart').readAsStringSync();

      expect(source, contains('Future<Uint8List?> _readWebBlobBytesSafely'));
      expect(source, contains('connectTimeout: const Duration(seconds: 2)'));
      expect(source, contains('receiveTimeout: const Duration(seconds: 6)'));
      expect(source, contains('.timeout(const Duration(seconds: 8))'));
      expect(source, isNot(contains('Dio().get<List<int>>')));
      expect(
        source,
        contains("throw StateError('Selected image files are unreadable')"),
      );
    });

    test('worker image picker uses bounded web blob reads', () {
      final source = File('lib/screens/worker_panel.dart').readAsStringSync();

      expect(source, contains('Future<Uint8List?> _readWebBlobBytesSafely'));
      expect(source, contains('Future<Uint8List?> _readXFileBytesSafely'));
      expect(source, contains('connectTimeout: const Duration(seconds: 2)'));
      expect(source, contains('receiveTimeout: const Duration(seconds: 6)'));
      expect(source, contains('.timeout(const Duration(seconds: 8))'));
      expect(source, isNot(contains('Dio().get<List<int>>')));
    });

    test('file picker reads are bounded on heavy user-facing screens', () {
      for (final path in <String>[
        'lib/screens/admin_panel.dart',
        'lib/screens/profile_screen.dart',
        'lib/screens/cart_screen.dart',
        'lib/screens/admin_promotion_center_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        final unboundedReads = RegExp(
          r'readAsBytes\(\)(?!\.timeout)',
        ).allMatches(source).length;

        expect(
          unboundedReads,
          0,
          reason: '$path must not read picked files without a timeout',
        );
      }
    });

    test('image file picker keeps web bytes for Safari uploads', () {
      final helperSource = File(
        'lib/src/utils/image_file_picker.dart',
      ).readAsStringSync();

      expect(
        helperSource,
        contains('Future<PlatformFile?> pickSingleImageFile'),
      );
      expect(helperSource, contains('withData: kIsWeb'));
      expect(helperSource, contains('allowMultiple: false'));
      expect(
        helperSource,
        contains('Future<List<PlatformFile>> pickImageFiles'),
      );
      expect(helperSource, contains('allowMultiple: true'));

      for (final path in <String>[
        'lib/screens/admin_panel.dart',
        'lib/screens/profile_screen.dart',
        'lib/screens/cart_screen.dart',
        'lib/screens/admin_promotion_center_screen.dart',
        'lib/screens/worker_panel.dart',
        'lib/screens/chat_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          isNot(contains('FilePicker.pickFile(type: FileType.image)')),
          reason:
              '$path must use pickSingleImageFile so web uploads keep bytes',
        );
      }
    });

    test('chat attachment sheet does not auto-start camera', () {
      final source = File('lib/screens/chat_screen.dart').readAsStringSync();

      expect(source, contains('autoStartCamera: false'));
      expect(
        source,
        isNot(contains('Запускается сразу при открытии скрепки.')),
      );
      expect(source, contains('Включается только по нажатию.'));
    });

    test('chat image dimension warm-up is bounded and cache-limited', () {
      final source = File(
        'lib/widgets/chat_message_image.dart',
      ).readAsStringSync();

      expect(source, contains('_chatMessageImageCacheLimit = 600'));
      expect(
        source,
        contains('_chatMessageImageResolveTimeout = Duration(seconds: 12)'),
      );
      expect(source, contains('timeoutTimer = Timer('));
      expect(source, contains('detachListener();'));
      expect(source, contains('_rememberChatMessageImageSize'));
      expect(source, contains('_rememberChatMessageImageRendered'));
      expect(source, contains('_imageResolveTimeoutTimer'));
    });
  });

  group('server chat unread stability', () {
    test('uses local chat sequence for unread state', () {
      final chatsSource = File('server/src/routes/chats.js').readAsStringSync();
      final notificationsSource = File(
        'server/src/utils/notifications.js',
      ).readAsStringSync();
      final bootstrapSource = File(
        'server/src/utils/bootstrap.js',
      ).readAsStringSync();
      final migrationSource = File(
        'server/migrations/080_chat_local_sequence_unread_state.sql',
      ).readAsStringSync();

      expect(migrationSource, contains('ADD COLUMN IF NOT EXISTS chat_seq'));
      expect(migrationSource, contains('last_read_chat_seq'));
      expect(migrationSource, contains('assign_message_chat_seq'));
      expect(chatsSource, contains('last_read_chat_seq'));
      expect(chatsSource, contains('m.chat_seq > rs.last_read_chat_seq'));
      expect(chatsSource, contains('um.chat_seq >'));
      expect(notificationsSource, contains('m.chat_seq >'));
      expect(chatsSource, isNot(contains('COALESCE(um.chat_seq, 0) >')));
      expect(chatsSource, isNot(contains('COALESCE(m.chat_seq, 0) >')));
      expect(notificationsSource, contains('last_read_chat_seq'));
      expect(notificationsSource, isNot(contains('COALESCE(m.chat_seq, 0) >')));
      expect(bootstrapSource, contains(r'pg_advisory_lock(hashtext($1))'));
      expect(bootstrapSource, contains('ON CONFLICT (filename) DO NOTHING'));
      expect(chatsSource, isNot(contains('last_read_msg.created_at')));
      expect(notificationsSource, isNot(contains('last_read_msg.created_at')));
    });
  });

  group('notification prompt stability', () {
    test('notification badge refresh coalesces realtime bursts', () {
      final source = File('lib/main.dart').readAsStringSync();

      expect(
        source,
        contains('Future<void>? _notificationBadgeRefreshInFlight'),
      );
      expect(source, contains('bool _notificationBadgeRefreshPending = false'));
      expect(
        source,
        contains('Future<void> _runNotificationBadgeRefreshLoop()'),
      );
      expect(
        source,
        contains('Future<void> _refreshNotificationBadgeCountOnce()'),
      );
      expect(source, contains('_notificationBadgeRefreshPending = true'));
      expect(source, contains("'/api/notifications/badge-count'"));
      expect(
        source,
        contains('final activeUserId = authService.currentUser?.id.trim()'),
      );
      expect(source, contains('if (activeUserId != userId)'));
    });

    test('support queue refresh coalesces periodic and realtime calls', () {
      final source = File('lib/main.dart').readAsStringSync();

      expect(source, contains('Future<void>? _supportQueueRefreshInFlight'));
      expect(source, contains('bool _supportQueueRefreshPending = false'));
      expect(source, contains('String _supportQueueRefreshScope()'));
      expect(source, contains('Future<void> _runSupportQueueRefreshLoop()'));
      expect(
        source,
        contains('Future<void> _refreshSupportQueueNoticesOnce()'),
      );
      expect(source, contains('_supportQueueRefreshPending = true'));
      expect(
        source,
        contains('if (_supportQueueRefreshScope() != refreshScope)'),
      );
    });

    test('global notification runtime reconcile is scoped and coalesced', () {
      final source = File('lib/main.dart').readAsStringSync();

      expect(
        source,
        contains('Future<void>? _notificationRuntimeReconcileInFlight'),
      );
      expect(
        source,
        contains('bool _notificationRuntimeReconcilePending = false'),
      );
      expect(
        source,
        contains('Future<void> _runNotificationRuntimeReconcileLoop()'),
      );
      expect(
        source,
        contains('Future<void> _reconcileCurrentNotificationRuntimeOnce()'),
      );
      expect(source, contains('_notificationRuntimeReconcilePending = true'));
      expect(
        source,
        contains('final activeUserId = authService.currentUser?.id.trim()'),
      );
      expect(
        source,
        contains('authService.isSessionDegraded || activeUserId != userId'),
      );
      final reconcileStart = source.indexOf(
        'Future<void> _reconcileCurrentNotificationRuntimeOnce()',
      );
      final reconcileEnd = source.indexOf(
        'Future<void> setDarkModeEnabled',
        reconcileStart,
      );
      expect(reconcileStart, greaterThanOrEqualTo(0));
      expect(reconcileEnd, greaterThan(reconcileStart));
      final reconcileSource = source.substring(reconcileStart, reconcileEnd);
      expect(reconcileSource, contains('userId: userId'));
      expect(reconcileSource, isNot(contains('userId: user.id')));
    });

    test(
      'web prompt dismissal is only persisted after permission is granted',
      () {
        final source = File('lib/screens/main_shell.dart').readAsStringSync();
        final dismissStart = source.indexOf(
          'Future<void> _dismissWebNotificationPrompt()',
        );
        final requestStart = source.indexOf(
          'Future<void> _requestWebNotificationAccess()',
        );
        final dismissSource = source.substring(dismissStart, requestStart);

        expect(
          source,
          contains(
            'permission == WebNotificationPermissionState.granted && dismissed',
          ),
        );
        expect(
          source,
          contains(
            '_webNotificationBannerDismissed =\n'
            '          permission == WebNotificationPermissionState.granted;',
          ),
        );
        expect(
          dismissSource,
          isNot(contains('_webNotificationBannerDismissed = true;')),
        );
      },
    );

    test('notification runtime sync coalesces startup calls', () {
      final source = File('lib/screens/main_shell.dart').readAsStringSync();

      expect(
        source,
        contains('Future<void>? _notificationRuntimeSyncInFlight'),
      );
      expect(source, contains('bool _notificationRuntimeSyncPending = false'));
      expect(
        source,
        contains('final inFlight = _notificationRuntimeSyncInFlight'),
      );
      expect(source, contains('_notificationRuntimeSyncPending = true'));
      expect(
        source,
        contains('Future<void> _runNotificationRuntimeSyncLoop()'),
      );
      expect(
        source,
        contains('Future<void> _runNotificationRuntimeSyncOnce()'),
      );
      expect(
        source,
        contains('bool _notificationRuntimeStillMatches(String userId)'),
      );
      expect(source, contains('authService.currentUser?.id == userId'));
      expect(source, isNot(contains('userId: authService.currentUser?.id')));
    });

    test('web system notifications pass silent flag to browser', () {
      final source = File(
        'lib/services/web_notification_service_web.dart',
      ).readAsStringSync();

      expect(source, contains("import 'dart:js_interop';"));
      expect(source, contains("import 'dart:js_interop_unsafe';"));
      expect(source, contains('globalContext'));
      expect(source, contains("'Notification'"));
      expect(source, contains("'silent': true"));
      expect(source, contains('callAsConstructor<JSObject>'));
    });

    test('web push sync and service worker calls are bounded', () {
      final source = File(
        'lib/services/web_push_client_service_web.dart',
      ).readAsStringSync();
      final wrapperSource = File(
        'lib/services/web_push_client_service.dart',
      ).readAsStringSync();
      final imageCacheSource = File(
        'lib/services/web_image_cache_service_web.dart',
      ).readAsStringSync();
      final pushHelperSource = File(
        'web/push_client_helper.js',
      ).readAsStringSync();
      final pushWorkerSource = File(
        'web/push_service_worker.js',
      ).readAsStringSync();

      expect(source, contains('Duration timeout = const Duration(seconds: 6)'));
      expect(
        wrapperSource,
        contains('Future<void>? _syncUnreadBadgeCountInFlight'),
      );
      expect(wrapperSource, contains('int? _pendingUnreadBadgeCount'));
      expect(
        wrapperSource,
        contains('_pendingUnreadBadgeCount = count < 0 ? 0 : count'),
      );
      expect(source, contains("sw.getRegistration().timeout"));
      expect(source, contains("register(workerUrl)"));
      expect(source, contains(".timeout(const Duration(seconds: 5))"));
      expect(
        source,
        contains("'/api/web-push/config',\n          options: Options("),
      );
      expect(source, contains("'/api/web-push/badge-count'"));
      expect(source, contains(".timeout(const Duration(seconds: 12))"));
      expect(imageCacheSource, contains('sw.getRegistration().timeout'));
      expect(imageCacheSource, contains('sw.register(workerUrl).timeout'));
      expect(pushHelperSource, contains('function withTimeout'));
      expect(pushHelperSource, contains('navigator.serviceWorker.ready, 4000'));
      expect(pushHelperSource, contains('registration.pushManager.subscribe'));
      expect(
        pushWorkerSource,
        contains('SERVICE_WORKER_OPERATION_TIMEOUT_MS = 2500'),
      );
      expect(
        pushWorkerSource,
        contains('MEDIA_PRECACHE_FETCH_TIMEOUT_MS = 7000'),
      );
      expect(pushWorkerSource, contains('CACHE_TRIM_DELETE_BATCH_SIZE = 24'));
      expect(pushWorkerSource, contains('function withTimeout'));
      expect(pushWorkerSource, contains('withTimeout(self.clients.matchAll'));
      expect(pushWorkerSource, contains('self.clients.openWindow(targetUrl)'));
    });

    test('web media capture permission requests are bounded', () {
      final permissionSource = File(
        'lib/services/web_media_capture_permission_service_web.dart',
      ).readAsStringSync();
      final videoNoteSource = File(
        'lib/services/web_video_note_capture_service_web.dart',
      ).readAsStringSync();

      expect(permissionSource, contains("callMethod('getUserMedia'"));
      expect(
        permissionSource,
        contains(".timeout(const Duration(seconds: 12))"),
      );
      expect(videoNoteSource, contains('.getUserMedia(<String, dynamic>{'));
      expect(
        videoNoteSource,
        contains(".timeout(const Duration(seconds: 12))"),
      );
      expect(videoNoteSource, contains('_recordingStopTimeout'));
      expect(videoNoteSource, contains('_recordingCancelTimeout'));
      expect(videoNoteSource, contains('_blobReadTimeout'));
      expect(
        videoNoteSource,
        contains(
          "throw TimeoutException('Video note recording stop timed out')",
        ),
      );
      expect(videoNoteSource, contains("reader.abort();"));
      expect(
        videoNoteSource,
        contains("TimeoutException('Blob read timed out')"),
      );
    });

    test('web bootstrap service worker and cache cleanup are bounded', () {
      final webIndex = File('web/index.html').readAsStringSync();
      final cacheReset = File(
        'web/phoenix_cache_reset.html',
      ).readAsStringSync();

      expect(webIndex, contains('serviceWorkerCleanupTimeoutMs = 2500'));
      expect(webIndex, contains('cacheCleanupTimeoutMs = 2500'));
      expect(webIndex, contains('navigator.serviceWorker.getRegistrations()'));
      expect(webIndex, contains('registration.unregister(),'));
      expect(webIndex, contains('caches.keys(),'));
      expect(webIndex, contains('await withTimeout(Promise.all('));
      expect(cacheReset, contains('operationTimeoutMs = 2500'));
      expect(cacheReset, contains('const withTimeout = function'));
      expect(
        cacheReset,
        contains('navigator.serviceWorker.getRegistrations()'),
      );
      expect(cacheReset, contains('registration.unregister()'));
    });
  });

  group('android web startup', () {
    test('does not force android web into auth-only mode', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final shellSource = File(
        'lib/screens/main_shell.dart',
      ).readAsStringSync();
      final authSource = File(
        'lib/screens/auth_screen.dart',
      ).readAsStringSync();

      expect(
        mainSource,
        isNot(
          contains(
            'if (kIsWeb && defaultTargetPlatform == TargetPlatform.android) {\n'
            '    return const AuthScreen();',
          ),
        ),
      );
      expect(shellSource, isNot(contains('if (_isAndroidWeb()) return;')));
      expect(
        shellSource,
        isNot(
          contains('if (_isAndroidWeb()) {\n      return const AuthScreen();'),
        ),
      );
      expect(
        authSource,
        contains('bool _isAndroidWebRestricted() {\n    return false;\n  }'),
      );
    });

    test('managed update status polling is non-overlapping', () {
      final source = File('lib/main.dart').readAsStringSync();
      final downloadStart = source.indexOf(
        'Future<bool> _downloadAndInstallAndroidUpdate',
      );
      final downloadEnd = source.indexOf(
        'Future<bool> _openAndroidFallbackUpdateUri',
        downloadStart,
      );
      expect(downloadStart, greaterThanOrEqualTo(0));
      expect(downloadEnd, greaterThan(downloadStart));
      final downloadSource = source.substring(downloadStart, downloadEnd);

      expect(downloadSource, contains('var statusPollInFlight = false'));
      expect(downloadSource, contains('if (statusPollInFlight) return'));
      expect(downloadSource, contains('statusPollInFlight = true'));
      expect(downloadSource, contains('statusPollInFlight = false'));
      expect(
        downloadSource,
        contains('poller = Timer.periodic(const Duration(milliseconds: 750)'),
      );
    });
  });

  group('notification and chat navigation stability', () {
    test('input language polling is bounded and non-overlapping', () {
      final source = File(
        'lib/services/input_language_service.dart',
      ).readAsStringSync();

      expect(source, contains('bool _refreshInFlight = false'));
      expect(
        source,
        contains('if (!_nativeLookupAvailable || _refreshInFlight) return'),
      );
      expect(source, contains('_refreshInFlight = true'));
      expect(source, contains('_refreshInFlight = false'));
      expect(source, contains(".timeout(const Duration(milliseconds: 800)"));
    });

    test('chat offline queue count refresh is coalesced', () {
      final chatSource = File(
        'lib/screens/chat_screen.dart',
      ).readAsStringSync();

      expect(
        chatSource,
        contains('Future<void>? _offlineQueueCountRefreshInFlight'),
      );
      expect(
        chatSource,
        contains('bool _offlineQueueCountRefreshPending = false'),
      );
      expect(
        chatSource,
        contains('Future<void> _runOfflineQueueCountRefreshLoop()'),
      );
      expect(
        chatSource,
        contains('Future<void> _refreshOfflineQueueCountOnce()'),
      );
      expect(chatSource, contains('_offlineQueueCountRefreshPending = true'));
      expect(
        chatSource,
        contains('final activeUserId = authService.currentUser?.id.trim()'),
      );
    });

    test('delivery dashboard refreshes are non-overlapping', () {
      final adminSource = File(
        'lib/screens/admin_panel.dart',
      ).readAsStringSync();
      final workerSource = File(
        'lib/screens/worker_panel.dart',
      ).readAsStringSync();

      expect(
        adminSource,
        contains('bool _deliveryDashboardLoadInFlight = false'),
      );
      expect(
        adminSource,
        contains('bool _deliveryDashboardLoadQueued = false'),
      );
      expect(adminSource, contains('if (_deliveryDashboardLoadInFlight) {'));
      expect(adminSource, contains('_deliveryDashboardLoadQueued = true;'));
      expect(adminSource, contains('unawaited(_loadDeliveryDashboard());'));

      expect(
        workerSource,
        contains('bool _deliveryDashboardLoadInFlight = false'),
      );
      expect(
        workerSource,
        contains('bool _deliveryDashboardLoadQueued = false'),
      );
      expect(
        workerSource,
        contains('bool _deliveryDashboardQueuedSilent = true'),
      );
      expect(
        workerSource,
        contains('_deliveryDashboardQueuedSilent && silent'),
      );
      expect(
        workerSource,
        contains('unawaited(_loadDeliveryDashboard(silent: queuedSilent));'),
      );
    });

    test('notification chat fallback and server search are bounded', () {
      final navigationSource = File(
        'lib/src/utils/notification_navigation.dart',
      ).readAsStringSync();
      final chatSource = File(
        'lib/screens/chat_screen.dart',
      ).readAsStringSync();

      expect(
        navigationSource,
        contains("queryParameters: kIsWeb\n              ? {'_ts':"),
      );
      expect(
        navigationSource,
        contains("headers: const {\n              'Cache-Control':"),
      );
      expect(
        navigationSource,
        contains('receiveTimeout: const Duration(seconds: 12)'),
      );
      expect(
        navigationSource,
        contains('.timeout(const Duration(seconds: 14))'),
      );
      expect(chatSource, contains("'/api/chats/\${widget.chatId}/search'"));
      expect(
        chatSource,
        contains('receiveTimeout: const Duration(seconds: 12)'),
      );
      expect(chatSource, contains('.timeout(const Duration(seconds: 14))'));
    });
  });

  group('phone access routing', () {
    test('does not trust stale pending state when feature flag is missing', () {
      expect(
        app.debugShouldShowPhoneAccessPendingForTesting({
          'id': 'client-1',
          'email': 'client@example.test',
          'role': 'client',
          'phone_access_state': 'pending',
        }),
        isFalse,
      );
    });

    test('uses pending route when phone access approval is enabled', () {
      expect(
        app.debugShouldShowPhoneAccessPendingForTesting({
          'id': 'client-1',
          'email': 'client@example.test',
          'role': 'client',
          'phone_access_state': 'pending',
          'feature_settings': {
            'phone_access_approval_enabled': true,
            'client': {'phone_access_approval_enabled': true},
          },
        }),
        isTrue,
      );
    });

    test('recognizes server phone access restriction response', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/api/cart'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/cart'),
          statusCode: 423,
          data: {
            'code': 'phone_access_pending',
            'phone_access': {'state': 'pending'},
          },
        ),
        type: DioExceptionType.badResponse,
      );

      expect(app.debugIsPhoneAccessRestrictionErrorForTesting(error), isTrue);
    });
  });
}
