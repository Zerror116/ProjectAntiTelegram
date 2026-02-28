import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../utils/phone_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/avatar_crop_dialog.dart';
import 'auth_screen.dart';
import 'change_password_screen.dart';
import 'change_phone_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _loading = true;
  bool _deletingAccount = false;
  bool _avatarBusy = false;
  String _name = '';
  String _email = '';
  String _phone = '';
  String? _avatarUrl;
  double _avatarFocusX = 0;
  double _avatarFocusY = 0;
  double _avatarZoom = 1;
  String _message = '';
  String _viewMode = 'creator';

  @override
  void initState() {
    super.initState();
    _viewMode = authService.viewRole ?? 'creator';
    _load();
  }

  String _extractDioMessage(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        return (data['error'] ?? data['message'] ?? 'Ошибка запроса')
            .toString();
      }
      return e.message ?? 'Ошибка запроса';
    }
    return e.toString();
  }

  String? _resolveImageUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    final base = authService.dio.options.baseUrl.trim();
    if (base.isEmpty) return value;
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  double _toAvatarFocus(Object? raw) {
    final value = double.tryParse('${raw ?? ''}');
    if (value == null || !value.isFinite) return 0;
    return value.clamp(-1.0, 1.0);
  }

  double _toAvatarZoom(Object? raw) {
    final value = double.tryParse('${raw ?? ''}');
    if (value == null || !value.isFinite) return 1;
    return value.clamp(1.0, 4.0);
  }

  void _applyUser(Map<String, dynamic> u) {
    final rawPhone = u['phone'] ?? '';
    _name = (u['name'] ?? '').toString();
    _email = (u['email'] ?? '').toString();
    _phone = PhoneUtils.formatForDisplay(rawPhone.toString());
    _avatarUrl = _resolveImageUrl((u['avatar_url'] ?? u['avatar'])?.toString());
    _avatarFocusX = _toAvatarFocus(u['avatar_focus_x']);
    _avatarFocusY = _toAvatarFocus(u['avatar_focus_y']);
    _avatarZoom = _toAvatarZoom(u['avatar_zoom']);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      final resp = await authService.dio.get('/api/profile');
      final data = resp.data;
      if (data is Map && data['user'] is Map) {
        final u = Map<String, dynamic>.from(data['user']);
        if (!mounted) return;
        setState(() => _applyUser(u));
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

  Future<void> _pickAndUploadAvatar() async {
    if (_avatarBusy) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.single.path;
    if (path == null || path.isEmpty) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось получить путь к файлу');
      return;
    }

    AvatarCropResult? placement;
    try {
      if (!mounted) return;
      placement = await showAvatarCropDialog(
        context: context,
        filePath: path,
        initialFocusX: _avatarFocusX,
        initialFocusY: _avatarFocusY,
        initialZoom: _avatarZoom,
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка подготовки фото: ${_extractDioMessage(e)}',
      );
      return;
    }
    if (placement == null) return;

    setState(() {
      _avatarBusy = true;
      _message = '';
    });
    try {
      final uploadPath = placement.croppedPath;
      final fileName = uploadPath.split(Platform.pathSeparator).last;
      final form = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(uploadPath, filename: fileName),
      });
      final resp = await authService.dio.post(
        '/api/profile/avatar',
        data: form,
      );
      final data = resp.data;
      if (data is Map && data['user'] is Map && mounted) {
        setState(() {
          _applyUser(Map<String, dynamic>.from(data['user']));
          _message = 'Аватарка обновлена';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка загрузки аватарки: ${_extractDioMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
      try {
        await File(placement.croppedPath).delete();
      } catch (_) {}
    }
  }

  Future<void> _removeAvatar() async {
    if (_avatarBusy) return;
    setState(() {
      _avatarBusy = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.delete('/api/profile/avatar');
      final data = resp.data;
      if (data is Map && data['user'] is Map && mounted) {
        setState(() {
          _applyUser(Map<String, dynamic>.from(data['user']));
          _message = 'Аватарка удалена';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка удаления аватарки: ${_extractDioMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _logout() async {
    await authService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
      (route) => false,
    );
  }

  Future<void> _changeViewMode(String mode) async {
    await authService.setViewRole(mode == 'creator' ? null : mode);
    if (!mounted) return;
    setState(() => _viewMode = mode);
  }

  Future<void> _deleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить аккаунт'),
        content: const Text('Вы уверены? Это действие необратимо.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _deletingAccount = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post('/api/auth/delete_account');
      if (resp.statusCode == 200) {
        await authService.clearToken();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AuthScreen()),
          (route) => false,
        );
        return;
      }
      if (!mounted) return;
      setState(() => _message = 'Ошибка удаления аккаунта');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _extractDioMessage(e));
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  Widget _statChip(IconData icon, String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: padding,
      child: child,
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSwitchRole = authService.canSwitchViewRole;
    final displayName = _name.isNotEmpty
        ? _name
        : (_email.isNotEmpty ? _email : 'Без имени');

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          theme.colorScheme.primaryContainer,
                          theme.colorScheme.surfaceContainerHighest,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            AppAvatar(
                              title: displayName,
                              imageUrl: _avatarUrl,
                              focusX: _avatarFocusX,
                              focusY: _avatarFocusY,
                              zoom: _avatarZoom,
                              radius: 46,
                            ),
                            Positioned(
                              right: -6,
                              bottom: -6,
                              child: Material(
                                color: theme.colorScheme.primary,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: _avatarBusy
                                      ? null
                                      : _pickAndUploadAvatar,
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: _avatarBusy
                                        ? SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color:
                                                  theme.colorScheme.onPrimary,
                                            ),
                                          )
                                        : Icon(
                                            Icons.photo_camera_outlined,
                                            size: 18,
                                            color: theme.colorScheme.onPrimary,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text(
                          displayName,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _email,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_phone.trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            _phone,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _statChip(
                              Icons.verified_user_outlined,
                              authService.currentUser?.role.toUpperCase() ??
                                  'CLIENT',
                            ),
                            _statChip(
                              Icons.visibility_outlined,
                              'Режим: ${authService.effectiveRole}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _avatarBusy
                                  ? null
                                  : _pickAndUploadAvatar,
                              icon: const Icon(Icons.image_outlined),
                              label: const Text('Изменить фото'),
                            ),
                            if (_avatarUrl != null && _avatarUrl!.isNotEmpty)
                              OutlinedButton.icon(
                                onPressed: _avatarBusy ? null : _removeAvatar,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Убрать фото'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Данные аккаунта',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _infoTile(
                          icon: Icons.person_outline,
                          label: 'Имя',
                          value: displayName,
                        ),
                        const SizedBox(height: 10),
                        _infoTile(
                          icon: Icons.mail_outline,
                          label: 'Email',
                          value: _email.isEmpty ? 'Не указан' : _email,
                        ),
                        const SizedBox(height: 10),
                        _infoTile(
                          icon: Icons.phone_outlined,
                          label: 'Телефон',
                          value: _phone.isEmpty ? 'Не указан' : _phone,
                        ),
                      ],
                    ),
                  ),
                  if (canSwitchRole) ...[
                    const SizedBox(height: 16),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Режим просмотра',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Только создатель может переключать вид приложения между ролями.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          DropdownButtonFormField<String>(
                            key: ValueKey(_viewMode),
                            initialValue: _viewMode,
                            decoration: const InputDecoration(
                              labelText: 'Показывать интерфейс как',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'creator',
                                child: Text('Creator'),
                              ),
                              DropdownMenuItem(
                                value: 'admin',
                                child: Text('Admin'),
                              ),
                              DropdownMenuItem(
                                value: 'worker',
                                child: Text('Worker'),
                              ),
                              DropdownMenuItem(
                                value: 'client',
                                child: Text('Client'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              _changeViewMode(v);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _sectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Безопасность',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ChangePasswordScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.lock_outline),
                            label: const Text('Сменить пароль'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ChangePhoneScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.phone_outlined),
                            label: const Text('Сменить номер телефона'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonalIcon(
                            onPressed: _deletingAccount ? null : _deleteAccount,
                            icon: _deletingAccount
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.delete_forever_outlined),
                            label: Text(
                              _deletingAccount
                                  ? 'Удаление...'
                                  : 'Удалить аккаунт',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout),
                      label: const Text('Выйти'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  if (_message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        _message,
                        style: TextStyle(
                          color: _message.toLowerCase().contains('ошибка')
                              ? Colors.red
                              : theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
