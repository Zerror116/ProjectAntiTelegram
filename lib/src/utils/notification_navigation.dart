import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../main.dart';
import '../../screens/chat_screen.dart';

bool _initialNotificationDeepLinkConsumed = false;

Uri? _parseNotificationUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    return Uri.parse(trimmed);
  } catch (_) {
    return null;
  }
}

bool _looksLikeNotificationDeepLink(Uri uri) {
  final path = uri.path.toLowerCase().trim();
  if (uri.queryParameters.containsKey('chatId') ||
      uri.queryParameters.containsKey('chat_id')) {
    return true;
  }
  return path.contains('chat') ||
      path.contains('notification') ||
      path.contains('reserved') ||
      path.contains('support') ||
      path.contains('update');
}

bool _canOpenNotificationCenter() {
  return authService.effectiveRole.toLowerCase().trim() == 'creator';
}

String? consumeInitialNotificationDeepLink() {
  if (!kIsWeb || _initialNotificationDeepLinkConsumed) return null;
  final uri = Uri.base;
  if (!_looksLikeNotificationDeepLink(uri)) return null;
  _initialNotificationDeepLinkConsumed = true;
  return uri.toString();
}

Map<String, dynamic>? consumeInitialNotificationTapPayload() {
  if (!kIsWeb || _initialNotificationDeepLinkConsumed) return null;
  final rawPayload = Uri.base.queryParameters['notification_payload']?.trim() ?? '';
  if (rawPayload.isEmpty) return null;
  try {
    final decoded = jsonDecode(rawPayload);
    if (decoded is Map<String, dynamic>) {
      _initialNotificationDeepLinkConsumed = true;
      return decoded;
    }
    if (decoded is Map) {
      _initialNotificationDeepLinkConsumed = true;
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}
  return null;
}

String? _chatIdFrom(Uri? uri, Map<String, dynamic>? payload) {
  final direct =
      (uri?.queryParameters['chatId'] ?? uri?.queryParameters['chat_id'] ?? '')
          .trim();
  if (direct.isNotEmpty) return direct;
  final map = payload ?? const <String, dynamic>{};
  final payloadChatId = (map['chat_id'] ?? map['chatId'] ?? '')
      .toString()
      .trim();
  if (payloadChatId.isNotEmpty) return payloadChatId;
  final nested = map['data'];
  if (nested is Map) {
    final nestedChatId = (nested['chat_id'] ?? nested['chatId'] ?? '')
        .toString()
        .trim();
    if (nestedChatId.isNotEmpty) return nestedChatId;
  }
  return null;
}

Future<Map<String, dynamic>?> _loadChatMeta(String chatId) async {
  try {
    final response = await authService.dio.get('/api/chats/list');
    final root = response.data;
    if (root is Map && root['ok'] == true && root['data'] is List) {
      for (final raw in root['data']) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        if ((row['id'] ?? '').toString().trim() == chatId) {
          return row;
        }
      }
    }
  } on DioException {
    // Fallback below.
  } catch (_) {}

  try {
    final response = await authService.dio.get('/api/chats');
    final root = response.data;
    if (root is List) {
      for (final raw in root) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        if ((row['id'] ?? '').toString().trim() == chatId) {
          return row;
        }
      }
    }
    if (root is Map && root['ok'] == true && root['data'] is List) {
      for (final raw in root['data']) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        if ((row['id'] ?? '').toString().trim() == chatId) {
          return row;
        }
      }
    }
  } catch (_) {}

  return null;
}

Future<bool> _openChat(BuildContext context, String chatId) async {
  final normalizedChatId = chatId.trim();
  if (normalizedChatId.isEmpty) return false;
  final chat = await _loadChatMeta(normalizedChatId);
  if (chat == null) {
    showGlobalAppNotice(
      'Не удалось открыть чат: он недоступен или уже скрыт.',
      title: 'Уведомления',
      tone: AppNoticeTone.warning,
    );
    return false;
  }

  activeShellSectionNotifier.value = 'chats';
  final title =
      (chat['display_title'] ??
              chat['peer_display_name'] ??
              chat['title'] ??
              'Чат')
          .toString()
          .trim();
  final rawSettings = chat['settings'];
  final settings = rawSettings is Map<String, dynamic>
      ? rawSettings
      : rawSettings is Map
      ? Map<String, dynamic>.from(rawSettings)
      : null;

  final navigator = navigatorKey.currentState;
  if (navigator == null) return false;
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        chatId: normalizedChatId,
        chatTitle: title.isNotEmpty ? title : 'Чат',
        chatType: (chat['type'] ?? '').toString().trim().isEmpty
            ? null
            : (chat['type'] ?? '').toString().trim(),
        chatSettings: settings,
      ),
    ),
  );
  return true;
}

Future<bool> openNotificationDeepLink(
  BuildContext context,
  String rawDeepLink, {
  Map<String, dynamic>? payload,
}) async {
  final uri = _parseNotificationUri(rawDeepLink);
  final chatId = _chatIdFrom(uri, payload);
  if ((chatId ?? '').isNotEmpty) {
    return _openChat(context, chatId!);
  }

  if (uri == null) return false;
  final path = uri.path.toLowerCase().trim();
  if (path.contains('notification')) {
    if (!_canOpenNotificationCenter()) {
      showGlobalAppNotice(
        'Раздел событий доступен только создателю.',
        title: 'Уведомления',
        tone: AppNoticeTone.info,
      );
      return false;
    }
    activeShellSectionNotifier.value = 'notifications';
    return true;
  }
  if (path.contains('update')) {
    activeShellSectionNotifier.value = 'settings';
    showGlobalAppNotice(
      'Переходим к разделу, где можно проверить обновление приложения.',
      title: 'Обновление',
      tone: AppNoticeTone.info,
    );
    return true;
  }
  if (path.contains('support') ||
      path.contains('reserved') ||
      path.contains('delivery')) {
    activeShellSectionNotifier.value = 'chats';
    return true;
  }
  return false;
}
