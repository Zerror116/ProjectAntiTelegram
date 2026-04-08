import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../src/utils/media_url.dart';
import '../utils/date_time_utils.dart';

class AdminPromotionCenterScreen extends StatefulWidget {
  const AdminPromotionCenterScreen({super.key});

  @override
  State<AdminPromotionCenterScreen> createState() =>
      _AdminPromotionCenterScreenState();
}

class _AdminPromotionCenterScreenState
    extends State<AdminPromotionCenterScreen> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final TextEditingController _linkCtrl = TextEditingController();
  final TextEditingController _imageCtrl = TextEditingController();

  bool _loading = true;
  bool _sending = false;
  String _message = '';
  List<Map<String, dynamic>> _campaigns = const [];

  bool get _isAdminBaseRole {
    final role = (authService.currentUser?.role ?? '').toLowerCase().trim();
    return role == 'admin';
  }

  @override
  void initState() {
    super.initState();
    _loadCampaigns();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _linkCtrl.dispose();
    _imageCtrl.dispose();
    super.dispose();
  }

  String _extractDioMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        return (data['error'] ?? data['message'] ?? 'Ошибка сервера')
            .toString();
      }
      return error.message ?? 'Ошибка сервера';
    }
    return error.toString();
  }

  Future<void> _loadCampaigns() async {
    if (!_isAdminBaseRole) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = 'Раздел promo-кампаний доступен только администратору.';
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _message = '';
    });
    try {
      final response = await authService.dio.get(
        '/api/admin/notifications/promotions',
      );
      final root = response.data;
      final rows = root is Map && root['ok'] == true && root['data'] is List
          ? (root['data'] as List)
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList(growable: false)
          : const <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _campaigns = rows;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = _extractDioMessage(error);
      });
    } finally {
      if (!mounted) {
        _loading = false;
      } else {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _sendPromotion() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      showAppNotice(
        context,
        'Нужны и заголовок, и текст рассылки',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    setState(() {
      _sending = true;
      _message = '';
    });
    try {
      await authService.dio.post(
        '/api/admin/notifications/promotions',
        data: <String, dynamic>{
          'title': title,
          'body': body,
          'deep_link': _linkCtrl.text.trim().isEmpty
              ? '/'
              : _linkCtrl.text.trim(),
          if (_imageCtrl.text.trim().isNotEmpty)
            'media': <String, dynamic>{'image_url': _imageCtrl.text.trim()},
        },
      );
      _titleCtrl.clear();
      _bodyCtrl.clear();
      _linkCtrl.clear();
      _imageCtrl.clear();
      if (!mounted) return;
      showGlobalAppNotice(
        'Промо-кампания поставлена в отправку по opt-in клиентам.',
        title: 'Промо-рассылка',
        tone: AppNoticeTone.success,
      );
      await _loadCampaigns();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = _extractDioMessage(error);
      });
    } finally {
      if (!mounted) {
        _sending = false;
      } else {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Color _statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case 'sent':
        return scheme.primaryContainer;
      case 'error':
        return scheme.errorContainer;
      default:
        return scheme.surfaceContainerHighest;
    }
  }

  String _statusLabel(String raw) {
    switch (raw.toLowerCase().trim()) {
      case 'sent':
        return 'Отправлено';
      case 'error':
        return 'Ошибка';
      case 'draft':
      default:
        return 'Черновик';
    }
  }

  Widget _buildComposer() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Промо-рассылка администратора',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Реальная промо-рассылка идёт только по opt-in клиентам вашего tenant.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Заголовок',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _bodyCtrl,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Текст',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _linkCtrl,
              decoration: const InputDecoration(
                labelText: 'Deep link внутри приложения',
                hintText: '/chat?chatId=...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _imageCtrl,
              decoration: const InputDecoration(
                labelText: 'URL картинки (необязательно)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sending ? null : _sendPromotion,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.campaign_outlined),
              label: const Text('Отправить promo'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCampaignCard(Map<String, dynamic> item) {
    final theme = Theme.of(context);
    final status = (item['status'] ?? 'draft').toString().trim().toLowerCase();
    final media = item['media'] is Map
        ? Map<String, dynamic>.from(item['media'])
        : const <String, dynamic>{};
    final imageUrl = (media['image_url'] ?? '').toString().trim();
    final resolvedImage = imageUrl.isEmpty
        ? null
        : resolveMediaUrl(
            imageUrl,
            apiBaseUrl: authService.dio.options.baseUrl,
          );
    final errorMessage = (item['error_message'] ?? '').toString().trim();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (item['title'] ?? 'Промо-кампания').toString(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(
                            label: Text(_statusLabel(status)),
                            backgroundColor: _statusColor(context, status),
                          ),
                          Text(
                            formatDateTimeValue(item['created_at']),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Text(
                  'Получателей: ${(item['sent_count'] ?? 0).toString()}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text((item['body'] ?? '').toString().trim()),
            if (resolvedImage != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    resolvedImage,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
                ),
              ),
            ],
            if (errorMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAdminBaseRole) {
      return Scaffold(
        appBar: AppBar(title: const Text('Промо-рассылки')),
        body: const SafeArea(
          child: Center(
            child: Text(
              'Раздел промо-кампаний доступен только администратору.',
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Промо-рассылки')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadCampaigns,
          child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            children: [
              if (_loading) const LinearProgressIndicator(),
              if (_message.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    _message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _buildComposer(),
              const SizedBox(height: 12),
              Text(
                'Мои promo-кампании',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              if (_campaigns.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Пока нет отправленных или созданных promo-кампаний.',
                    ),
                  ),
                )
              else
                ..._campaigns.map(_buildCampaignCard),
            ],
          ),
        ),
      ),
    );
  }
}
