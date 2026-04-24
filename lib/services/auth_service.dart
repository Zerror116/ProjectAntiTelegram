// ignore_for_file: avoid_print

// lib/services/auth_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../src/utils/device_utils.dart';
import 'notification_coordinator_service.dart';
import 'notification_runtime_preference_service.dart';

class User {
  final String id;
  final String email;
  final String? name;
  final String role;
  final String? phone;
  final String? phoneAccessState;
  final String? tenantId;
  final String? tenantCode;
  final String? tenantName;
  final String? tenantStatus;
  final String? subscriptionExpiresAt;
  final Map<String, dynamic> permissions;

  User({
    required this.id,
    required this.email,
    this.name,
    required this.role,
    this.phone,
    this.phoneAccessState,
    this.tenantId,
    this.tenantCode,
    this.tenantName,
    this.tenantStatus,
    this.subscriptionExpiresAt,
    this.permissions = const <String, dynamic>{},
  });

  factory User.fromMap(Map<String, dynamic> m) {
    return User(
      id: m['id']?.toString() ?? '',
      email: m['email']?.toString() ?? '',
      name: m['name']?.toString(),
      role: m['role']?.toString() ?? 'client',
      phone: m['phone']?.toString(),
      phoneAccessState: (() {
        final raw = (m['phone_access_state'] ?? m['phoneAccessState'] ?? '')
            .toString()
            .trim();
        return raw.isEmpty ? null : raw;
      })(),
      tenantId: (() {
        final raw = (m['tenant_id'] ?? m['tenantId'] ?? '').toString().trim();
        return raw.isEmpty ? null : raw;
      })(),
      tenantCode: (() {
        final raw = (m['tenant_code'] ?? m['tenantCode'] ?? '')
            .toString()
            .trim();
        return raw.isEmpty ? null : raw;
      })(),
      tenantName: (() {
        final raw = (m['tenant_name'] ?? m['tenantName'] ?? '')
            .toString()
            .trim();
        return raw.isEmpty ? null : raw;
      })(),
      tenantStatus: (() {
        final raw = (m['tenant_status'] ?? m['tenantStatus'] ?? '')
            .toString()
            .trim();
        return raw.isEmpty ? null : raw;
      })(),
      subscriptionExpiresAt: (() {
        final raw =
            (m['subscription_expires_at'] ?? m['subscriptionExpiresAt'] ?? '')
                .toString()
                .trim();
        return raw.isEmpty ? null : raw;
      })(),
      permissions: (() {
        final raw = m['permissions'];
        if (raw is Map<String, dynamic>) return raw;
        if (raw is Map) return Map<String, dynamic>.from(raw);
        return const <String, dynamic>{};
      })(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'role': role,
      'phone': phone,
      'phone_access_state': phoneAccessState,
      'tenant_id': tenantId,
      'tenant_code': tenantCode,
      'tenant_name': tenantName,
      'tenant_status': tenantStatus,
      'subscription_expires_at': subscriptionExpiresAt,
      'permissions': permissions,
    };
  }
}

class AuthService {
  final Dio dio;
  static const bool _verboseAuthLogs = bool.fromEnvironment(
    'FENIX_VERBOSE_AUTH_LOGS',
    defaultValue: false,
  );
  static const _tokenKey = 'auth_token';
  static const _legacyJwtKey = 'jwt';
  static const _refreshTokenKey = 'auth_refresh_token';
  static const _accessExpiresAtKey = 'auth_access_expires_at';
  static const _sessionExpiresAtKey = 'auth_session_expires_at';
  static const _authNoticeKey = 'auth_notice_message';
  static const _viewRoleKey = 'creator_view_role';
  static const _tenantCodeKey = 'tenant_code_scope';
  static const _creatorTenantScopeKey = 'creator_tenant_scope_code_v1';
  static const _savedSessionsKey = 'saved_tenant_sessions_v1';
  static const _userSnapshotKey = 'auth_user_snapshot_v1';

  // Temporary storage for multi-step registration
  String? pendingEmail;
  String? pendingPassword;
  String? pendingAccessKey;
  String? pendingRegistrationEmailToken;

  // Current authenticated user (populated after login / profile fetch)
  User? _currentUser;
  String? _cachedToken;
  bool _lastStartupRefreshUsedFallback = false;
  User? get currentUser => _currentUser;
  bool get lastStartupRefreshUsedFallback => _lastStartupRefreshUsedFallback;
  String? _viewRole;
  String? get viewRole => _viewRole;
  String get effectiveRole {
    final base = (_currentUser?.role ?? 'client').toLowerCase().trim();
    if (base == 'creator' && _viewRole != null && _viewRole!.isNotEmpty) {
      return _viewRole!;
    }
    return base;
  }

  bool hasPermission(String key) {
    final user = _currentUser;
    if (user == null) return false;
    final role = user.role.toLowerCase().trim();
    if (role == 'creator' && (_viewRole == null || _viewRole == 'creator')) {
      return true;
    }
    if (effectiveRole.toLowerCase().trim() == 'tenant') {
      return true;
    }
    final perms = user.permissions;
    if (perms['all'] == true) return true;
    if (perms[key] == true) return true;

    final parts = key.split('.').where((e) => e.isNotEmpty).toList();
    for (var i = parts.length - 1; i > 0; i--) {
      final wildcard = '${parts.sublist(0, i).join('.')}.*';
      if (perms[wildcard] == true) return true;
    }
    return false;
  }

  // Stream controller to notify listeners about auth changes (user or logout)
  final StreamController<User?> _authController =
      StreamController<User?>.broadcast();
  Stream<User?> get authStream => _authController.stream;

  // Prevent re-entrant or duplicate logout/clear operations
  bool _isLoggingOut = false;
  String? _deviceFingerprintCache;
  String? _tenantCodeCache;
  String? _creatorTenantScopeCache;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  Completer<bool>? _sessionRefreshCompleter;
  bool _preferSharedPrefsSecretStore = false;
  bool _loggedSharedPrefsSecretFallback = false;
  bool _postAuthSyncInProgress = false;
  bool _sessionDegraded = false;
  String? _sessionDegradedReason;

  bool get isSessionDegraded => _sessionDegraded;
  String? get sessionDegradedReason => _sessionDegradedReason;

  String _normalizeTenantCodeScope(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return '';
    return normalized.replaceAll(RegExp(r'\s+'), '');
  }

  AuthService({required this.dio});

  bool _isDesktopPlatform() {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  void _setSessionDegraded(bool value, {String? reason}) {
    if (_sessionDegraded == value &&
        (!value || (_sessionDegradedReason ?? '') == (reason ?? ''))) {
      return;
    }
    _sessionDegraded = value;
    _sessionDegradedReason = value ? (reason ?? 'unknown') : null;
    if (value) {
      debugPrint(
        '⚠️ Auth session switched to degraded mode: $_sessionDegradedReason',
      );
    } else {
      debugPrint('✅ Auth session restored to normal mode');
    }
  }

  bool _isTransientNetworkOrServerError(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return status >= 500 || status == 408;
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.badResponse:
        return false;
    }
  }

  bool _shouldFallbackToSharedPrefsSecretStore(Object error) {
    if (!_isDesktopPlatform()) return false;
    if (error is! PlatformException) return false;
    final code = error.code.trim();
    final message = (error.message ?? '').toLowerCase().trim();
    return code == '-34018' ||
        message.contains('required entitlement') ||
        message.contains('security result code') ||
        message.contains('keychain');
  }

  void _enableSharedPrefsSecretStoreFallback(Object error) {
    _preferSharedPrefsSecretStore = true;
    if (_loggedSharedPrefsSecretFallback) return;
    _loggedSharedPrefsSecretFallback = true;
    debugPrint(
      '⚠️ Secure storage unavailable on this desktop build, '
      'falling back to local preferences: $error',
    );
  }

  Future<void> _writeSharedSecret(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<String?> _readSharedSecret(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> _removeSharedSecret(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<void> _writeSecret(String key, String value) async {
    if (kIsWeb || _preferSharedPrefsSecretStore) {
      await _writeSharedSecret(key, value);
      return;
    }
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (error) {
      if (_shouldFallbackToSharedPrefsSecretStore(error)) {
        _enableSharedPrefsSecretStoreFallback(error);
        await _writeSharedSecret(key, value);
        return;
      }
      rethrow;
    }
  }

  Future<String?> _readSecret(String key) async {
    if (kIsWeb || _preferSharedPrefsSecretStore) {
      return _readSharedSecret(key);
    }
    try {
      return await _secureStorage.read(key: key);
    } catch (error) {
      if (_shouldFallbackToSharedPrefsSecretStore(error)) {
        _enableSharedPrefsSecretStoreFallback(error);
        return _readSharedSecret(key);
      }
      rethrow;
    }
  }

  Future<void> _removeSecret(String key) async {
    if (kIsWeb || _preferSharedPrefsSecretStore) {
      await _removeSharedSecret(key);
      return;
    }
    try {
      await _secureStorage.delete(key: key);
    } catch (error) {
      if (_shouldFallbackToSharedPrefsSecretStore(error)) {
        _enableSharedPrefsSecretStoreFallback(error);
        await _removeSharedSecret(key);
        return;
      }
      rethrow;
    }
  }

  Future<String?> _readLegacyStoredToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy =
          prefs.getString(_tokenKey) ?? prefs.getString(_legacyJwtKey);
      final normalized = legacy?.trim();
      if (normalized == null || normalized.isEmpty) return null;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupLegacyStoredTokenCopies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyJwtKey);
      if (!kIsWeb && !_preferSharedPrefsSecretStore) {
        await prefs.remove(_tokenKey);
      }
    } catch (_) {}
  }

  DateTime? _parseStoredDateTime(String? raw) {
    final normalized = (raw ?? '').trim();
    if (normalized.isEmpty) return null;
    return DateTime.tryParse(normalized)?.toUtc();
  }

  String? _encodeStoredDateTime(DateTime? value) {
    if (value == null) return null;
    return value.toUtc().toIso8601String();
  }

  Future<void> setPendingAuthNotice(String? value) async {
    final normalized = (value ?? '').trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(_authNoticeKey);
      return;
    }
    await prefs.setString(_authNoticeKey, normalized);
  }

  Future<String?> consumePendingAuthNotice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_authNoticeKey)?.trim() ?? '';
      if (raw.isEmpty) return null;
      await prefs.remove(_authNoticeKey);
      return raw;
    } catch (_) {
      return null;
    }
  }

  DateTime? _accessExpiryFromToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      var normalized = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      final padLength = (4 - (normalized.length % 4)) % 4;
      normalized = normalized.padRight(normalized.length + padLength, '=');
      final json = utf8.decode(base64Decode(normalized));
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final expRaw = decoded['exp'];
      final exp = expRaw is int
          ? expRaw
          : int.tryParse(expRaw?.toString() ?? '');
      if (exp == null || exp <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  bool _isExpired(
    DateTime? value, {
    Duration skew = const Duration(seconds: 30),
  }) {
    if (value == null) return false;
    return value.isBefore(DateTime.now().toUtc().add(skew));
  }

  void _schedulePostAuthSync() {
    if (_postAuthSyncInProgress) return;
    _postAuthSyncInProgress = true;
    unawaited(() async {
      try {
        final enabled =
            await NotificationRuntimePreferenceService.isEnabledForUser(
              _currentUser?.id,
            );
        if (!enabled) {
          await NotificationCoordinatorService.clear(dio);
          return;
        }
        await NotificationRuntimePreferenceService.refreshServerPolicy(
          dio,
          userId: _currentUser?.id,
        );
        await NotificationCoordinatorService.reconcile(dio, enabled: enabled);
      } finally {
        _postAuthSyncInProgress = false;
      }
    }());
  }

  void _authVerboseLog(String message) {
    if (kDebugMode && _verboseAuthLogs) {
      debugPrint(message);
    }
  }

  String _sessionIdFor(String email, String? tenantCode) {
    final mail = email.trim().toLowerCase();
    final tenant = (tenantCode ?? '').trim().toLowerCase();
    return '$mail::$tenant';
  }

  Future<List<Map<String, dynamic>>> listSavedTenantSessions() async {
    try {
      final raw = await _readSecret(_savedSessionsKey);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final data = decoded
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) {
            final token = (row['token'] ?? '').toString().trim();
            final email = (row['email'] ?? '').toString().trim();
            return token.isNotEmpty && email.isNotEmpty;
          })
          .toList();
      data.sort((a, b) {
        final aa = (a['updated_at'] ?? '').toString();
        final bb = (b['updated_at'] ?? '').toString();
        return bb.compareTo(aa);
      });
      return data;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _upsertSavedSession(String token, User? user) async {
    if (token.trim().isEmpty || user == null) return;
    if (user.email.trim().isEmpty) return;

    final sessions = await listSavedTenantSessions();
    final id = _sessionIdFor(user.email, user.tenantCode);
    final refreshToken = (await getRefreshToken())?.trim() ?? '';
    final accessExpiresAt = _encodeStoredDateTime(await getAccessTokenExpiry());
    final sessionExpiresAt = _encodeStoredDateTime(await getSessionExpiry());
    final next = <String, dynamic>{
      'id': id,
      'token': token,
      'refresh_token': refreshToken,
      'access_expires_at': accessExpiresAt,
      'session_expires_at': sessionExpiresAt,
      'email': user.email,
      'name': user.name ?? '',
      'role': user.role,
      'tenant_code': user.tenantCode ?? '',
      'tenant_name': user.tenantName ?? '',
      'updated_at': DateTime.now().toIso8601String(),
    };

    final updated = <Map<String, dynamic>>[
      next,
      ...sessions.where((row) => (row['id'] ?? '').toString() != id),
    ];

    try {
      await _writeSecret(_savedSessionsKey, jsonEncode(updated));
    } catch (_) {}
  }

  Future<void> removeSavedTenantSession(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return;
    final sessions = await listSavedTenantSessions();
    final updated = sessions
        .where((row) => (row['id'] ?? '').toString() != id)
        .toList();
    try {
      await _writeSecret(_savedSessionsKey, jsonEncode(updated));
    } catch (_) {}
  }

  Future<bool> switchToSavedTenantSession(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return false;
    final sessions = await listSavedTenantSessions();
    final found = sessions.firstWhere(
      (row) => (row['id'] ?? '').toString() == id,
      orElse: () => const <String, dynamic>{},
    );
    if (found.isEmpty) return false;

    final token = (found['token'] ?? '').toString().trim();
    final refreshToken = (found['refresh_token'] ?? '').toString().trim();
    final accessExpiresAt = _parseStoredDateTime(
      (found['access_expires_at'] ?? '').toString(),
    );
    final sessionExpiresAt = _parseStoredDateTime(
      (found['session_expires_at'] ?? '').toString(),
    );
    if (token.isEmpty) return false;

    try {
      await setSessionTokens(
        accessToken: token,
        refreshToken: refreshToken.isEmpty ? null : refreshToken,
        accessExpiresAt: accessExpiresAt,
        sessionExpiresAt: sessionExpiresAt,
      );
      final refreshed = await ensureFreshSession(
        allowBootstrap: true,
        forceRefreshIfExpired: true,
      );
      if (!refreshed) {
        await removeSavedTenantSession(id);
        return false;
      }
      final resp = await dio.get('/api/profile');
      if (resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['user'] is Map) {
        _currentUser = User.fromMap(
          Map<String, dynamic>.from(resp.data['user']),
        );
        try {
          final prefs = await SharedPreferences.getInstance();
          if (_currentUser?.role.toLowerCase().trim() == 'creator') {
            _viewRole = prefs.getString(_viewRoleKey);
          } else {
            _viewRole = null;
            await prefs.remove(_viewRoleKey);
          }
        } catch (_) {}
        try {
          _authController.add(_currentUser);
        } catch (_) {}
        final latestToken = await getToken();
        if (latestToken != null && latestToken.trim().isNotEmpty) {
          await _upsertSavedSession(latestToken, _currentUser);
        }
        return true;
      }
      await removeSavedTenantSession(id);
      return false;
    } catch (_) {
      await removeSavedTenantSession(id);
      return false;
    }
  }

  String _shortToken(String token) {
    if (token.isEmpty) return '';
    final n = token.length < 20 ? token.length : 20;
    return token.substring(0, n);
  }

  /// Приватный: установить/удалить заголовок Authorization
  void _setAuthHeader(String? token) {
    if (token != null && token.isNotEmpty) {
      dio.options.headers['Authorization'] = 'Bearer $token';
      debugPrint('✅ Auth header set with token');
    } else {
      dio.options.headers.remove('Authorization');
      debugPrint('❌ Auth header removed');
    }
  }

  Future<void> _saveToken(String token) async {
    try {
      _cachedToken = token;
      await _writeSecret(_tokenKey, token);
      await _cleanupLegacyStoredTokenCopies();
      debugPrint('✅ Access token stored: ${_shortToken(token)}...');
    } catch (e) {
      debugPrint('❌ Error saving access token: $e');
    }
  }

  Future<void> _saveRefreshToken(String token) async {
    try {
      await _writeSecret(_refreshTokenKey, token);
    } catch (e) {
      debugPrint('❌ Error saving refresh token: $e');
    }
  }

  Future<void> _saveExpiry(String key, DateTime? value) async {
    final encoded = _encodeStoredDateTime(value);
    if (encoded == null || encoded.isEmpty) {
      await _removeSecret(key);
      return;
    }
    await _writeSecret(key, encoded);
  }

  Future<DateTime?> _readExpiry(String key) async {
    final raw = await _readSecret(key);
    return _parseStoredDateTime(raw);
  }

  Future<String?> getRefreshToken() async {
    try {
      final token = await _readSecret(_refreshTokenKey);
      final normalized = token?.trim();
      if (normalized == null || normalized.isEmpty) return null;
      return normalized;
    } catch (e) {
      debugPrint('❌ Error getting refresh token: $e');
      return null;
    }
  }

  Future<DateTime?> getAccessTokenExpiry() async {
    return _readExpiry(_accessExpiresAtKey);
  }

  Future<DateTime?> getSessionExpiry() async {
    return _readExpiry(_sessionExpiresAtKey);
  }

  Future<void> setSessionTokens({
    required String accessToken,
    String? refreshToken,
    DateTime? accessExpiresAt,
    DateTime? sessionExpiresAt,
    User? user,
    bool keepExistingRefreshToken = true,
  }) async {
    debugPrint(
      '🔐 setSessionTokens called with token: ${_shortToken(accessToken)}..., user: ${user?.email}',
    );
    _cachedToken = accessToken;
    _setSessionDegraded(false);
    await _saveToken(accessToken);
    if (refreshToken != null && refreshToken.trim().isNotEmpty) {
      await _saveRefreshToken(refreshToken.trim());
    } else if (!keepExistingRefreshToken) {
      await _removeSecret(_refreshTokenKey);
    }
    await _saveExpiry(
      _accessExpiresAtKey,
      accessExpiresAt ?? _accessExpiryFromToken(accessToken),
    );
    await _saveExpiry(_sessionExpiresAtKey, sessionExpiresAt);
    _setAuthHeader(accessToken);
    if (user != null) _currentUser = user;
    await _saveUserSnapshot(_currentUser);
    final responseTenantCode = (user?.tenantCode ?? '').trim();
    if ((_currentUser?.role.toLowerCase().trim() ?? '') == 'creator') {
      if (responseTenantCode.isNotEmpty) {
        _creatorTenantScopeCache = _normalizeTenantCodeScope(
          responseTenantCode,
        );
      }
    } else if (responseTenantCode.isNotEmpty) {
      await setTenantCode(responseTenantCode);
    }
    await _upsertSavedSession(accessToken, _currentUser);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_currentUser?.role.toLowerCase().trim() == 'creator') {
        _viewRole = prefs.getString(_viewRoleKey);
        await _restoreCreatorTenantScopeFromStorage(
          prefs,
          patchCurrentUser: true,
        );
      } else {
        _viewRole = null;
        await prefs.remove(_viewRoleKey);
        _creatorTenantScopeCache = null;
        await prefs.remove(_creatorTenantScopeKey);
      }
    } catch (_) {}
    try {
      _authController.add(_currentUser);
    } catch (_) {}
    _schedulePostAuthSync();
    debugPrint(
      '✅ AuthService.setSessionTokens -> token set, user=${_currentUser?.email}',
    );
  }

  /// Публичный: установить access token и (опционально) user, уведомить слушателей
  Future<void> setToken(String token, [User? user]) async {
    await setSessionTokens(accessToken: token, user: user);
  }

  /// Публичный: очистить токен и user (logout)
  Future<void> clearToken() async {
    debugPrint('🗑️ clearToken called');
    if (_isLoggingOut) {
      debugPrint('⚠️ clearToken already in progress, skipping');
      return;
    }
    _isLoggingOut = true;
    try {
      await NotificationCoordinatorService.clear(dio);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_viewRoleKey);
      await prefs.remove(_userSnapshotKey);
      await prefs.remove(_creatorTenantScopeKey);
      await _removeSecret(_tokenKey);
      await _removeSecret(_refreshTokenKey);
      await _removeSecret(_accessExpiresAtKey);
      await _removeSecret(_sessionExpiresAtKey);
      await _cleanupLegacyStoredTokenCopies();
      _cachedToken = null;
      _setSessionDegraded(false);
      _sessionRefreshCompleter = null;
      debugPrint('✅ Auth secrets removed');

      _setAuthHeader(null);
      pendingEmail = null;
      pendingPassword = null;
      pendingAccessKey = null;
      pendingRegistrationEmailToken = null;
      _currentUser = null;
      _viewRole = null;
      _creatorTenantScopeCache = null;

      try {
        _authController.add(null);
      } catch (_) {}
      debugPrint('✅ AuthService.clearToken -> logged out');
    } finally {
      _isLoggingOut = false;
    }
  }

  Future<void> _saveUserSnapshot(User? user) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (user == null) {
        await prefs.remove(_userSnapshotKey);
        return;
      }
      await prefs.setString(_userSnapshotKey, jsonEncode(user.toMap()));
    } catch (e) {
      debugPrint('⚠️ Error saving auth user snapshot: $e');
    }
  }

  Future<User?> _readStoredUserSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_userSnapshotKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final email = (map['email'] ?? '').toString().trim();
      if (email.isEmpty) return null;
      return User.fromMap(map);
    } catch (e) {
      debugPrint('⚠️ Error reading auth user snapshot: $e');
      return null;
    }
  }

  Future<bool> _restoreLocalSessionFallback({String? token}) async {
    try {
      _currentUser ??= await _readStoredUserSnapshot();
      final candidateToken = token ?? await getToken();
      if (_currentUser == null &&
          candidateToken != null &&
          candidateToken.trim().isNotEmpty) {
        _currentUser = _decodeUserFromTokenUnsafe(candidateToken);
      }
      if (_currentUser == null) return false;

      final prefs = await SharedPreferences.getInstance();
      if (_currentUser?.role.toLowerCase().trim() == 'creator') {
        _viewRole = prefs.getString(_viewRoleKey);
        await _restoreCreatorTenantScopeFromStorage(
          prefs,
          patchCurrentUser: true,
        );
      } else {
        _viewRole = null;
        _creatorTenantScopeCache = null;
      }
      try {
        _authController.add(_currentUser);
      } catch (_) {}
      debugPrint(
        '⚠️ Restored local auth session without fresh server confirmation: ${_currentUser?.email}',
      );
      return true;
    } catch (e) {
      debugPrint('⚠️ Failed to restore local auth session: $e');
      return false;
    }
  }

  User? _decodeUserFromTokenUnsafe(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      var normalized = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      final padLength = (4 - (normalized.length % 4)) % 4;
      normalized = normalized.padRight(normalized.length + padLength, '=');
      final json = utf8.decode(base64Decode(normalized));
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final userId = (map['id'] ?? map['userId'] ?? map['sub'] ?? '')
          .toString()
          .trim();
      final email = (map['email'] ?? '').toString().trim();
      final role = (map['role'] ?? 'client').toString().trim();
      if (userId.isEmpty || email.isEmpty) return null;
      return User.fromMap({
        'id': userId,
        'email': email,
        'role': role.isEmpty ? 'client' : role,
        'tenant_id': map['tenant_id'],
        'tenant_code': map['tenant_code'] ?? map['tenantCode'],
      });
    } catch (e) {
      debugPrint('⚠️ Error decoding auth token payload: $e');
      return null;
    }
  }

  /// Получение токена из SharedPreferences
  Future<String?> getToken() async {
    try {
      if (_cachedToken != null && _cachedToken!.trim().isNotEmpty) {
        return _cachedToken;
      }
      var token = await _readSecret(_tokenKey);
      token = token?.trim();
      if (token == null || token.isEmpty) {
        final legacy = await _readLegacyStoredToken();
        if (legacy != null && legacy.isNotEmpty) {
          token = legacy;
          await _saveToken(legacy);
        }
      }
      _cachedToken = token;
      _authVerboseLog(
        '🔑 getToken -> ${token != null ? '${_shortToken(token)}...' : 'null'}',
      );
      return token;
    } catch (e) {
      debugPrint('❌ Error getting token: $e');
      return null;
    }
  }

  Future<bool> primeAuthHeaderFromStoredToken() async {
    try {
      final token = await getToken();
      if (token == null || token.trim().isEmpty) {
        _setAuthHeader(null);
        return false;
      }
      _setAuthHeader(token);
      if (_currentUser == null) {
        _currentUser = await _readStoredUserSnapshot();
        _currentUser ??= _decodeUserFromTokenUnsafe(token);
        if (_currentUser != null) {
          final prefs = await SharedPreferences.getInstance();
          if (_currentUser?.role.toLowerCase().trim() == 'creator') {
            _viewRole = prefs.getString(_viewRoleKey);
            await _restoreCreatorTenantScopeFromStorage(
              prefs,
              patchCurrentUser: true,
            );
          }
        }
      }
      return true;
    } catch (e) {
      debugPrint('❌ Error priming auth header from storage: $e');
      _setAuthHeader(null);
      return false;
    }
  }

  Future<void> setTenantCode(String? tenantCode) async {
    final normalized = _normalizeTenantCodeScope(tenantCode);
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      _tenantCodeCache = null;
      await prefs.remove(_tenantCodeKey);
      return;
    }
    _tenantCodeCache = normalized;
    await prefs.setString(_tenantCodeKey, normalized);
  }

  Future<String?> getTenantCode() async {
    if (_tenantCodeCache != null && _tenantCodeCache!.trim().isNotEmpty) {
      return _tenantCodeCache;
    }
    final prefs = await SharedPreferences.getInstance();
    final storedRaw = prefs.getString(_tenantCodeKey)?.trim() ?? '';
    final stored = _normalizeTenantCodeScope(storedRaw);
    if (stored.isEmpty) {
      if (storedRaw.isNotEmpty) {
        await prefs.remove(_tenantCodeKey);
      }
      return null;
    }
    if (stored != storedRaw) {
      await prefs.setString(_tenantCodeKey, stored);
    }
    _tenantCodeCache = stored;
    return _tenantCodeCache;
  }

  bool get canSelectCreatorTenantScope =>
      _currentUser?.role.toLowerCase().trim() == 'creator';

  String? get creatorTenantScopeCode =>
      (_creatorTenantScopeCache?.trim().isNotEmpty ?? false)
      ? _creatorTenantScopeCache?.trim()
      : (() {
          final fallback = _normalizeTenantCodeScope(_currentUser?.tenantCode);
          return fallback.isEmpty ? null : fallback;
        })();

  User? _withCreatorTenantScope(
    User? user, {
    String? tenantCode,
    String? tenantName,
    String? tenantStatus,
    String? tenantId,
    String? subscriptionExpiresAt,
  }) {
    if (user == null) return null;
    if (user.role.toLowerCase().trim() != 'creator') return user;
    final normalizedCode = _normalizeTenantCodeScope(tenantCode);
    return User(
      id: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      phone: user.phone,
      phoneAccessState: user.phoneAccessState,
      tenantCode: normalizedCode.isEmpty ? null : normalizedCode,
      tenantName: (tenantName ?? '').trim().isEmpty ? null : tenantName?.trim(),
      tenantStatus: (tenantStatus ?? '').trim().isEmpty
          ? null
          : tenantStatus?.trim(),
      subscriptionExpiresAt: (subscriptionExpiresAt ?? '').trim().isEmpty
          ? null
          : subscriptionExpiresAt?.trim(),
      permissions: user.permissions,
    );
  }

  Future<void> _restoreCreatorTenantScopeFromStorage(
    SharedPreferences prefs, {
    bool patchCurrentUser = false,
  }) async {
    final storedRaw = prefs.getString(_creatorTenantScopeKey)?.trim() ?? '';
    final stored = _normalizeTenantCodeScope(storedRaw);
    if (stored.isEmpty) {
      final fallback = _normalizeTenantCodeScope(_currentUser?.tenantCode);
      _creatorTenantScopeCache = fallback.isEmpty ? null : fallback;
      if (storedRaw.isNotEmpty) {
        await prefs.remove(_creatorTenantScopeKey);
      }
      if (patchCurrentUser &&
          _currentUser?.role.toLowerCase().trim() == 'creator') {
        _currentUser = _withCreatorTenantScope(
          _currentUser,
          tenantCode: _creatorTenantScopeCache,
          tenantName: _currentUser?.tenantName,
          tenantStatus: _currentUser?.tenantStatus,
          subscriptionExpiresAt: _currentUser?.subscriptionExpiresAt,
        );
      }
      if (_creatorTenantScopeCache != null) {
        await prefs.setString(
          _creatorTenantScopeKey,
          _creatorTenantScopeCache!,
        );
      }
      return;
    }
    if (stored != storedRaw) {
      await prefs.setString(_creatorTenantScopeKey, stored);
    }
    _creatorTenantScopeCache = stored;
    if (patchCurrentUser &&
        _currentUser?.role.toLowerCase().trim() == 'creator') {
      _currentUser = _withCreatorTenantScope(
        _currentUser,
        tenantCode: stored,
        tenantName: _currentUser?.tenantName,
        tenantStatus: _currentUser?.tenantStatus,
        subscriptionExpiresAt: _currentUser?.subscriptionExpiresAt,
      );
    }
  }

  Future<void> setCreatorTenantScope(
    String? tenantCode, {
    String? tenantId,
    String? tenantName,
    String? tenantStatus,
    String? subscriptionExpiresAt,
  }) async {
    if (!canSelectCreatorTenantScope) return;
    final normalized = _normalizeTenantCodeScope(tenantCode);
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      _creatorTenantScopeCache = null;
      await prefs.remove(_creatorTenantScopeKey);
      _currentUser = _withCreatorTenantScope(_currentUser);
    } else {
      _creatorTenantScopeCache = normalized;
      await prefs.setString(_creatorTenantScopeKey, normalized);
      _currentUser = _withCreatorTenantScope(
        _currentUser,
        tenantCode: normalized,
        tenantId: tenantId,
        tenantName: tenantName,
        tenantStatus: tenantStatus,
        subscriptionExpiresAt: subscriptionExpiresAt,
      );
    }
    await _saveUserSnapshot(_currentUser);
    try {
      _authController.add(_currentUser);
    } catch (_) {}
  }

  Future<String?> getCreatorTenantScopeCode() async {
    if (!canSelectCreatorTenantScope && _currentUser != null) {
      return null;
    }
    if (_creatorTenantScopeCache != null &&
        _creatorTenantScopeCache!.trim().isNotEmpty) {
      return _creatorTenantScopeCache;
    }
    final prefs = await SharedPreferences.getInstance();
    await _restoreCreatorTenantScopeFromStorage(prefs, patchCurrentUser: true);
    final fallback = _normalizeTenantCodeScope(_currentUser?.tenantCode);
    if ((_creatorTenantScopeCache ?? '').trim().isEmpty &&
        fallback.isNotEmpty) {
      _creatorTenantScopeCache = fallback;
      await prefs.setString(_creatorTenantScopeKey, fallback);
    }
    return (_creatorTenantScopeCache ?? '').trim().isEmpty
        ? null
        : _creatorTenantScopeCache;
  }

  /// Обработать ответ от /auth (вытянуть токены и user), использовать setSessionTokens
  Future<void> _processAuthResponse(Response resp) async {
    debugPrint('📝 _processAuthResponse: status=${resp.statusCode}');
    // ✅ ИСПРАВЛЕНИЕ: Cast правильно
    final data = (resp.data as Map<dynamic, dynamic>).cast<String, dynamic>();
    final token = data['token'] ?? data['access'];
    final refreshToken = (data['refresh_token'] ?? '').toString().trim();
    final accessExpiresAt = _parseStoredDateTime(
      (data['access_expires_at'] ?? '').toString(),
    );
    final sessionExpiresAt = _parseStoredDateTime(
      (data['session_expires_at'] ?? '').toString(),
    );
    Map<String, dynamic>? userMap;
    if (data['user'] is Map) {
      userMap = Map<String, dynamic>.from(data['user']);
    }
    String? tenantNameFromResponse;
    final tenant = data['tenant'];
    if (tenant is Map && tenant['name'] != null) {
      final raw = tenant['name'].toString().trim();
      tenantNameFromResponse = raw.isEmpty ? null : raw;
    }
    String? tenantStatusFromResponse;
    if (tenant is Map && tenant['status'] != null) {
      final raw = tenant['status'].toString().trim();
      tenantStatusFromResponse = raw.isEmpty ? null : raw;
    }
    String? subscriptionExpiresAtFromResponse;
    if (tenant is Map && tenant['subscription_expires_at'] != null) {
      final raw = tenant['subscription_expires_at'].toString().trim();
      subscriptionExpiresAtFromResponse = raw.isEmpty ? null : raw;
    }
    if (userMap != null &&
        tenantNameFromResponse != null &&
        (userMap['tenant_name'] ?? '').toString().trim().isEmpty) {
      userMap['tenant_name'] = tenantNameFromResponse;
    }
    if (userMap != null &&
        tenantStatusFromResponse != null &&
        (userMap['tenant_status'] ?? '').toString().trim().isEmpty) {
      userMap['tenant_status'] = tenantStatusFromResponse;
    }
    if (userMap != null &&
        subscriptionExpiresAtFromResponse != null &&
        (userMap['subscription_expires_at'] ?? '').toString().trim().isEmpty) {
      userMap['subscription_expires_at'] = subscriptionExpiresAtFromResponse;
    }

    if (token == null) throw Exception('No token in response');
    final tokenStr = token.toString();

    debugPrint('🔐 Token extracted: ${_shortToken(tokenStr)}...');

    if (userMap != null) {
      _currentUser = _hydrateUserFromMap(userMap);
      if (_currentUser?.role.toLowerCase().trim() == 'creator') {
        final scopedCode = await getCreatorTenantScopeCode();
        if ((scopedCode ?? '').isNotEmpty) {
          _currentUser = _withCreatorTenantScope(
            _currentUser,
            tenantCode: userMap['tenant_code']?.toString() ?? scopedCode,
            tenantId: userMap['tenant_id']?.toString(),
            tenantName: userMap['tenant_name']?.toString(),
            tenantStatus: userMap['tenant_status']?.toString(),
            subscriptionExpiresAt: userMap['subscription_expires_at']
                ?.toString(),
          );
        }
      }
      debugPrint('👤 User extracted: ${_currentUser?.email}');
    } else {
      // Попробуем подтянуть профиль, если сервер не вернул user
      try {
        debugPrint('📡 Fetching profile...');
        final profileResp = await dio.get('/api/profile');
        if (profileResp.statusCode == 200 &&
            profileResp.data is Map &&
            profileResp.data['user'] is Map) {
          final profileMap = (profileResp.data['user'] as Map<dynamic, dynamic>)
              .cast<String, dynamic>();
          _currentUser = _hydrateUserFromMap(profileMap);
          debugPrint('👤 Profile fetched: ${_currentUser?.email}');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to fetch profile: $e');
      }
    }

    String? tenantCodeFromResponse;
    if (tenant is Map && tenant['code'] != null) {
      tenantCodeFromResponse = tenant['code'].toString().trim();
    }
    tenantCodeFromResponse ??= _currentUser?.tenantCode;
    if ((_currentUser?.role.toLowerCase().trim() ?? '') == 'creator') {
      if ((tenantCodeFromResponse ?? '').isNotEmpty) {
        await setCreatorTenantScope(
          tenantCodeFromResponse,
          tenantName: _currentUser?.tenantName,
          tenantStatus: _currentUser?.tenantStatus,
          subscriptionExpiresAt: _currentUser?.subscriptionExpiresAt,
        );
      }
    } else if ((tenantCodeFromResponse ?? '').isNotEmpty) {
      await setTenantCode(tenantCodeFromResponse);
    }

    await setSessionTokens(
      accessToken: tokenStr,
      refreshToken: refreshToken.isEmpty ? null : refreshToken,
      accessExpiresAt: accessExpiresAt,
      sessionExpiresAt: sessionExpiresAt,
      user: _currentUser,
    );
    debugPrint('✅ _processAuthResponse complete');
  }

  Future<String?> _getDeviceFingerprintSafe() async {
    if (_deviceFingerprintCache != null &&
        _deviceFingerprintCache!.isNotEmpty) {
      return _deviceFingerprintCache;
    }
    try {
      final fingerprint = await generateDeviceFingerprint();
      final normalized = fingerprint.trim();
      if (normalized.isEmpty) return null;
      _deviceFingerprintCache = normalized;
      return normalized;
    } catch (e) {
      debugPrint('⚠️ Failed to generate device fingerprint: $e');
      return null;
    }
  }

  Future<String?> getDeviceFingerprintForRequest() async {
    return await _getDeviceFingerprintSafe();
  }

  /// Вход
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? accessKey,
    String? otpCode,
    bool trustDevice = false,
  }) async {
    debugPrint('🔓 login called with email: $email');
    final fingerprint = await _getDeviceFingerprintSafe();
    String? tenantCode = await getTenantCode();
    if (tenantCode == null || tenantCode.trim().isEmpty) {
      final targetEmail = email.trim().toLowerCase();
      final sessions = await listSavedTenantSessions();
      for (final row in sessions) {
        final rowEmail = (row['email'] ?? '').toString().trim().toLowerCase();
        if (rowEmail != targetEmail) continue;
        final rememberedTenant = _normalizeTenantCodeScope(
          (row['tenant_code'] ?? '').toString(),
        );
        if (rememberedTenant.isEmpty) continue;
        tenantCode = rememberedTenant;
        await setTenantCode(rememberedTenant);
        break;
      }
    }
    final resp = await dio.post(
      '/api/auth/login',
      data: {
        'email': email,
        'password': password,
        if (accessKey != null && accessKey.trim().isNotEmpty)
          'access_key': accessKey.trim(),
        if (otpCode != null && otpCode.trim().isNotEmpty)
          'otp_code': otpCode.trim(),
        if (tenantCode != null && tenantCode.trim().isNotEmpty)
          'tenant_code': tenantCode.trim(),
        'device_fingerprint': fingerprint,
        if (trustDevice) 'trust_device': true,
      },
    );
    debugPrint('📬 login response received, status: ${resp.statusCode}');

    await _processAuthResponse(resp);

    pendingEmail = null;
    pendingPassword = null;
    pendingAccessKey = null;
    pendingRegistrationEmailToken = null;
    debugPrint('✅ login complete');
    return {
      'access': resp.data['token'] ?? resp.data['access'],
      'user': _currentUser?.toMap(),
    };
  }

  Future<Map<String, dynamic>> getTwoFactorStatus() async {
    final resp = await dio.get('/api/auth/2fa/status');
    final data = resp.data;
    if (data is Map && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data']);
    }
    return const <String, dynamic>{};
  }

  Future<Map<String, dynamic>> startTwoFactorSetup() async {
    final resp = await dio.post('/api/auth/2fa/setup/start');
    final data = resp.data;
    if (data is Map && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data']);
    }
    throw Exception('Сервер не вернул данные для настройки 2FA');
  }

  Future<Map<String, dynamic>> confirmTwoFactorSetup({
    required String secret,
    required String code,
  }) async {
    final resp = await dio.post(
      '/api/auth/2fa/setup/confirm',
      data: {'secret': secret.trim(), 'code': code.trim()},
    );
    final data = resp.data;
    if (data is Map && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data']);
    }
    return const <String, dynamic>{};
  }

  Future<void> disableTwoFactor({
    required String password,
    required String code,
  }) async {
    await dio.post(
      '/api/auth/2fa/disable',
      data: {'password': password, 'code': code.trim()},
    );
  }

  Future<Map<String, dynamic>> regenerateTwoFactorBackupCodes({
    required String password,
    required String code,
  }) async {
    final resp = await dio.post(
      '/api/auth/2fa/backup-codes/regenerate',
      data: {'password': password, 'code': code.trim()},
    );
    final data = resp.data;
    if (data is Map && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data']);
    }
    return const <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> listTrustedTwoFactorDevices() async {
    final resp = await dio.get('/api/auth/2fa/trusted-devices');
    final data = resp.data;
    if (data is Map && data['data'] is List) {
      return data['data']
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return const [];
  }

  Future<void> revokeTrustedTwoFactorDevice(String id) async {
    await dio.delete('/api/auth/2fa/trusted-devices/$id');
  }

  Future<int> revokeAllTrustedTwoFactorDevices() async {
    final resp = await dio.post('/api/auth/2fa/trusted-devices/revoke_all');
    final data = resp.data;
    if (data is Map && data['data'] is Map) {
      final revoked = data['data']['revoked'];
      return int.tryParse('$revoked') ?? 0;
    }
    return 0;
  }

  /// Регистрация (полная: email+password+name+phone + optional secret)
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String? name,
    String? phone,
    String? accessKey,
    String? secret, // для special creator email
  }) async {
    debugPrint('✍️ register called with email: $email');
    final fingerprint = await _getDeviceFingerprintSafe();
    final tenantCode = await getTenantCode();
    final resp = await dio.post(
      '/api/auth/register',
      data: {
        'email': email,
        'password': password,
        if (accessKey != null && accessKey.trim().isNotEmpty)
          'access_key': accessKey.trim(),
        if (tenantCode != null && tenantCode.trim().isNotEmpty)
          'tenant_code': tenantCode.trim(),
        'name': name,
        'phone': phone,
        'secret': secret,
        'device_fingerprint': fingerprint,
      },
    );
    debugPrint('📬 register response received, status: ${resp.statusCode}');

    await _processAuthResponse(resp);

    pendingEmail = null;
    pendingPassword = null;
    pendingAccessKey = null;
    pendingRegistrationEmailToken = null;
    debugPrint('✅ register complete');
    return {
      'access': resp.data['token'] ?? resp.data['access'],
      'user': _currentUser?.toMap(),
    };
  }

  /// Устанавливаем временные данные при первом шаге регистрации
  void setPendingCredentials({
    required String email,
    required String password,
    String? accessKey,
    String? registrationEmailToken,
  }) {
    pendingEmail = email;
    pendingPassword = password;
    pendingAccessKey = accessKey?.trim();
    pendingRegistrationEmailToken = registrationEmailToken?.trim();
    debugPrint('📋 AuthService.setPendingCredentials -> email saved');
  }

  /// Завершение регистрации: используем pendingEmail/pendingPassword + name + phone + optional secret
  Future<void> completePendingRegistration({
    required String name,
    required String phone,
    String? secret,
  }) async {
    if (pendingEmail == null || pendingPassword == null) {
      throw Exception('No pending credentials');
    }
    final fingerprint = await _getDeviceFingerprintSafe();
    final tenantCode = await getTenantCode();
    final resp = await dio.post(
      '/api/auth/register',
      data: {
        'email': pendingEmail,
        'password': pendingPassword,
        if (pendingAccessKey != null && pendingAccessKey!.trim().isNotEmpty)
          'access_key': pendingAccessKey!.trim(),
        if (tenantCode != null && tenantCode.trim().isNotEmpty)
          'tenant_code': tenantCode.trim(),
        'name': name,
        'phone': phone,
        'secret': secret,
        'device_fingerprint': fingerprint,
        if (pendingRegistrationEmailToken != null &&
            pendingRegistrationEmailToken!.trim().isNotEmpty)
          'registration_email_token': pendingRegistrationEmailToken!.trim(),
      },
    );

    await _processAuthResponse(resp);
    pendingEmail = null;
    pendingPassword = null;
    pendingAccessKey = null;
    pendingRegistrationEmailToken = null;
  }

  bool hasAnyRole(List<String> roles) =>
      _currentUser != null && roles.contains(_currentUser!.role);

  bool get canSwitchViewRole =>
      _currentUser?.role.toLowerCase().trim() == 'creator';

  Future<void> setViewRole(String? role) async {
    if (!canSwitchViewRole) return;
    final normalized = role?.toLowerCase().trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalized == null || normalized.isEmpty || normalized == 'creator') {
        _viewRole = null;
        await prefs.remove(_viewRoleKey);
      } else {
        _viewRole = normalized;
        await prefs.setString(_viewRoleKey, normalized);
      }
    } catch (e) {
      // Do not crash UI if storage is temporarily unavailable on web.
      debugPrint('setViewRole storage error: $e');
      if (normalized == null || normalized.isEmpty || normalized == 'creator') {
        _viewRole = null;
      } else {
        _viewRole = normalized;
      }
    }
    try {
      _authController.add(_currentUser);
    } catch (_) {}
  }

  /// Применить ответ логина/регистрации (если вызывается извне)
  Future<void> applyLoginResponse(
    String token,
    Map<String, dynamic>? userMap,
  ) async {
    debugPrint('🔐 applyLoginResponse called');
    User? user;
    if (userMap != null) user = _hydrateUserFromMap(userMap);
    await setToken(token, user);
  }

  User _hydrateUserFromMap(Map<String, dynamic> userMap) {
    final merged = Map<String, dynamic>.from(userMap);
    final current = _currentUser;
    if (current != null) {
      final nextName = (merged['name'] ?? '').toString().trim();
      if (nextName.isEmpty && (current.name ?? '').trim().isNotEmpty) {
        merged['name'] = current.name;
      }
      final nextPhone = (merged['phone'] ?? '').toString().trim();
      if (nextPhone.isEmpty && (current.phone ?? '').trim().isNotEmpty) {
        merged['phone'] = current.phone;
      }
      final nextPhoneAccessState =
          (merged['phone_access_state'] ?? merged['phoneAccessState'] ?? '')
              .toString()
              .trim();
      if (nextPhoneAccessState.isEmpty &&
          (current.phoneAccessState ?? '').trim().isNotEmpty) {
        merged['phone_access_state'] = current.phoneAccessState;
      }
      final nextPermissions = merged['permissions'];
      if ((nextPermissions is! Map || nextPermissions.isEmpty) &&
          current.permissions.isNotEmpty) {
        merged['permissions'] = current.permissions;
      }
    }

    var user = User.fromMap(merged);
    if (user.role.toLowerCase().trim() == 'creator') {
      final scopedCode = _normalizeTenantCodeScope(
        merged['tenant_code'] ?? merged['tenantCode'] ?? creatorTenantScopeCode,
      );
      if (scopedCode.isNotEmpty) {
        user =
            _withCreatorTenantScope(
              user,
              tenantCode: scopedCode,
              tenantName:
                  (merged['tenant_name'] ??
                          merged['tenantName'] ??
                          user.tenantName)
                      ?.toString(),
              tenantStatus:
                  (merged['tenant_status'] ??
                          merged['tenantStatus'] ??
                          user.tenantStatus)
                      ?.toString(),
              subscriptionExpiresAt:
                  (merged['subscription_expires_at'] ??
                          merged['subscriptionExpiresAt'] ??
                          user.subscriptionExpiresAt)
                      ?.toString(),
            ) ??
            user;
      }
    }
    return user;
  }

  void updateCurrentUserFromMap(Map<String, dynamic> userMap) {
    _currentUser = _hydrateUserFromMap(userMap);
    unawaited(_saveUserSnapshot(_currentUser));
  }

  Future<bool> _bootstrapLegacySession() async {
    final token = await getToken();
    if (token == null || token.trim().isEmpty) return false;
    final accessExpiry =
        await getAccessTokenExpiry() ?? _accessExpiryFromToken(token);
    if (_isExpired(accessExpiry)) {
      return false;
    }
    try {
      final resp = await dio.post(
        '/api/auth/refresh/bootstrap',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (resp.statusCode == 200) {
        await _processAuthResponse(resp);
        return true;
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return false;
      }
      debugPrint('⚠️ bootstrap legacy session skipped: $e');
      return false;
    } catch (e) {
      debugPrint('⚠️ bootstrap legacy session error: $e');
      return false;
    }
    return false;
  }

  Future<bool> refreshSession({bool allowBootstrap = false}) async {
    if (_sessionRefreshCompleter != null) {
      return _sessionRefreshCompleter!.future;
    }
    final completer = Completer<bool>();
    _sessionRefreshCompleter = completer;
    try {
      final sessionExpiry = await getSessionExpiry();
      if (_isExpired(sessionExpiry, skew: Duration.zero)) {
        await setPendingAuthNotice(
          'Срок входа истек, пожалуйста, войдите снова',
        );
        await clearToken();
        completer.complete(false);
        return false;
      }

      final refreshToken = await getRefreshToken();
      if (refreshToken == null || refreshToken.trim().isEmpty) {
        if (allowBootstrap) {
          final bootstrapped = await _bootstrapLegacySession();
          completer.complete(bootstrapped);
          return bootstrapped;
        }
        completer.complete(false);
        return false;
      }

      try {
        final resp = await dio.post(
          '/api/auth/refresh',
          data: {'refresh_token': refreshToken},
          options: Options(
            sendTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
        if (resp.statusCode == 200) {
          await _processAuthResponse(resp);
          completer.complete(true);
          return true;
        }
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (allowBootstrap && (status == 400 || status == 401)) {
          final bootstrapped = await _bootstrapLegacySession();
          if (bootstrapped) {
            completer.complete(true);
            return true;
          }
        }
        if (status == 401) {
          await setPendingAuthNotice(
            'Срок входа истек, пожалуйста, войдите снова',
          );
          await clearToken();
          completer.complete(false);
          return false;
        }
        if (_isTransientNetworkOrServerError(e)) {
          _setSessionDegraded(true, reason: 'refresh_session_transient_error');
        }
        debugPrint('⚠️ refreshSession warning: $e');
        completer.complete(false);
        return false;
      }

      completer.complete(false);
      return false;
    } catch (e) {
      debugPrint('⚠️ refreshSession error: $e');
      completer.complete(false);
      return false;
    } finally {
      if (identical(_sessionRefreshCompleter, completer)) {
        _sessionRefreshCompleter = null;
      }
    }
  }

  Future<bool> ensureFreshSession({
    bool allowBootstrap = true,
    bool forceRefreshIfExpired = false,
  }) async {
    final token = await getToken();
    if (token == null || token.trim().isEmpty) return false;

    final sessionExpiry = await getSessionExpiry();
    if (_isExpired(sessionExpiry, skew: Duration.zero)) {
      await setPendingAuthNotice('Срок входа истек, пожалуйста, войдите снова');
      await clearToken();
      return false;
    }

    final accessExpiry =
        await getAccessTokenExpiry() ?? _accessExpiryFromToken(token);
    if (accessExpiry != null) {
      await _saveExpiry(_accessExpiresAtKey, accessExpiry);
    }
    final needsRefresh =
        _isExpired(accessExpiry, skew: const Duration(minutes: 2)) ||
        (forceRefreshIfExpired && _isExpired(accessExpiry));

    if (!needsRefresh) {
      final refreshToken = await getRefreshToken();
      if ((refreshToken == null || refreshToken.trim().isEmpty) &&
          allowBootstrap) {
        unawaited(_bootstrapLegacySession());
      }
      return true;
    }

    return refreshSession(allowBootstrap: allowBootstrap);
  }

  /// Попытка обновить токен при старте (восстановить сессию)
  Future<bool> tryRefreshOnStartup() async {
    String? token;
    try {
      _lastStartupRefreshUsedFallback = false;
      debugPrint('🔄 tryRefreshOnStartup called');
      token = await getToken();
      if (token == null || token.isEmpty) {
        debugPrint('❌ No token in storage');
        return false;
      }

      debugPrint('✅ Token found in storage, setting auth header');
      _setAuthHeader(token);
      await _restoreLocalSessionFallback(token: token);
      final sessionReady = await ensureFreshSession(
        allowBootstrap: true,
        forceRefreshIfExpired: true,
      );
      if (!sessionReady) {
        final latestToken = await getToken();
        if (latestToken == null || latestToken.trim().isEmpty) {
          _lastStartupRefreshUsedFallback = false;
          return false;
        }
        final restored = await _restoreLocalSessionFallback(token: latestToken);
        _lastStartupRefreshUsedFallback = restored;
        _setSessionDegraded(restored, reason: 'startup_refresh_unconfirmed');
        return restored;
      }
      token = await getToken();
      if (token != null && token.trim().isNotEmpty) {
        _setAuthHeader(token);
      }

      // Проверяем, валиден ли токен, запрашивая профиль
      Response<dynamic> resp = await dio.get(
        '/api/profile',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      debugPrint('📡 Profile check: status=${resp.statusCode}');

      if (resp.statusCode == 401) {
        final refreshed = await refreshSession(allowBootstrap: true);
        if (!refreshed) {
          await clearToken();
          return false;
        }
        resp = await dio.get(
          '/api/profile',
          options: Options(
            sendTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
      }

      if (resp.statusCode == 200 && resp.data is Map) {
        final user = resp.data['user'];
        if (user is Map) {
          // ✅ ИСПРАВЛЕНИЕ: Cast правильно
          final userMap = Map<String, dynamic>.from(user);
          _currentUser = _hydrateUserFromMap(userMap);
          final prefs = await SharedPreferences.getInstance();
          _viewRole = prefs.getString(_viewRoleKey);
          await _saveUserSnapshot(_currentUser);
          try {
            _authController.add(_currentUser);
          } catch (_) {}
          _schedulePostAuthSync();
          _setSessionDegraded(false);
          _lastStartupRefreshUsedFallback = false;
          debugPrint(
            '✅ tryRefreshOnStartup -> user restored: ${_currentUser?.email}',
          );
          return true;
        }
      }
      return false;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // Временная недоступность сервера не должна выбрасывать пользователя из сессии.
      // Очищаем токен только если сервер явно вернул auth-ошибку.
      if (status == 401) {
        debugPrint('❌ tryRefreshOnStartup auth error: $e');
        _lastStartupRefreshUsedFallback = false;
        await clearToken();
        return false;
      }
      if (_isTransientNetworkOrServerError(e)) {
        _setSessionDegraded(true, reason: 'startup_refresh_transient_error');
      } else {
        _setSessionDegraded(false);
      }
      final restored = await _restoreLocalSessionFallback(token: token);
      _lastStartupRefreshUsedFallback = restored;
      if (restored) {
        debugPrint(
          '⚠️ tryRefreshOnStartup dio warning, using local session fallback: $e',
        );
      } else {
        debugPrint('❌ tryRefreshOnStartup dio error: $e');
      }
      return restored;
    } catch (e) {
      _setSessionDegraded(true, reason: 'startup_refresh_runtime_error');
      final restored = await _restoreLocalSessionFallback(token: token);
      _lastStartupRefreshUsedFallback = restored;
      if (restored) {
        debugPrint(
          '⚠️ tryRefreshOnStartup warning, using local session fallback: $e',
        );
      } else {
        debugPrint('❌ tryRefreshOnStartup error: $e');
      }
      return restored;
    }
  }

  /// Логаут
  Future<void> logout() async {
    try {
      debugPrint('🚪 AuthService.logout -> starting logout');
      try {
        await dio.post('/api/auth/logout');
        debugPrint('✅ Logout API call succeeded');
      } catch (e) {
        debugPrint('⚠️ logout API call failed (ignoring): $e');
      }

      // И очищаем токен локально
      await clearToken();

      debugPrint('✅ AuthService.logout -> logout complete');
    } catch (e) {
      debugPrint('❌ logout error: $e');
      await clearToken();
    }
  }

  /// Закрыть контроллер при завершении
  void dispose() {
    try {
      _authController.close();
    } catch (_) {}
  }

  // -------------------------
  // Совместимость с существующим кодом (обёртки)
  // -------------------------

  /// Старые вызовы в проекте могли использовать `saveToken` — оставляем обёртку.
  Future<void> saveToken(String token) async {
    await setToken(token);
  }

  /// Старые вызовы могли использовать `setAuthHeaderFromStorage` — оставляем обёртку.
  Future<void> setAuthHeaderFromStorage() async {
    await tryRefreshOnStartup();
  }
}
