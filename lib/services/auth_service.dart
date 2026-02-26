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
    } else {
      dio.options.headers.remove('Authorization');
    }
  }

  /// Публичный: установить токен и (опционально) user, уведомить слушателей
  Future<void> setToken(String token, [User? user]) async {
    await _saveToken(token);
    _setAuthHeader(token);
    if (user != null) _currentUser = user;
    try {
      _authController.add(_currentUser);
    } catch (_) {}
    debugPrint('AuthService.setToken -> token set, user=${_currentUser?.email}');
  }

  /// Публичный: очистить токен и user (logout)
  Future<void> clearToken() async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      _setAuthHeader(null);
      pendingEmail = null;
      pendingPassword = null;
      _currentUser = null;
      try {
        _authController.add(null);
      } catch (_) {}
      debugPrint('AuthService.clearToken -> logged out');
    } finally {
      _isLoggingOut = false;
    }
  }

  /// Приватный: сохранить токен в SharedPreferences
  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  /// Получение токена из SharedPreferences
  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    debugPrint('AuthService.getToken -> $token');
    return token;
  }

  /// Обработать ответ от /auth (вытянуть токен и user), использовать setToken
  Future<void> _processAuthResponse(Response resp) async {
    final data = resp.data as Map<String, dynamic>;
    final token = data['token'] ?? data['access'];
    final userMap = data['user'] as Map<String, dynamic>?;
    if (token == null) throw Exception('No token in response');
    if (userMap != null) {
      _currentUser = User.fromMap(Map<String, dynamic>.from(userMap));
    } else {
      // Попробуем подтянуть профиль, если сервер не вернул user
      try {
        final profileResp = await dio.get('/api/profile');
        if (profileResp.statusCode == 200 && profileResp.data is Map && profileResp.data['user'] is Map) {
          _currentUser = User.fromMap(Map<String, dynamic>.from(profileResp.data['user']));
        }
      } catch (_) {
        // ignore
      }
    }
    await setToken(token as String, _currentUser);
  }

  /// Вход
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final resp = await dio.post('/api/auth/login', data: {'email': email, 'password': password});
    await _processAuthResponse(resp);
    pendingEmail = null;
    pendingPassword = null;
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
    final resp = await dio.post('/api/auth/register', data: {
      'email': email,
      'password': password,
      if (name != null) 'name': name,
      if (phone != null) 'phone': phone,
      if (secret != null) 'secret': secret,
    });
    await _processAuthResponse(resp);
    pendingEmail = null;
    pendingPassword = null;
    return {'access': resp.data['token'] ?? resp.data['access'], 'user': _currentUser?.toMap()};
  }

  /// Устанавливаем временные данные при первом шаге регистрации
  void setPendingCredentials({required String email, required String password}) {
    pendingEmail = email;
    pendingPassword = password;
    debugPrint('AuthService.setPendingCredentials -> email saved');
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
    final data = resp.data as Map<String, dynamic>?;
    final token = data != null ? (data['token'] ?? data['access']) : null;
    if (token == null) {
      throw Exception('Registration failed: token not returned');
    }
    // Обновляем currentUser и сохраняем токен
    await _processAuthResponse(resp);
    pendingEmail = null;
    pendingPassword = null;
  }

  /// Попытка автоматического входа при старте приложения.
  /// Устанавливает заголовок и проверяет /api/profile.
  Future<bool> tryRefreshOnStartup() async {
    final token = await getToken();
    if (token == null) return false;
    try {
      _setAuthHeader(token);
      final resp = await dio.get('/api/profile');
      if (resp.statusCode == 200 && resp.data is Map && resp.data['user'] is Map) {
        _currentUser = User.fromMap(Map<String, dynamic>.from(resp.data['user']));
        // уведомляем слушателей, что пользователь восстановлен
        try { _authController.add(_currentUser); } catch (_) {}
        debugPrint('AuthService.tryRefreshOnStartup -> user restored: ${_currentUser?.email}');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('tryRefreshOnStartup failed: $e');
      await clearToken();
      return false;
    }
  }

  /// Отправка номера телефона на сервер.
  Future<Map<String, dynamic>> submitPhone(String phone) async {
    final token = await getToken();
    if (token != null) {
      dio.options.headers['Authorization'] = 'Bearer $token';
    } else {
      throw Exception('No auth token available');
    }
    final resp = await dio.post('/api/phones/request', data: {'phone': phone});
    return resp.data as Map<String, dynamic>;
  }

  /// Подтверждение кода телефона (заглушка)
  Future<Map<String, dynamic>> verifyPhoneCode(String code) async {
    final token = await getToken();
    if (token != null) dio.options.headers['Authorization'] = 'Bearer $token';
    final resp = await dio.post('/api/phones/admin/verify', data: {'code': code});
    return resp.data as Map<String, dynamic>;
  }

  /// Утилиты по ролям
  bool hasRole(String role) => _currentUser?.role == role;
  bool hasAnyRole(List<String> roles) => _currentUser != null && roles.contains(_currentUser!.role);

  /// Применить ответ логина/регистрации (если вызывается извне)
  Future<void> applyLoginResponse(String token, Map<String, dynamic>? userMap) async {
    User? user;
    if (userMap != null) user = User.fromMap(Map<String, dynamic>.from(userMap));
    await setToken(token, user);
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

  /// Старые вызовы могли использовать `logout` — оставляем обёртку.
  Future<void> logout() async {
    await clearToken();
  }
}
