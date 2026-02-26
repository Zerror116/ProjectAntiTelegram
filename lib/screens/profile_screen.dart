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
import 'auth_screen.dart';

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

  String _extractDioMessage(dynamic e) {
    try {
      final resp = (e is DioException) ? e.response : (e is DioError ? e.response : null);
      if (resp != null && resp.data != null) return resp.data.toString();
    } catch (_) {}
    return e?.toString() ?? 'Неизвестная ошибка';
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
        if (!mounted) return;
        setState(() {
          _name = (u['name'] ?? '') as String;
          _email = (u['email'] ?? '') as String;
          _phone = PhoneUtils.formatForDisplay(rawPhone.toString());
          _avatarUrl = (u['avatar_url'] ?? u['avatar'] ?? null)?.toString();
        });
      } else {
        if (!mounted) return;
        setState(() => _message = 'Ошибка загрузки профиля');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _extractDioMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await authService.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
        (route) => false,
      );
    }
  }

  Widget _buildAvatar() {
    final name = (_name.isNotEmpty ? _name : _email);
    final initials = name.isNotEmpty
        ? name.trim().split(' ').map((s) => s.isNotEmpty ? s[0] : '').take(2).join().toUpperCase()
        : '?';

    if (_avatarUrl != null && _avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 40,
        backgroundImage: NetworkImage(_avatarUrl!),
        backgroundColor: Colors.grey[300],
      );
    } else {
      return CircleAvatar(
        radius: 40,
        backgroundColor: Colors.grey[400],
        child: Text(initials, style: const TextStyle(fontSize: 32, color: Colors.white)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
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
                          // Можно добавить загрузку аватара через ImagePicker, если нужно
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
                    if (_message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_message, style: const TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}