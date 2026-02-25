// lib/services/auth_service.dart
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

  AuthService({required this.dio});

  /// Устанавливает заголовок Authorization для текущего Dio-инстанса
  void setAuthHeader(String token) {
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  /// Попытка установить заголовок из сохранённого токена (если есть)
  /// и подтянуть профиль пользователя, чтобы заполнить currentUser.
  Future<void> setAuthHeaderFromStorage() async {
    final token = await getToken();
    if (token != null) {
      setAuthHeader(token);
      try {
        final resp = await dio.get('/api/profile');
        if (resp.statusCode == 200 && resp.data is Map && resp.data['user'] is Map) {
          _currentUser = User.fromMap(Map<String, dynamic>.from(resp.data['user']));
          debugPrint('AuthService.setAuthHeaderFromStorage -> user loaded: ${_currentUser?.email} role=${_currentUser?.role}');
        }
      } catch (e) {
        debugPrint('AuthService.setAuthHeaderFromStorage: failed to fetch profile: $e');
      }
    }
  }

  /// Сохраняет токен публично и устанавливает заголовок
  Future<void> saveToken(String token) async {
    await _saveToken(token);
    setAuthHeader(token);
    debugPrint('AuthService.saveToken -> saved and set header: ${dio.options.headers['Authorization']}');
  }

  /// Удаляет токен (logout)
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    dio.options.headers.remove('Authorization');
    pendingEmail = null;
    pendingPassword = null;
    _currentUser = null;
    debugPrint('AuthService.logout -> token removed and user cleared');
  }

  /// Вспомогательный метод: обработать ответ от /auth (вытянуть токен и user)
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
      } catch (_) {}
    }
    await saveToken(token as String);
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
      setAuthHeader(token);
      final resp = await dio.get('/api/profile');
      if (resp.statusCode == 200 && resp.data is Map && resp.data['user'] is Map) {
        _currentUser = User.fromMap(Map<String, dynamic>.from(resp.data['user']));
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('tryRefreshOnStartup failed: $e');
      await logout();
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

  /// Сохранение токена в SharedPreferences (приватный)
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

  /// Утилиты по ролям
  bool hasRole(String role) => _currentUser?.role == role;
  bool hasAnyRole(List<String> roles) => _currentUser != null && roles.contains(_currentUser!.role);
}
