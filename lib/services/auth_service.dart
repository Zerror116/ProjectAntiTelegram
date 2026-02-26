// lib/services/auth_service.dart
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

class User {
  final String id;
  final String email;
  final String? name;
  final String role;
  final String? phone;

  User({
    required this.id,
    required this.email,
    this.name,
    required this.role,
    this.phone,
  });

  factory User.fromMap(Map<String, dynamic> m) {
    return User(
      id: m['id']?.toString() ?? '',
      email: m['email']?.toString() ?? '',
      name: m['name']?.toString(),
      role: m['role']?.toString() ?? 'client',
      phone: m['phone']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'role': role,
      'phone': phone,
    };
  }
}

class AuthService {
  final Dio dio;
  static const _tokenKey = 'auth_token';

  // Temporary storage for multi-step registration
  String? pendingEmail;
  String? pendingPassword;

  // Current authenticated user (populated after login / profile fetch)
  User? _currentUser;
  User? get currentUser => _currentUser;

  // Stream controller to notify listeners about auth changes (user or logout)
  final StreamController<User?> _authController = StreamController<User?>.broadcast();
  Stream<User?> get authStream => _authController.stream;

  // Prevent re-entrant or duplicate logout/clear operations
  bool _isLoggingOut = false;

  AuthService({required this.dio});

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
    debugPrint('🔐 setToken called with token: ${token.substring(0, 20)}..., user: ${user?.email}');
    await _saveToken(token);
    _setAuthHeader(token);
    if (user != null) _currentUser = user;
    try {
      _authController.add(_currentUser);
    } catch (_) {}
    debugPrint('✅ AuthService.setToken -> token set, user=${_currentUser?.email}');
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      debugPrint('✅ Token removed from SharedPreferences');

      _setAuthHeader(null);
      pendingEmail = null;
      pendingPassword = null;
      _currentUser = null;

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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      debugPrint('✅ Token saved to SharedPreferences: ${token.substring(0, 20)}...');
    } catch (e) {
      debugPrint('❌ Error saving token: $e');
    }
  }

  /// Получение токена из SharedPreferences
  Future<String?> getToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      debugPrint('🔑 getToken -> ${token != null ? '${token.substring(0, 20)}...' : 'null'}');
      return token;
    } catch (e) {
      debugPrint('❌ Error getting token: $e');
      return null;
    }
  }

  /// Обработать ответ от /auth (вытянуть токен и user), использовать setToken
  Future<void> _processAuthResponse(Response resp) async {
    debugPrint('📝 _processAuthResponse: status=${resp.statusCode}');
    // ✅ ИСПРАВЛЕНИЕ: Cast правильно
    final data = (resp.data as Map<dynamic, dynamic>).cast<String, dynamic>();
    final token = data['token'] ?? data['access'];
    final userMap = data['user'] as Map<String, dynamic>?;

    if (token == null) throw Exception('No token in response');

    debugPrint('🔐 Token extracted: ${(token as String).substring(0, 20)}...');

    if (userMap != null) {
      _currentUser = User.fromMap(userMap);
      debugPrint('👤 User extracted: ${_currentUser?.email}');
    } else {
      // Попробуем подтянуть профиль, если сервер не вернул user
      try {
        debugPrint('📡 Fetching profile...');
        final profileResp = await dio.get('/api/profile');
        if (profileResp.statusCode == 200 && profileResp.data is Map && profileResp.data['user'] is Map) {
          final profileMap = (profileResp.data['user'] as Map<dynamic, dynamic>).cast<String, dynamic>();
          _currentUser = User.fromMap(profileMap);
          debugPrint('👤 Profile fetched: ${_currentUser?.email}');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to fetch profile: $e');
      }
    }

    // ✅ Сохраняем токен ПЕРЕД установкой заголовка
    await setToken(token as String, _currentUser);
    debugPrint('✅ _processAuthResponse complete');
  }

  /// Вход
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    debugPrint('🔓 login called with email: $email');
    final resp = await dio.post('/api/auth/login', data: {'email': email, 'password': password});
    debugPrint('📬 login response received, status: ${resp.statusCode}');

    await _processAuthResponse(resp);

    pendingEmail = null;
    pendingPassword = null;
    debugPrint('✅ login complete');
    return {'access': resp.data['token'] ?? resp.data['access'], 'user': _currentUser?.toMap()};
  }

  /// Регистрация (полная: email+password+name+phone + optional secret)
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String? name,
    String? phone,
    String? secret, // для special creator email
  }) async {
    debugPrint('✍️ register called with email: $email');
    final resp = await dio.post('/api/auth/register', data: {
      'email': email,
      'password': password,
      if (name != null) 'name': name,
      if (phone != null) 'phone': phone,
      if (secret != null) 'secret': secret,
    });
    debugPrint('📬 register response received, status: ${resp.statusCode}');

    await _processAuthResponse(resp);

    pendingEmail = null;
    pendingPassword = null;
    debugPrint('✅ register complete');
    return {'access': resp.data['token'] ?? resp.data['access'], 'user': _currentUser?.toMap()};
  }

  /// Устанавливаем временные данные при первом шаге регистрации
  void setPendingCredentials({required String email, required String password}) {
    pendingEmail = email;
    pendingPassword = password;
    debugPrint('📋 AuthService.setPendingCredentials -> email saved');
  }

  /// Завершение регистрации: используем pendingEmail/pendingPassword + name + phone + optional secret
  Future<void> completePendingRegistration({required String name, required String phone, String? secret}) async {
    if (pendingEmail == null || pendingPassword == null) {
      throw Exception('No pending credentials');
    }
    final resp = await dio.post('/api/auth/register', data: {
      'email': pendingEmail,
      'password': pendingPassword,
      'name': name,
      'phone': phone,
      if (secret != null) 'secret': secret,
    });

    await _processAuthResponse(resp);
    pendingEmail = null;
    pendingPassword = null;
  }

  bool hasAnyRole(List<String> roles) => _currentUser != null && roles.contains(_currentUser!.role);

  /// Применить ответ логина/регистрации (если вызывается извне)
  Future<void> applyLoginResponse(String token, Map<String, dynamic>? userMap) async {
    debugPrint('🔐 applyLoginResponse called');
    User? user;
    if (userMap != null) user = User.fromMap(userMap);
    await setToken(token, user);
  }

  /// Попытка обновить токен при старте (восстановить сессию)
  Future<bool> tryRefreshOnStartup() async {
    try {
      debugPrint('🔄 tryRefreshOnStartup called');
      final token = await getToken();
      if (token == null || token.isEmpty) {
        debugPrint('❌ No token in storage');
        return false;
      }

      debugPrint('✅ Token found in storage, setting auth header');
      _setAuthHeader(token);

      // Проверяем, валиден ли токен, запрашивая профиль
      final resp = await dio.get('/api/profile');
      debugPrint('📡 Profile check: status=${resp.statusCode}');

      if (resp.statusCode == 200 && resp.data is Map) {
        final user = resp.data['user'];
        if (user is Map) {
          // ✅ ИСПРАВЛЕНИЕ: Cast правильно
          final userMap = (user as Map<dynamic, dynamic>).cast<String, dynamic>();
          _currentUser = User.fromMap(userMap);
          try {
            _authController.add(_currentUser);
          } catch (_) {}
          debugPrint('✅ tryRefreshOnStartup -> user restored: ${_currentUser?.email}');
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('❌ tryRefreshOnStartup error: $e');
      await clearToken();
      return false;
    }
  }

  /// Логаут
  Future<void> logout() async {
    try {
      debugPrint('🚪 AuthService.logout -> starting logout');

      // ✅ ИСПРАВЛЕНИЕ: Уведомляем слушателей ПЕРЕД logout
      _currentUser = null;
      try {
        _authController.add(null);
        debugPrint('📢 authStream notified about logout');
      } catch (_) {}

      // Потом выполняем логаут на сервере
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
      rethrow;
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