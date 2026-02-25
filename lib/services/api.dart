// lib/services/api.dart
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiService {
  final Dio dio;
  final FlutterSecureStorage storage;

  ApiService._(this.dio, this.storage);

  factory ApiService({String baseUrl = 'http://localhost:3000'}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    final storage = const FlutterSecureStorage();
    return ApiService._(dio, storage);
  }

  Future<void> setAuthToken(String token) async {
    await storage.write(key: 'jwt', value: token);
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  Future<String?> getAuthToken() async {
    return await storage.read(key: 'jwt');
  }

  Future<Map<String, dynamic>> register(String email, String password) async {
    final resp = await dio.post('/api/auth/register', data: {'email': email, 'password': password});
    final token = resp.data['token'] as String?;
    if (token != null) await setAuthToken(token);
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final resp = await dio.post('/api/auth/login', data: {'email': email, 'password': password});
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
