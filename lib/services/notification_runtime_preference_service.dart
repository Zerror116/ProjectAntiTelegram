import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_coordinator_service.dart';

const _notificationsPrefPrefix = 'notifications_enabled_';
const _notificationPolicyPrefix = 'notifications_runtime_policy_';

class NotificationRuntimePolicy {
  final bool enabled;
  final bool messagePreviewEnabled;
  final bool soundEnabled;
  final bool showWhenActive;

  const NotificationRuntimePolicy({
    required this.enabled,
    required this.messagePreviewEnabled,
    required this.soundEnabled,
    required this.showWhenActive,
  });

  const NotificationRuntimePolicy.defaults()
    : enabled = true,
      messagePreviewEnabled = true,
      soundEnabled = true,
      showWhenActive = false;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'enabled': enabled,
      'message_preview_enabled': messagePreviewEnabled,
      'sound_enabled': soundEnabled,
      'show_when_active': showWhenActive,
    };
  }

  NotificationRuntimePolicy copyWith({
    bool? enabled,
    bool? messagePreviewEnabled,
    bool? soundEnabled,
    bool? showWhenActive,
  }) {
    return NotificationRuntimePolicy(
      enabled: enabled ?? this.enabled,
      messagePreviewEnabled:
          messagePreviewEnabled ?? this.messagePreviewEnabled,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      showWhenActive: showWhenActive ?? this.showWhenActive,
    );
  }

  static NotificationRuntimePolicy fromJson(Map<String, dynamic>? raw) {
    final source = raw ?? const <String, dynamic>{};
    return NotificationRuntimePolicy(
      enabled: source['enabled'] != false,
      messagePreviewEnabled: source['message_preview_enabled'] != false,
      soundEnabled: source['sound_enabled'] != false,
      showWhenActive: source['show_when_active'] == true,
    );
  }

  static NotificationRuntimePolicy fromServerPreferences(
    Map<String, dynamic> data, {
    required bool enabled,
  }) {
    return NotificationRuntimePolicy(
      enabled: enabled,
      messagePreviewEnabled: data['message_preview_enabled'] != false,
      soundEnabled: data['sound_enabled'] != false,
      showWhenActive: data['show_when_active'] == true,
    );
  }
}

class NotificationRuntimePreferenceService {
  const NotificationRuntimePreferenceService._();

  static Future<NotificationRuntimePolicy>? _policyRefreshInFlight;

  static String settingsScopeUserId(String? userId) {
    final normalized = (userId ?? '').trim();
    return normalized.isEmpty ? 'guest' : normalized;
  }

  static String _policyKey(String? userId) {
    final scope = settingsScopeUserId(userId);
    return '$_notificationPolicyPrefix$scope';
  }

  static Future<bool> isEnabledForUser(String? userId) async {
    final prefs = await SharedPreferences.getInstance();
    final scope = settingsScopeUserId(userId);
    return prefs.getBool('$_notificationsPrefPrefix$scope') ?? true;
  }

  static Future<void> persistEnabledForUser(String? userId, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final scope = settingsScopeUserId(userId);
    await prefs.setBool('$_notificationsPrefPrefix$scope', value);
    final current = await getCachedPolicyForUser(userId);
    await persistPolicyForUser(userId, current.copyWith(enabled: value));
  }

  static Future<NotificationRuntimePolicy> getCachedPolicyForUser(
    String? userId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = await isEnabledForUser(userId);
    final raw = prefs.getString(_policyKey(userId))?.trim() ?? '';
    if (raw.isEmpty) {
      return const NotificationRuntimePolicy.defaults().copyWith(
        enabled: enabled,
      );
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return NotificationRuntimePolicy.fromJson(
          decoded,
        ).copyWith(enabled: enabled);
      }
      if (decoded is Map) {
        return NotificationRuntimePolicy.fromJson(
          Map<String, dynamic>.from(decoded),
        ).copyWith(enabled: enabled);
      }
    } catch (_) {}
    return const NotificationRuntimePolicy.defaults().copyWith(
      enabled: enabled,
    );
  }

  static Future<void> persistPolicyForUser(
    String? userId,
    NotificationRuntimePolicy policy,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_policyKey(userId), jsonEncode(policy.toJson()));
  }

  static bool deriveEnabledFromServerPreferences(Map<String, dynamic> data) {
    final categories = data['categories'] is Map
        ? Map<String, dynamic>.from(data['categories'] as Map)
        : const <String, dynamic>{};
    final channels = data['channels'] is Map
        ? Map<String, dynamic>.from(data['channels'] as Map)
        : const <String, dynamic>{};
    return channels.values.any((value) => value == true) ||
        categories.values.any((value) => value == true) ||
        data['promo_opt_in'] == true ||
        data['updates_opt_in'] != false;
  }

  static Future<NotificationRuntimePolicy> refreshServerPolicy(
    Dio dio, {
    String? userId,
  }) async {
    final inFlight = _policyRefreshInFlight;
    if (inFlight != null) return inFlight;
    final future = (() async {
      try {
        final response = await dio.get('/api/notifications/preferences');
        final root = response.data;
        final data = root is Map && root['data'] is Map
            ? Map<String, dynamic>.from(root['data'])
            : const <String, dynamic>{};
        final enabled = await isEnabledForUser(userId);
        final policy = NotificationRuntimePolicy.fromServerPreferences(
          data,
          enabled: enabled,
        );
        await persistPolicyForUser(userId, policy);
        return policy;
      } catch (_) {
        return getCachedPolicyForUser(userId);
      }
    })();
    _policyRefreshInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_policyRefreshInFlight, future)) {
        _policyRefreshInFlight = null;
      }
    }
  }

  static NotificationRuntimePolicy policyFromPayload(
    Map<String, dynamic> payload, {
    required NotificationRuntimePolicy fallback,
  }) {
    final presentation = payload['presentation'];
    final map = presentation is Map<String, dynamic>
        ? presentation
        : presentation is Map
        ? Map<String, dynamic>.from(presentation)
        : const <String, dynamic>{};
    return fallback.copyWith(
      messagePreviewEnabled:
          _parseBoolLike(map['message_preview_enabled']) ??
          fallback.messagePreviewEnabled,
      soundEnabled:
          _parseBoolLike(map['sound_enabled']) ??
          ((_parseBoolLike(payload['silent']) ?? false)
              ? false
              : fallback.soundEnabled),
      showWhenActive:
          _parseBoolLike(map['show_when_active']) ?? fallback.showWhenActive,
    );
  }

  static Future<void> applyRuntimePreference(
    Dio dio, {
    required bool enabled,
    String? userId,
  }) async {
    final policy = await getCachedPolicyForUser(userId);
    await NotificationCoordinatorService.reconcile(
      dio,
      enabled: enabled,
      userId: userId,
      runtimePolicySnapshot: policy.toJson(),
    );
  }

  static bool? _parseBoolLike(dynamic raw) {
    if (raw is bool) return raw;
    final normalized = raw?.toString().trim().toLowerCase();
    if (normalized == 'true') return true;
    if (normalized == 'false') return false;
    return null;
  }
}
