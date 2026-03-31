// ignore_for_file: avoid_print

// lib/services/auth_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import '../src/utils/device_utils.dart';
import 'web_notification_service.dart';
import 'web_push_client_service.dart';

class User {
  final String id;
  final String email;
  final String? name;
  final String role;
  final String? phone;
  final String? phoneAccessState;
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
  static const _viewRoleKey = 'creator_view_role';
  static const _tenantCodeKey = 'tenant_code_scope';
  static const _savedSessionsKey = 'saved_tenant_sessions_v1';
  static const _userSnapshotKey = 'auth_user_snapshot_v1';

  // Temporary storage for multi-step registration
  String? pendingEmail;
  String? pendingPassword;
  String? pendingAccessKey;

  // Current authenticated user (populated after login / profile fetch)
  User? _currentUser;
  String? _cachedToken;
  User? get currentUser => _currentUser;
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

  String _normalizeTenantCodeScope(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return '';
    return normalized.replaceAll(RegExp(r'\s+'), '');
  }

  AuthService({required this.dio});

  Future<void> _maybeEnsureWebPushSubscription() async {
    if (!kIsWeb) return;
    try {
      final permission = await WebNotificationService.getPermissionState();
      print('[web-push] auth hook permission=$permission user=${_currentUser?.email ?? ''}');
      if (permission != WebNotificationPermissionState.granted) return;
      await WebPushClientService.ensureSubscribed(dio);
      await WebPushClientService.syncUnreadBadge(dio);
    } catch (e) {
      print('[web-push] auth hook error: $e');
      _authVerboseLog('⚠️ Web push sync skipped: $e');
    }
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
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_savedSessionsKey);
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
    final next = <String, dynamic>{
      'id': id,
      'token': token,
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedSessionsKey, jsonEncode(updated));
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedSessionsKey, jsonEncode(updated));
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
    if (token.isEmpty) return false;

    try {
      await setToken(token);
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
        await _upsertSavedSession(token, _currentUser);
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

  /// Публичный: установить токен и (опционально) user, уведомить слушателей
  Future<void> setToken(String token, [User? user]) async {
    debugPrint(
      '🔐 setToken called with token: ${_shortToken(token)}..., user: ${user?.email}',
    );
    _cachedToken = token;
    await _saveToken(token);
    _setAuthHeader(token);
    if (user != null) _currentUser = user;
    await _saveUserSnapshot(_currentUser);
    final responseTenantCode = (user?.tenantCode ?? '').trim();
    if (responseTenantCode.isNotEmpty) {
      await setTenantCode(responseTenantCode);
    }
    await _upsertSavedSession(token, _currentUser);
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
    await _maybeEnsureWebPushSubscription();
    debugPrint(
      '✅ AuthService.setToken -> token set, user=${_currentUser?.email}',
    );
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
      try {
        if (kIsWeb) {
          await WebPushClientService.unsubscribe(dio);
        }
      } catch (_) {}
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      await prefs.remove(_viewRoleKey);
      await prefs.remove(_userSnapshotKey);
      _cachedToken = null;
      debugPrint('✅ Token removed from SharedPreferences');

      _setAuthHeader(null);
      pendingEmail = null;
      pendingPassword = null;
      pendingAccessKey = null;
      _currentUser = null;
      _viewRole = null;

      try {
        _authController.add(null);
      } catch (_) {}
      debugPrint('✅ AuthService.clearToken -> logged out');
    } finally {
      _isLoggingOut = false;
    }
  }

  /// Приватный: сохранить токен в SharedPreferences
  Future<void> _saveToken(String token) async {
    try {
      _cachedToken = token;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      debugPrint(
        '✅ Token saved to SharedPreferences: ${_shortToken(token)}...',
      );
    } catch (e) {
      debugPrint('❌ Error saving token: $e');
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
      } else {
        _viewRole = null;
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
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
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

  /// Обработать ответ от /auth (вытянуть токен и user), использовать setToken
  Future<void> _processAuthResponse(Response resp) async {
    debugPrint('📝 _processAuthResponse: status=${resp.statusCode}');
    // ✅ ИСПРАВЛЕНИЕ: Cast правильно
    final data = (resp.data as Map<dynamic, dynamic>).cast<String, dynamic>();
    final token = data['token'] ?? data['access'];
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
      _currentUser = User.fromMap(userMap);
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
          _currentUser = User.fromMap(profileMap);
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
    if ((tenantCodeFromResponse ?? '').isNotEmpty) {
      await setTenantCode(tenantCodeFromResponse);
    }

    // ✅ Сохраняем токен ПЕРЕД установкой заголовка
    await setToken(tokenStr, _currentUser);
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
  }) {
    pendingEmail = email;
    pendingPassword = password;
    pendingAccessKey = accessKey?.trim();
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
      },
    );

    await _processAuthResponse(resp);
    pendingEmail = null;
    pendingPassword = null;
    pendingAccessKey = null;
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
    if (userMap != null) user = User.fromMap(userMap);
    await setToken(token, user);
  }

  void updateCurrentUserFromMap(Map<String, dynamic> userMap) {
    _currentUser = User.fromMap(userMap);
    unawaited(_saveUserSnapshot(_currentUser));
  }

  /// Попытка обновить токен при старте (восстановить сессию)
  Future<bool> tryRefreshOnStartup() async {
    String? token;
    try {
      debugPrint('🔄 tryRefreshOnStartup called');
      token = await getToken();
      if (token == null || token.isEmpty) {
        debugPrint('❌ No token in storage');
        return false;
      }

      debugPrint('✅ Token found in storage, setting auth header');
      _setAuthHeader(token);
      await _restoreLocalSessionFallback(token: token);

      // Проверяем, валиден ли токен, запрашивая профиль
      final resp = await dio.get(
        '/api/profile',
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      debugPrint('📡 Profile check: status=${resp.statusCode}');

      if (resp.statusCode == 200 && resp.data is Map) {
        final user = resp.data['user'];
        if (user is Map) {
          // ✅ ИСПРАВЛЕНИЕ: Cast правильно
          final userMap = Map<String, dynamic>.from(user);
          _currentUser = User.fromMap(userMap);
          final prefs = await SharedPreferences.getInstance();
          _viewRole = prefs.getString(_viewRoleKey);
          await _saveUserSnapshot(_currentUser);
          try {
            _authController.add(_currentUser);
          } catch (_) {}
          await _maybeEnsureWebPushSubscription();
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
      if (status == 401 || status == 403) {
        debugPrint('❌ tryRefreshOnStartup auth error: $e');
        await clearToken();
        return false;
      }
      final restored = await _restoreLocalSessionFallback(token: token);
      if (restored) {
        debugPrint(
          '⚠️ tryRefreshOnStartup dio warning, using local session fallback: $e',
        );
      } else {
        debugPrint('❌ tryRefreshOnStartup dio error: $e');
      }
      return restored;
    } catch (e) {
      final restored = await _restoreLocalSessionFallback(token: token);
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
