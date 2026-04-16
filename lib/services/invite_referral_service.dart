import 'package:shared_preferences/shared_preferences.dart';

class PendingInviteReferral {
  const PendingInviteReferral({
    required this.referrerUserId,
    required this.referrerName,
    required this.inviteCode,
    required this.tenantCode,
    required this.capturedAt,
  });

  final String referrerUserId;
  final String referrerName;
  final String inviteCode;
  final String tenantCode;
  final DateTime capturedAt;

  bool get isEmpty =>
      referrerUserId.trim().isEmpty && referrerName.trim().isEmpty;
}

class InviteReferralService {
  static const _referrerKey = 'phoenix_pending_invite_referrer_id_v1';
  static const _referrerNameKey = 'phoenix_pending_invite_referrer_name_v1';
  static const _inviteKey = 'phoenix_pending_invite_code_v1';
  static const _tenantKey = 'phoenix_pending_invite_tenant_v1';
  static const _capturedAtKey = 'phoenix_pending_invite_captured_at_v1';

  const InviteReferralService();

  String _queryValue(Uri uri, List<String> keys) {
    for (final key in keys) {
      final direct = (uri.queryParameters[key] ?? '').trim();
      if (direct.isNotEmpty) return direct;
    }
    if (uri.fragment.isNotEmpty) {
      final fragment = uri.fragment;
      final qIndex = fragment.indexOf('?');
      if (qIndex >= 0 && qIndex + 1 < fragment.length) {
        final nested = Uri.splitQueryString(fragment.substring(qIndex + 1));
        for (final key in keys) {
          final value = (nested[key] ?? '').trim();
          if (value.isNotEmpty) return value;
        }
      }
    }
    return '';
  }

  Future<void> captureFromUri(Uri uri) async {
    final inviteCode = _queryValue(uri, const ['invite', 'code']);
    final referrerUserId = _queryValue(uri, const ['referrer', 'referrer_id']);
    final referrerName = _queryValue(uri, const ['referrer_name']);
    final tenantCode = _queryValue(uri, const ['tenant', 'tenant_code']);
    if (inviteCode.isEmpty ||
        (referrerUserId.isEmpty && referrerName.isEmpty)) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_inviteKey, inviteCode);
    await prefs.setString(_tenantKey, tenantCode);
    await prefs.setString(_referrerKey, referrerUserId);
    await prefs.setString(_referrerNameKey, referrerName);
    await prefs.setString(
      _capturedAtKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<PendingInviteReferral?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final inviteCode = (prefs.getString(_inviteKey) ?? '').trim();
    final referrerUserId = (prefs.getString(_referrerKey) ?? '').trim();
    final referrerName = (prefs.getString(_referrerNameKey) ?? '').trim();
    final tenantCode = (prefs.getString(_tenantKey) ?? '').trim();
    if (inviteCode.isEmpty ||
        (referrerUserId.isEmpty && referrerName.isEmpty)) {
      return null;
    }
    final capturedAtRaw = (prefs.getString(_capturedAtKey) ?? '').trim();
    final capturedAt = DateTime.tryParse(capturedAtRaw)?.toLocal() ??
        DateTime.now();
    return PendingInviteReferral(
      referrerUserId: referrerUserId,
      referrerName: referrerName,
      inviteCode: inviteCode,
      tenantCode: tenantCode,
      capturedAt: capturedAt,
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_inviteKey);
    await prefs.remove(_tenantKey);
    await prefs.remove(_referrerKey);
    await prefs.remove(_referrerNameKey);
    await prefs.remove(_capturedAtKey);
  }
}

const inviteReferralService = InviteReferralService();
