import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../utils/phone_utils.dart';
import '../widgets/app_avatar.dart';
import '../widgets/avatar_crop_dialog.dart';
import '../widgets/input_language_badge.dart';
import 'change_password_screen.dart';
import 'change_phone_screen.dart';
import 'creator_keys_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const String _platformCreatorEmail = 'zerotwo02166@gmail.com';

  bool _loading = true;
  bool _deletingAccount = false;
  bool _avatarBusy = false;
  bool _inviteBusy = false;
  String _name = '';
  String _email = '';
  String _phone = '';
  String? _avatarUrl;
  double _avatarFocusX = 0;
  double _avatarFocusY = 0;
  double _avatarZoom = 1;
  String _message = '';
  String _publicInviteCode = '';
  String _viewMode = 'creator';
  Map<String, dynamic> _stats = const {};
  bool _statsExpanded = false;
  bool _sessionsBusy = false;
  bool _switchingSession = false;
  bool _addGroupBusy = false;
  final _addGroupCodeCtrl = TextEditingController();
  final _addGroupPasswordCtrl = TextEditingController();
  final _tenantClientSearchCtrl = TextEditingController();
  Timer? _tenantClientSearchDebounce;
  bool _tenantClientsLoading = false;
  bool _tenantClientsRequested = false;
  List<Map<String, dynamic>> _tenantClients = const [];
  String _tenantRoleUpdateUserId = '';
  List<Map<String, dynamic>> _savedTenantSessions = const [];

  @override
  void initState() {
    super.initState();
    _viewMode = authService.viewRole ?? 'creator';
    _load();
  }

  @override
  void dispose() {
    _tenantClientSearchDebounce?.cancel();
    _addGroupCodeCtrl.dispose();
    _addGroupPasswordCtrl.dispose();
    _tenantClientSearchCtrl.dispose();
    super.dispose();
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

  String get _effectiveRole => (authService.effectiveRole).toLowerCase().trim();

  bool get _isClientAccount => _effectiveRole == 'client';

  bool get _canManageTenantUsers {
    return authService.hasPermission('tenant.users.manage');
  }

  bool get _canManageTenantInvites {
    return authService.hasPermission('tenant.invites.manage') ||
        _canManageTenantUsers;
  }

  bool get _isTenantManagerAccount => _canManageTenantUsers;

  Options _tenantManagerRequestOptions() {
    final role = _effectiveRole;
    if (role == 'tenant') {
      return Options(headers: const {'X-View-Role': 'tenant'});
    }
    final baseRole = (authService.currentUser?.role ?? '').toLowerCase().trim();
    if (baseRole == 'creator') {
      return Options(headers: const {'X-View-Role': 'creator'});
    }
    if (baseRole == 'tenant') {
      return Options(headers: const {'X-View-Role': 'tenant'});
    }
    if (role == 'creator') {
      return Options(headers: const {'X-View-Role': 'creator'});
    }
    return Options();
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

  String _roleLabel(String role) {
    switch (role.toLowerCase().trim()) {
      case 'creator':
        return 'Создатель';
      case 'tenant':
        return 'Арендатор';
      case 'admin':
        return 'Администратор';
      case 'worker':
        return 'Работник';
      case 'client':
      default:
        return 'Клиент';
    }
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

  String get _currentSessionId {
    final user = authService.currentUser;
    if (user == null) return '';
    final email = user.email.trim().toLowerCase();
    final tenant = (user.tenantCode ?? '').trim().toLowerCase();
    return '$email::$tenant';
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
        setState(() {
          _applyUser(u);
          _stats = data['stats'] is Map
              ? Map<String, dynamic>.from(data['stats'])
              : const {};
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
      unawaited(_loadSavedSessions());
    }
  }

  void _onTenantClientSearchChanged(String value) {
    _tenantClientSearchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _tenantClientsRequested = false;
        _tenantClients = const [];
      });
      return;
    }
    _tenantClientSearchDebounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      unawaited(_loadTenantClients(searchOverride: query));
    });
  }

  Future<void> _loadSavedSessions() async {
    if (_sessionsBusy) return;
    _sessionsBusy = true;
    try {
      final sessionsRaw = await authService.listSavedTenantSessions();
      List<Map<String, dynamic>> sessions = const [];
      if (_isClientAccount) {
        final currentEmail = (authService.currentUser?.email ?? '')
            .trim()
            .toLowerCase();
        final filtered = sessionsRaw.where((row) {
          final email = (row['email'] ?? '').toString().trim().toLowerCase();
          final role = (row['role'] ?? '').toString().trim().toLowerCase();
          final tenantCode = (row['tenant_code'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          return email == currentEmail &&
              role == 'client' &&
              tenantCode.isNotEmpty;
        });
        final seenTenantCodes = <String>{};
        sessions = filtered.where((row) {
          final tenantCode = (row['tenant_code'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          if (tenantCode.isEmpty) return false;
          if (seenTenantCodes.contains(tenantCode)) return false;
          seenTenantCodes.add(tenantCode);
          return true;
        }).toList();
      }
      if (!mounted) return;
      setState(() {
        _savedTenantSessions = sessions;
      });
    } finally {
      _sessionsBusy = false;
    }
  }

  String _sessionTenantLabel(Map<String, dynamic> row) {
    final tenantName = (row['tenant_name'] ?? '').toString().trim();
    if (tenantName.isNotEmpty) return tenantName;
    final tenantCode = (row['tenant_code'] ?? '').toString().trim();
    if (tenantCode.isNotEmpty) return tenantCode;
    return 'Неизвестная группа';
  }

  Map<String, String> _extractInvitePayload(String raw) {
    final source = raw.trim();
    if (source.isEmpty) {
      return const {'invite': '', 'tenant': ''};
    }

    String invite = '';
    String tenant = '';

    void extractFromUri(Uri uri) {
      if (invite.isEmpty) {
        invite =
            (uri.queryParameters['invite'] ?? uri.queryParameters['code'] ?? '')
                .trim();
      }
      if (tenant.isEmpty) {
        tenant =
            (uri.queryParameters['tenant'] ??
                    uri.queryParameters['tenant_code'] ??
                    '')
                .trim()
                .toLowerCase();
      }
      if (uri.fragment.isNotEmpty) {
        final fragment = uri.fragment;
        final qIndex = fragment.indexOf('?');
        if (qIndex >= 0 && qIndex + 1 < fragment.length) {
          final inFragment = Uri.splitQueryString(
            fragment.substring(qIndex + 1),
          );
          if (invite.isEmpty) {
            invite = (inFragment['invite'] ?? inFragment['code'] ?? '').trim();
          }
          if (tenant.isEmpty) {
            tenant = (inFragment['tenant'] ?? inFragment['tenant_code'] ?? '')
                .trim()
                .toLowerCase();
          }
        }
      }
    }

    try {
      final uri = Uri.parse(source);
      if (uri.hasScheme || source.contains('?') || source.contains('#')) {
        extractFromUri(uri);
      }
    } catch (_) {}

    if (invite.isEmpty) {
      invite = source;
    }

    return {'invite': invite, 'tenant': tenant};
  }

  Future<String> _resolveTenantCodeByInvite(String inviteCode) async {
    final normalized = inviteCode.trim();
    if (normalized.isEmpty) return '';
    try {
      final resp = await authService.dio.post(
        '/api/auth/invite/resolve',
        data: {'invite_code': normalized},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final row = Map<String, dynamic>.from(data['data']);
        return (row['tenant_code'] ?? '').toString().trim().toLowerCase();
      }
    } catch (_) {}
    return '';
  }

  Future<void> _addGroupByInvite() async {
    if (_addGroupBusy || !_isClientAccount) return;

    final invitePayload = _extractInvitePayload(_addGroupCodeCtrl.text);
    final inviteCode = (invitePayload['invite'] ?? '').trim();
    var tenantCode = (invitePayload['tenant'] ?? '').trim().toLowerCase();
    final password = _addGroupPasswordCtrl.text.trim();

    if (inviteCode.isEmpty) {
      setState(() => _message = 'Введите код или ссылку приглашения');
      return;
    }
    if (password.length < 8) {
      setState(() => _message = 'Введите пароль (минимум 8 символов)');
      return;
    }

    final current = authService.currentUser;
    if (current == null || current.email.trim().isEmpty) {
      setState(() => _message = 'Сессия не найдена. Перезайдите в аккаунт');
      return;
    }

    final previousSessionId = _currentSessionId;
    final previousTenantCode = (current.tenantCode ?? '').trim();
    final email = current.email.trim();
    final name = (_name.isNotEmpty ? _name : (current.name ?? '')).trim();
    final phone = (current.phone ?? '').toString().trim();

    setState(() {
      _addGroupBusy = true;
      _message = '';
    });
    try {
      if (tenantCode.isEmpty) {
        tenantCode = await _resolveTenantCodeByInvite(inviteCode);
      }
      if (tenantCode.isNotEmpty) {
        await authService.setTenantCode(tenantCode);
      }

      var joined = false;
      try {
        await authService.register(
          email: email,
          password: password,
          name: name.isEmpty ? null : name,
          phone: phone.isEmpty ? null : phone,
          accessKey: inviteCode,
        );
        joined = true;
      } catch (e) {
        final text = _extractDioMessage(e).toLowerCase();
        final alreadyRegistered =
            text.contains('email already registered') ||
            text.contains('уже зарегистр');
        if (alreadyRegistered && tenantCode.isNotEmpty) {
          await authService.login(email: email, password: password);
          joined = true;
        } else {
          rethrow;
        }
      }

      if (!joined) {
        throw Exception('Не удалось добавить группу');
      }

      var switchedBack = true;
      if (previousSessionId.isNotEmpty) {
        switchedBack = await authService.switchToSavedTenantSession(
          previousSessionId,
        );
      }
      if (previousTenantCode.isNotEmpty) {
        await authService.setTenantCode(previousTenantCode);
      }

      _addGroupCodeCtrl.clear();
      _addGroupPasswordCtrl.clear();
      await _loadSavedSessions();
      await _load();
      if (!mounted) return;
      setState(() {
        _message = switchedBack
            ? 'Группа добавлена. Теперь можно переключаться в "Мои группы".'
            : 'Группа добавлена, но не удалось вернуться в прошлую группу автоматически.';
      });
    } catch (e) {
      if (previousTenantCode.isNotEmpty) {
        await authService.setTenantCode(previousTenantCode);
      }
      if (!mounted) return;
      final text = _extractDioMessage(e);
      setState(() => _message = 'Ошибка добавления группы: $text');
    } finally {
      if (mounted) setState(() => _addGroupBusy = false);
    }
  }

  Future<void> _switchToSession(Map<String, dynamic> row) async {
    if (_switchingSession) return;
    final sessionId = (row['id'] ?? '').toString().trim();
    if (sessionId.isEmpty) return;
    setState(() => _switchingSession = true);
    try {
      final ok = await authService.switchToSavedTenantSession(sessionId);
      if (!mounted) return;
      if (!ok) {
        setState(() => _message = 'Не удалось переключить группу');
        await _loadSavedSessions();
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка переключения: ${_extractDioMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _switchingSession = false);
    }
  }

  Future<void> _removeSavedSession(Map<String, dynamic> row) async {
    final sessionId = (row['id'] ?? '').toString().trim();
    if (sessionId.isEmpty || sessionId == _currentSessionId) return;
    await authService.removeSavedTenantSession(sessionId);
    await _loadSavedSessions();
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
  }

  Future<void> _changeViewMode(String mode) async {
    await authService.setViewRole(mode == 'creator' ? null : mode);
    if (!mounted) return;
    setState(() => _viewMode = mode);
    await _load();
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

  Future<void> _fetchPublicInviteCode() async {
    if (!_canManageTenantInvites) return;
    if (_inviteBusy) return;
    setState(() {
      _inviteBusy = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/profile/tenant/client-invite',
        options: _tenantManagerRequestOptions(),
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final row = Map<String, dynamic>.from(data['data']);
        var code = (row['code'] ?? '').toString().trim().toUpperCase();
        if (code.isEmpty) {
          final link = (row['invite_link'] ?? '').toString().trim();
          if (link.isNotEmpty) {
            try {
              final uri = Uri.parse(link);
              code =
                  (uri.queryParameters['invite'] ??
                          uri.queryParameters['code'] ??
                          '')
                      .trim()
                      .toUpperCase();
            } catch (_) {}
          }
        }
        if (code.isEmpty) {
          if (!mounted) return;
          setState(() => _message = 'Код приглашения недоступен');
          return;
        }
        await Clipboard.setData(ClipboardData(text: code));
        if (!mounted) return;
        setState(() {
          _publicInviteCode = code;
          _message = 'Код приглашения скопирован';
        });
      } else {
        if (!mounted) return;
        setState(() => _message = 'Не удалось получить код приглашения');
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка кода приглашения: ${_extractDioMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _inviteBusy = false);
    }
  }

  Future<void> _loadTenantClients({String? searchOverride}) async {
    if (!_canManageTenantUsers) return;
    final search = (searchOverride ?? _tenantClientSearchCtrl.text).trim();
    if (search.isEmpty) {
      if (!mounted) return;
      setState(() {
        _tenantClientsLoading = false;
        _tenantClientsRequested = false;
        _tenantClients = const [];
      });
      return;
    }
    setState(() {
      _tenantClientsLoading = true;
      _tenantClientsRequested = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/profile/tenant/clients',
        queryParameters: {'search': search},
        options: _tenantManagerRequestOptions(),
      );
      final data = resp.data;
      if (!mounted) return;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        setState(() {
          _tenantClients = List<Map<String, dynamic>>.from(data['data']);
        });
      } else {
        setState(() => _message = 'Не удалось загрузить список клиентов');
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка списка клиентов: ${_extractDioMessage(e)}',
      );
    } finally {
      if (mounted) setState(() => _tenantClientsLoading = false);
    }
  }

  Future<void> _setTenantClientRole(String userId, String role) async {
    if (!_canManageTenantUsers) return;
    final id = userId.trim();
    if (id.isEmpty) return;
    setState(() {
      _tenantRoleUpdateUserId = id;
      _message = '';
    });
    try {
      await authService.dio.patch(
        '/api/profile/tenant/clients/$id/role',
        data: {'role': role},
        options: _tenantManagerRequestOptions(),
      );
      if (!mounted) return;
      setState(() => _message = 'Роль успешно обновлена');
      await _loadTenantClients();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка смены роли: ${_extractDioMessage(e)}');
    } finally {
      if (mounted) {
        setState(() {
          if (_tenantRoleUpdateUserId == id) _tenantRoleUpdateUserId = '';
        });
      }
    }
  }

  Future<void> _openTenantRoleMenu(Map<String, dynamic> userRow) async {
    if (!_canManageTenantUsers) return;
    final userId = (userRow['id'] ?? '').toString().trim();
    final currentRole = (userRow['role'] ?? 'client').toString().trim();
    if (userId.isEmpty) return;

    final role = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final options = const <Map<String, String>>[
          {'value': 'client', 'label': 'Клиент'},
          {'value': 'worker', 'label': 'Работник'},
          {'value': 'admin', 'label': 'Администратор'},
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...options.map((option) {
                final value = option['value'] ?? 'client';
                final label = option['label'] ?? value;
                final selected = currentRole == value;
                return ListTile(
                  leading: Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                  ),
                  title: Text(label),
                  onTap: () => Navigator.of(ctx).pop(value),
                );
              }),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );

    if (role == null || role == currentRole) return;
    await _setTenantClientRole(userId, role);
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bounded = constraints.hasBoundedWidth;
          final compact = bounded && constraints.maxWidth < 160;
          if (!bounded) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ],
            );
          }
          if (compact) {
            return Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge,
            );
          }
          return Row(
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          );
        },
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

  String _formatMoneyCompact(dynamic raw) {
    final value = double.tryParse('${raw ?? ''}') ?? 0;
    return '${value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 2)} RUB';
  }

  Map<String, dynamic> _statsMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  Widget _statsMetricRow(String label, String value) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _periodCard({required String title, required List<Widget> children}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _buildStatsSection(String effectiveRole) {
    final theme = Theme.of(context);
    final stats = _statsMap(_stats['periods']);
    final today = _statsMap(stats['today']);
    final week = _statsMap(stats['week']);
    final month = _statsMap(stats['month']);
    final allTime = _statsMap(stats['all_time']);
    final live = _statsMap(stats['live']);

    Widget buildClientCard(String title, Map<String, dynamic> data) {
      return _periodCard(
        title: title,
        children: [
          _statsMetricRow('Куплено товаров', '${data['items'] ?? 0}'),
          const SizedBox(height: 8),
          _statsMetricRow('Потрачено', _formatMoneyCompact(data['amount'])),
        ],
      );
    }

    Widget buildWorkerCard(String title, Map<String, dynamic> data) {
      return _periodCard(
        title: title,
        children: [
          _statsMetricRow('Сделано постов', '${data['posts'] ?? 0}'),
          const SizedBox(height: 8),
          _statsMetricRow('Продано штук', '${data['sold'] ?? 0}'),
          const SizedBox(height: 8),
          _statsMetricRow('Принес денег', _formatMoneyCompact(data['amount'])),
        ],
      );
    }

    Widget buildAdminCard(String title, Map<String, dynamic> data) {
      return _periodCard(
        title: title,
        children: [
          _statsMetricRow('Обработано штук', '${data['processed'] ?? 0}'),
          const SizedBox(height: 8),
          _statsMetricRow(
            'Стоимость обработки',
            _formatMoneyCompact(data['processed_amount']),
          ),
          const SizedBox(height: 8),
          _statsMetricRow('Собрано доставок', '${data['deliveries'] ?? 0}'),
        ],
      );
    }

    Widget buildCreatorCard(String title, Map<String, dynamic> data) {
      return _periodCard(
        title: title,
        children: [
          _statsMetricRow('Новых людей', '${data['users'] ?? 0}'),
          const SizedBox(height: 8),
          _statsMetricRow('Постов работников', '${data['worker_posts'] ?? 0}'),
          const SizedBox(height: 8),
          _statsMetricRow(
            'Обработано админами',
            '${data['admin_processed'] ?? 0}',
          ),
          const SizedBox(height: 8),
          _statsMetricRow(
            'Потрачено клиентами',
            _formatMoneyCompact(data['client_amount']),
          ),
        ],
      );
    }

    Widget buildByRole(String title, Map<String, dynamic> data) {
      switch (effectiveRole) {
        case 'worker':
          return buildWorkerCard(title, data);
        case 'tenant':
        case 'admin':
          return buildAdminCard(title, data);
        case 'creator':
          return buildCreatorCard(title, data);
        case 'client':
        default:
          return buildClientCard(title, data);
      }
    }

    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(() => _statsExpanded = !_statsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Статистика',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    _statsExpanded ? 'Скрыть' : 'Показать',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _statsExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _statsExpanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 14),
                buildByRole('Сегодня', today),
                const SizedBox(height: 12),
                buildByRole('За неделю', week),
                const SizedBox(height: 12),
                buildByRole('За месяц', month),
                const SizedBox(height: 12),
                buildByRole('За всё время', allTime),
                if (effectiveRole == 'creator' && live.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _statChip(
                        Icons.inventory_2_outlined,
                        'Очередь: ${live['pending_posts'] ?? 0}',
                      ),
                      _statChip(
                        Icons.pending_actions_outlined,
                        'Не обработано резервов: ${live['unprocessed_reservations'] ?? 0}',
                      ),
                      _statChip(
                        Icons.local_shipping_outlined,
                        'Активных доставок: ${live['active_delivery_clients'] ?? 0}',
                      ),
                    ],
                  ),
                ],
              ],
            ),
            secondChild: Text(
              'Статистика скрыта',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
    final actualRole = authService.currentUser?.role ?? 'client';
    final effectiveRole = authService.effectiveRole;
    final canManageClients = _canManageTenantUsers;
    final canShareInvite = _canManageTenantInvites;
    final isPlatformCreator =
        actualRole.toLowerCase().trim() == 'creator' &&
        effectiveRole.toLowerCase().trim() == 'creator' &&
        (authService.currentUser?.email ?? '').toLowerCase().trim() ==
            _platformCreatorEmail;
    final tenantLabel =
        (authService.currentUser?.tenantName ?? '').trim().isNotEmpty
        ? (authService.currentUser?.tenantName ?? '').trim()
        : ((authService.currentUser?.tenantCode ?? '').trim().isNotEmpty
              ? (authService.currentUser?.tenantCode ?? '').trim()
              : 'Группа не выбрана');

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
                              _roleLabel(actualRole),
                            ),
                            if (canSwitchRole)
                              _statChip(
                                Icons.visibility_outlined,
                                'Режим: ${_roleLabel(effectiveRole)}',
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
                  _buildStatsSection(effectiveRole),
                  if (canShareInvite) ...[
                    const SizedBox(height: 16),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Приглашение в вашу группу',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Скопируйте короткий код и отправьте клиенту для регистрации.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              onPressed: _inviteBusy
                                  ? null
                                  : _fetchPublicInviteCode,
                              icon: _inviteBusy
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.share_outlined),
                              label: const Text('Скопировать код'),
                            ),
                          ),
                          if (_publicInviteCode.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            SelectableText(
                              _publicInviteCode,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (canManageClients) ...[
                    const SizedBox(height: 16),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Управление клиентами',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Ищите клиентов вашей группы и меняйте их роль на работника или администратора.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _tenantClientSearchCtrl,
                                  decoration: withInputLanguageBadge(
                                    const InputDecoration(
                                      labelText:
                                          'Поиск по имени, email, телефону',
                                      border: OutlineInputBorder(),
                                    ),
                                    controller: _tenantClientSearchCtrl,
                                  ),
                                  onChanged: _onTenantClientSearchChanged,
                                  onSubmitted: (_) => _loadTenantClients(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: 'Найти',
                                onPressed: _tenantClientsLoading
                                    ? null
                                    : () => _loadTenantClients(),
                                icon: _tenantClientsLoading
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.search_rounded),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_tenantClients.isEmpty && !_tenantClientsLoading)
                            Text(
                              _tenantClientSearchCtrl.text.trim().isEmpty
                                  ? 'Начните вводить имя, email или телефон клиента.'
                                  : (_tenantClientsRequested
                                        ? 'По этому запросу клиенты не найдены.'
                                        : 'Список пока пуст.'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ..._tenantClients.map((row) {
                            final userId = (row['id'] ?? '').toString();
                            final fullName = (row['name'] ?? '')
                                .toString()
                                .trim();
                            final email = (row['email'] ?? '')
                                .toString()
                                .trim();
                            final phone = PhoneUtils.formatForDisplay(
                              (row['phone'] ?? '').toString(),
                            );
                            final role = (row['role'] ?? 'client').toString();
                            final isBusy =
                                userId.isNotEmpty &&
                                _tenantRoleUpdateUserId == userId;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          fullName.isNotEmpty
                                              ? fullName
                                              : email,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          email,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                        if (phone.trim().isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            phone,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        _statChip(
                                          Icons.badge_outlined,
                                          'Роль: ${_roleLabel(role)}',
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Изменить роль',
                                    onPressed: isBusy
                                        ? null
                                        : () => _openTenantRoleMenu(row),
                                    icon: isBusy
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.manage_accounts),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                  if (_isClientAccount) ...[
                    const SizedBox(height: 16),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Мои группы',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Здесь отображаются только ваши клиентские группы. Добавьте новую по коду приглашения.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _addGroupCodeCtrl,
                            decoration: withInputLanguageBadge(
                              const InputDecoration(
                                labelText: 'Код или ссылка приглашения',
                                border: OutlineInputBorder(),
                              ),
                              controller: _addGroupCodeCtrl,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _addGroupPasswordCtrl,
                            obscureText: true,
                            decoration: withInputLanguageBadge(
                              const InputDecoration(
                                labelText: 'Пароль аккаунта в новой группе',
                                border: OutlineInputBorder(),
                              ),
                              controller: _addGroupPasswordCtrl,
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _addGroupBusy
                                  ? null
                                  : _addGroupByInvite,
                              icon: _addGroupBusy
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.group_add_outlined),
                              label: Text(
                                _addGroupBusy
                                    ? 'Добавление...'
                                    : 'Добавить группу',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_savedTenantSessions.isEmpty)
                            Text(
                              'Пока доступна только текущая группа.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ..._savedTenantSessions.map((row) {
                            final sessionId = (row['id'] ?? '').toString();
                            final active = sessionId == _currentSessionId;
                            final tenantLabel = _sessionTenantLabel(row);
                            final roleLabel = _roleLabel(
                              (row['role'] ?? 'client').toString(),
                            );
                            final email = (row['email'] ?? '').toString();
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: active
                                    ? theme.colorScheme.primaryContainer
                                    : theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: active
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.outlineVariant,
                                ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final compact = constraints.maxWidth < 420;
                                  final actions = <Widget>[
                                    if (active)
                                      const Icon(Icons.check_circle_outline)
                                    else
                                      FilledButton.tonal(
                                        onPressed: _switchingSession
                                            ? null
                                            : () => _switchToSession(row),
                                        child: const Text('Выбрать'),
                                      ),
                                    if (!active)
                                      IconButton(
                                        tooltip: 'Убрать из списка',
                                        onPressed: _switchingSession
                                            ? null
                                            : () => _removeSavedSession(row),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                  ];

                                  final details = Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tenantLabel,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '$roleLabel • $email',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  );

                                  if (compact) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        details,
                                        const SizedBox(height: 8),
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: Wrap(
                                            spacing: 6,
                                            runSpacing: 6,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            alignment: WrapAlignment.end,
                                            children: actions,
                                          ),
                                        ),
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      Expanded(child: details),
                                      const SizedBox(width: 8),
                                      Wrap(
                                        spacing: 6,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: actions,
                                      ),
                                    ],
                                  );
                                },
                              ),
                            );
                          }),
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
                        const SizedBox(height: 10),
                        _infoTile(
                          icon: Icons.groups_outlined,
                          label: 'Текущая группа',
                          value: tenantLabel,
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
                                child: Text('Создатель'),
                              ),
                              DropdownMenuItem(
                                value: 'admin',
                                child: Text('Администратор'),
                              ),
                              DropdownMenuItem(
                                value: 'worker',
                                child: Text('Работник'),
                              ),
                              DropdownMenuItem(
                                value: 'client',
                                child: Text('Клиент'),
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
                  if (isPlatformCreator) ...[
                    const SizedBox(height: 16),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ключи арендаторов',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Управление ключами доступа арендаторов.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const CreatorKeysScreen(),
                                ),
                              ),
                              icon: const Icon(Icons.vpn_key_outlined),
                              label: const Text('Открыть ключи'),
                            ),
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
