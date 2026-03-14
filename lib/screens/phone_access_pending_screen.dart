import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../main.dart';

class PhoneAccessPendingScreen extends StatefulWidget {
  const PhoneAccessPendingScreen({super.key});

  @override
  State<PhoneAccessPendingScreen> createState() =>
      _PhoneAccessPendingScreenState();
}

class _PhoneAccessPendingScreenState extends State<PhoneAccessPendingScreen> {
  Timer? _pollTimer;
  bool _loading = true;
  bool _busy = false;
  String _state = 'pending';
  String _message = 'Ожидается решение первого владельца номера';
  String _ownerName = '';

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshStatus(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _logout() async {
    try {
      await authService.clearToken();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (route) => false);
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    if (_busy) return;
    _busy = true;
    if (!silent && mounted) {
      setState(() => _loading = true);
    }
    try {
      final resp = await authService.dio.get('/api/auth/phone-access/status');
      final root = (resp.data is Map)
          ? Map<String, dynamic>.from(resp.data as Map)
          : const <String, dynamic>{};
      final data = (root['data'] is Map)
          ? Map<String, dynamic>.from(root['data'] as Map)
          : const <String, dynamic>{};
      final nextState = (data['state'] ?? 'none').toString().trim();
      final nextMessage = (data['message'] ?? '').toString().trim();
      final nextOwner = (data['owner_name'] ?? '').toString().trim();

      if (!mounted) return;
      if (nextState == 'approved' || nextState == 'none') {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/main', (route) => false);
        return;
      }

      setState(() {
        _state = nextState.isEmpty ? 'pending' : nextState;
        _message = nextMessage.isEmpty
            ? 'Ожидается решение первого владельца номера'
            : nextMessage;
        _ownerName = nextOwner;
      });
    } on DioException catch (e) {
      final responseData = e.response?.data;
      final body = responseData is Map
          ? Map<String, dynamic>.from(responseData)
          : const <String, dynamic>{};
      final err = (body['error'] ?? e.message ?? 'Ошибка запроса')
          .toString()
          .trim();
      if (!mounted) return;
      setState(() {
        _message = err.isEmpty ? _message : err;
      });
    } catch (_) {
      // ignore
    } finally {
      _busy = false;
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = _state == 'pending';
    final rejected = _state == 'rejected';
    final title = rejected
        ? 'Запрос отклонён'
        : waiting
        ? 'Ожидание разрешения'
        : 'Проверка доступа';

    return Scaffold(
      appBar: AppBar(title: const Text('Подтверждение номера')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(_message),
                    if (_ownerName.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Владелец номера: $_ownerName',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (_loading) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(minHeight: 3),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading ? null : _refreshStatus,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Проверить снова'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _loading ? null : _logout,
                            icon: const Icon(Icons.logout),
                            label: const Text('Выйти'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
