// lib/screens/profile_screen.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../utils/phone_utils.dart';
import 'change_password_screen.dart';
import 'change_phone_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final AuthService _auth = authService;
  final ImagePicker _picker = ImagePicker();

  bool _loading = true;
  bool _uploading = false;
  String _name = '';
  String _email = '';
  String _phone = '';
  String? _avatarUrl;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      final resp = await _auth.dio.get('/api/profile');
      final data = resp.data;
      if (data is Map && data['user'] is Map) {
        final u = Map<String, dynamic>.from(data['user']);
        final rawPhone = u['phone'] ?? '';
        setState(() {
          _name = (u['name'] ?? '') as String;
          _email = (u['email'] ?? '') as String;
          _phone = PhoneUtils.formatForDisplay(rawPhone.toString());
          _avatarUrl = (u['avatar_url'] ?? u['avatar'] ?? null)?.toString();
        });
      } else {
        setState(() => _message = 'Невозможно загрузить профиль');
      }
    } on DioException catch (e) {
      debugPrint('Profile load DioException: $e');
      setState(() => _message = 'Ошибка загрузки профиля: ${_extractDioMessage(e)}');
    } catch (e) {
      debugPrint('Profile load error: $e');
      setState(() => _message = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _extractDioMessage(DioException e) {
    final resp = e.response;
    if (resp != null && resp.data != null) {
      try {
        return resp.data.toString();
      } catch (_) {
        return e.message ?? e.toString();
      }
    }
    return e.message ?? e.toString();
  }

  Widget _buildAvatar() {
    const double size = 92;
    if (_avatarUrl != null && _avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: Colors.grey[200],
        backgroundImage: NetworkImage(_avatarUrl!),
      );
    }
    return const CircleAvatar(
      radius: 46,
      backgroundColor: Color(0xFFE0E0E0),
      child: Icon(Icons.person, size: 48, color: Color(0xFF757575)),
    );
  }

  Future<void> _pickAndUploadAvatar() async {
    setState(() => _message = '');
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      if (picked == null) return;

      final file = File(picked.path);
      setState(() => _uploading = true);

      final fileName = picked.name.isNotEmpty ? picked.name : file.path.split('/').last;
      final multipart = await MultipartFile.fromFile(file.path, filename: fileName);

      final formData = FormData.fromMap({'avatar': multipart});

      final resp = await _auth.dio.post(
        '/api/profile/avatar',
        data: formData,
        options: Options(
          headers: {'Content-Type': 'multipart/form-data'},
        ),
      );

      final data = resp.data as Map<String, dynamic>?;
      final newUrl = data != null ? (data['avatar_url'] ?? data['avatar'] ?? null) : null;

      if (newUrl != null) {
        setState(() {
          _avatarUrl = newUrl.toString();
          _message = 'Аватар обновлён';
        });
      } else {
        // Если сервер не вернул URL, перезагрузим профиль
        await _load();
        setState(() => _message = 'Аватар обновлён');
      }
    } on DioException catch (e) {
      debugPrint('Avatar upload DioException: $e');
      setState(() => _message = 'Ошибка загрузки аватара: ${_extractDioMessage(e)}');
    } catch (e) {
      debugPrint('Avatar upload error: $e');
      setState(() => _message = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          _buildAvatar(),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: InkWell(
                              onTap: _uploading ? null : _pickAndUploadAvatar,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                padding: const EdgeInsets.all(6),
                                child: Icon(_uploading ? Icons.hourglass_top : Icons.camera_alt, color: Colors.white, size: 18),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(_name.isNotEmpty ? _name : 'Без имени', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(_email, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                    const SizedBox(height: 2),
                    Text(_phone, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
                      child: const Text('Сменить пароль'),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePhoneScreen())),
                      child: const Text('Сменить номер телефона'),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _logout,
                        icon: const Icon(Icons.exit_to_app),
                        label: const Text('Выйти'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      ),
                    ),
                    if (_message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message, style: const TextStyle(color: Colors.red))),
                  ],
                ),
        ),
      ),
    );
  }
}
