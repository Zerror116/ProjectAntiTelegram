import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/input_language_badge.dart';

class ClientGroupsScreen extends StatefulWidget {
  const ClientGroupsScreen({super.key});

  @override
  State<ClientGroupsScreen> createState() => _ClientGroupsScreenState();
}

class _ClientGroupsScreenState extends State<ClientGroupsScreen> {
  final _inviteCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  VoidCallback? _pendingInviteListener;
  List<Map<String, dynamic>> _sessions = const <Map<String, dynamic>>[];
  bool _loading = true;
  bool _joining = false;
  bool _switching = false;
  bool _switchAfterJoin = true;
  String _message = '';
  String _tenantHint = '';
  String _tenantHintInvite = '';

  @override
  void initState() {
    super.initState();
    _pendingInviteListener = _applyPendingInvite;
    pendingClientGroupInviteVersion.addListener(_pendingInviteListener!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyPendingInvite();
      unawaited(_loadSessions());
    });
  }

  @override
  void dispose() {
    final listener = _pendingInviteListener;
    if (listener != null) {
      pendingClientGroupInviteVersion.removeListener(listener);
    }
    _inviteCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  bool get _isClient {
    return authService.effectiveRole.toLowerCase().trim() == 'client';
  }

  String get _currentSessionId {
    final user = authService.currentUser;
    if (user == null) return '';
    final email = user.email.trim().toLowerCase();
    final tenant = (user.tenantCode ?? '').trim().toLowerCase();
    return '$email::$tenant';
  }

  String _extractError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final text = (data['error'] ?? data['message'] ?? '').toString().trim();
        if (text.isNotEmpty) return text;
      }
      final message = error.message?.trim() ?? '';
      if (message.isNotEmpty) return message;
    }
    return error.toString();
  }

  String _tenantLabel(Map<String, dynamic> row) {
    final tenantName = (row['tenant_name'] ?? '').toString().trim();
    if (tenantName.isNotEmpty) return tenantName;
    final tenantCode = (row['tenant_code'] ?? '').toString().trim();
    if (tenantCode.isNotEmpty) return tenantCode;
    return 'Группа';
  }

  String _switchFailureMessage() {
    final reason = (authService.lastSavedTenantSwitchFailureReason ?? '')
        .trim()
        .toLowerCase();
    if (reason.contains('transient')) {
      return 'Сервер временно недоступен. Группа осталась в списке, попробуйте позже.';
    }
    if (reason.contains('restricted')) {
      return 'Доступ к этой группе сейчас ограничен. Группа осталась в списке.';
    }
    if (reason.contains('auth_rejected')) {
      return 'Сохранённый вход в эту группу истёк. Добавьте группу заново по приглашению.';
    }
    if (reason.contains('missing')) {
      return 'Сохранённый вход в эту группу не найден. Добавьте группу заново.';
    }
    return 'Не удалось переключить группу. Группа осталась в списке, попробуйте ещё раз.';
  }

  String _normalizeTenantCode(Object? value) =>
      value?.toString().trim().toLowerCase() ?? '';

  String _normalizeInviteCode(Object? value) {
    return value
            ?.toString()
            .toUpperCase()
            .replaceAll(RegExp(r'[^A-Z0-9-]'), '')
            .trim() ??
        '';
  }

  Map<String, String> _extractInvitePayload(String raw) {
    final source = raw.trim();
    if (source.isEmpty) return const {'invite': '', 'tenant': ''};
    String invite = '';
    String tenant = '';

    void extractFromUri(Uri uri) {
      final segments = uri.pathSegments
          .map((segment) => Uri.decodeComponent(segment).trim())
          .where((segment) => segment.isNotEmpty)
          .toList();
      final joinIndex = segments.indexWhere(
        (segment) => segment.toLowerCase() == 'join',
      );
      if (invite.isEmpty && joinIndex >= 0 && joinIndex + 1 < segments.length) {
        invite = segments[joinIndex + 1].trim();
      }
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

    if (invite.isEmpty) invite = source;
    return {'invite': invite, 'tenant': tenant};
  }

  void _applyPendingInvite() {
    if (!mounted || !_isClient) return;
    final pending = consumePendingClientGroupInvite();
    if (pending == null) return;
    final inviteCode = _normalizeInviteCode(pending.inviteCode);
    if (inviteCode.isEmpty) return;
    setState(() {
      _inviteCtrl.text = inviteCode;
      _passwordCtrl.clear();
      _switchAfterJoin = true;
      _tenantHint = _normalizeTenantCode(pending.tenantCode);
      _tenantHintInvite = inviteCode;
      _message =
          'Приглашение найдено. Введите пароль аккаунта и добавьте группу.';
    });
  }

  Future<void> _loadSessions() async {
    if (!_isClient) {
      if (mounted) {
        setState(() {
          _sessions = const <Map<String, dynamic>>[];
          _loading = false;
        });
      }
      return;
    }

    setState(() => _loading = true);
    try {
      final currentEmail = (authService.currentUser?.email ?? '')
          .trim()
          .toLowerCase();
      final raw = await authService.listSavedTenantSessions();
      final seen = <String>{};
      final filtered = <Map<String, dynamic>>[];
      for (final row in raw) {
        final email = (row['email'] ?? '').toString().trim().toLowerCase();
        final role = (row['role'] ?? '').toString().trim().toLowerCase();
        final tenantCode = (row['tenant_code'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (email != currentEmail || role != 'client' || tenantCode.isEmpty) {
          continue;
        }
        if (!seen.add(tenantCode)) continue;
        filtered.add(row);
      }
      final current = authService.currentUser;
      final currentTenantCode = (current?.tenantCode ?? '')
          .trim()
          .toLowerCase();
      if (current != null &&
          currentTenantCode.isNotEmpty &&
          !seen.contains(currentTenantCode)) {
        filtered.insert(0, {
          'id': _currentSessionId,
          'email': current.email,
          'name': current.name ?? '',
          'role': current.role,
          'tenant_code': current.tenantCode ?? '',
          'tenant_name': current.tenantName ?? '',
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
      if (!mounted) return;
      setState(() {
        _sessions = filtered;
        _message = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось загрузить группы: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
    if (_joining || !_isClient) return;
    final invitePayload = _extractInvitePayload(_inviteCtrl.text);
    final inviteCode = _normalizeInviteCode(invitePayload['invite']);
    var tenantCode = (invitePayload['tenant'] ?? '').trim().toLowerCase();
    if (tenantCode.isEmpty && inviteCode == _tenantHintInvite) {
      tenantCode = _tenantHint;
    }
    final password = _passwordCtrl.text.trim();

    if (inviteCode.isEmpty) {
      setState(() => _message = 'Введите код или ссылку приглашения');
      return;
    }
    if (password.length < 8) {
      setState(() => _message = 'Введите пароль аккаунта');
      return;
    }

    final current = authService.currentUser;
    if (current == null || current.email.trim().isEmpty) {
      setState(() => _message = 'Сессия не найдена. Войдите заново');
      return;
    }

    final previousSessionId = _currentSessionId;
    final previousTenantCode = (current.tenantCode ?? '').trim();
    final email = current.email.trim();
    final name = (current.name ?? '').trim();
    final phone = (current.phone ?? '').trim();

    setState(() {
      _joining = true;
      _message = '';
    });
    try {
      if (tenantCode.isEmpty) {
        tenantCode = await _resolveTenantCodeByInvite(inviteCode);
      }
      if (tenantCode.isNotEmpty) {
        await authService.setTenantCode(tenantCode);
      }
      await authService.joinClientGroupByInvite(
        email: email,
        password: password,
        inviteCode: inviteCode,
        tenantCode: tenantCode,
        name: name.isEmpty ? null : name,
        phone: phone.isEmpty ? null : phone,
      );

      var switchedBack = true;
      if (!_switchAfterJoin && previousSessionId.isNotEmpty) {
        switchedBack = await authService.switchToSavedTenantSession(
          previousSessionId,
        );
      }
      if (!_switchAfterJoin && previousTenantCode.isNotEmpty) {
        await authService.setTenantCode(previousTenantCode);
      }

      _inviteCtrl.clear();
      _passwordCtrl.clear();
      _tenantHint = '';
      _tenantHintInvite = '';
      await _loadSessions();
      if (!mounted) return;
      if (_switchAfterJoin) {
        activeShellSectionNotifier.value = 'groups';
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/main', (route) => false);
        return;
      }
      setState(() {
        _message = switchedBack
            ? 'Группа добавлена. Можно переключиться в списке.'
            : 'Группа добавлена, но вернуться автоматически не получилось.';
      });
    } catch (error) {
      if (previousTenantCode.isNotEmpty) {
        await authService.setTenantCode(previousTenantCode);
      }
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка добавления группы: ${_extractError(error)}',
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _switchTo(Map<String, dynamic> row) async {
    if (_switching) return;
    final sessionId = (row['id'] ?? '').toString().trim();
    if (sessionId.isEmpty || sessionId == _currentSessionId) return;
    setState(() {
      _switching = true;
      _message = '';
    });
    try {
      final ok = await authService.switchToSavedTenantSession(sessionId);
      if (!mounted) return;
      if (!ok) {
        final message = _switchFailureMessage();
        await _loadSessions();
        if (!mounted) return;
        setState(() => _message = message);
        return;
      }
      activeShellSectionNotifier.value = 'groups';
      Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка переключения: ${_extractError(error)}');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final sessionId = (row['id'] ?? '').toString().trim();
    if (sessionId.isEmpty || sessionId == _currentSessionId) return;
    await authService.removeSavedTenantSession(sessionId);
    await _loadSessions();
  }

  Widget _sessionCard(BuildContext context, Map<String, dynamic> row) {
    final theme = Theme.of(context);
    final sessionId = (row['id'] ?? '').toString();
    final active = sessionId == _currentSessionId;
    return Card(
      color: active
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.surfaceContainerHighest,
              foregroundColor: active
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
              child: Icon(active ? Icons.check_rounded : Icons.groups_outlined),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _tenantLabel(row),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    active ? 'Текущая группа' : 'Доступна для переключения',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: active
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (active)
              Icon(Icons.check_circle_outline, color: theme.colorScheme.primary)
            else ...[
              FilledButton.tonal(
                onPressed: _switching ? null : () => _switchTo(row),
                child: const Text('Выбрать'),
              ),
              IconButton(
                tooltip: 'Убрать из списка',
                onPressed: _switching ? null : () => _remove(row),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Мои группы')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadSessions,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Переключение групп',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Добавьте группу по приглашению или выберите уже доступную.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _inviteCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Код или ссылка приглашения',
                            border: OutlineInputBorder(),
                          ),
                          controller: _inviteCtrl,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _passwordCtrl,
                        obscureText: true,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'Пароль аккаунта',
                            border: OutlineInputBorder(),
                          ),
                          controller: _passwordCtrl,
                        ),
                      ),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _switchAfterJoin,
                        onChanged: _joining
                            ? null
                            : (value) => setState(
                                () => _switchAfterJoin = value == true,
                              ),
                        title: const Text('Сразу перейти в эту группу'),
                        subtitle: const Text(
                          'Если выключено, группа появится в списке ниже.',
                        ),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _joining ? null : _addGroupByInvite,
                          icon: _joining
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.group_add_outlined),
                          label: Text(
                            _joining
                                ? 'Добавление...'
                                : (_switchAfterJoin
                                      ? 'Добавить и перейти'
                                      : 'Добавить группу'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_message.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _message.toLowerCase().startsWith('ошибка')
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                'Доступные группы',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_sessions.isEmpty)
                Text(
                  'Пока доступна только текущая группа.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                ..._sessions.map((row) => _sessionCard(context, row)),
            ],
          ),
        ),
      ),
    );
  }
}
