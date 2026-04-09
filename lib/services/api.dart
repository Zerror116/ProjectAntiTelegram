// lib/services/api.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiService {
  final Dio dio;
  final FlutterSecureStorage storage;
  static const String _authTokenKey = 'auth_token';

  ApiService._(this.dio, this.storage);

  static const String _localDebugBaseUrl = 'http://127.0.0.1:3001';
  static const String _legacyLocalDebugBaseUrl = 'http://127.0.0.1:3000';

  static String _resolveBaseUrl(String rawBaseUrl) {
    final source = rawBaseUrl.trim();
    if (source.isNotEmpty) return source;
    if (!kIsWeb) return _localDebugBaseUrl;

    final uri = Uri.base;
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.trim();
    if ((scheme == 'http' || scheme == 'https') && host.isNotEmpty) {
      final portPart = uri.hasPort ? ':${uri.port}' : '';
      return '$scheme://$host$portPart';
    }
    return _legacyLocalDebugBaseUrl;
  }

  factory ApiService({String baseUrl = ''}) {
    final resolvedBaseUrl = _resolveBaseUrl(baseUrl);
    final dio = Dio(
      BaseOptions(
        baseUrl: resolvedBaseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    final storage = const FlutterSecureStorage();
    return ApiService._(dio, storage);
  }

  Future<void> setAuthToken(String token) async {
    await storage.write(key: _authTokenKey, value: token);
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  Future<String?> getAuthToken() async {
    return await storage.read(key: _authTokenKey);
  }

  Future<Map<String, dynamic>> register(String email, String password) async {
    final resp = await dio.post(
      '/api/auth/register',
      data: {'email': email, 'password': password},
    );
    final token = resp.data['token'] as String?;
    if (token != null) await setAuthToken(token);
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final resp = await dio.post(
      '/api/auth/login',
      data: {'email': email, 'password': password},
    );
    final token = resp.data['token'] as String?;
    if (token != null) await setAuthToken(token);
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> fetchProfile() async {
    final token = await getAuthToken();
    if (token == null) return null;
    dio.options.headers['Authorization'] = 'Bearer $token';
    final resp = await dio.get('/api/profile');
    return resp.data as Map<String, dynamic>?;
  }
}
