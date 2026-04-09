import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../src/utils/media_url.dart';
import '../utils/date_time_utils.dart';

class _PromotionDestinationOption {
  const _PromotionDestinationOption({
    required this.id,
    required this.label,
    required this.description,
    required this.deepLink,
    this.requiresManualPath = false,
  });

  final String id;
  final String label;
  final String description;
  final String deepLink;
  final bool requiresManualPath;
}

class AdminPromotionCenterScreen extends StatefulWidget {
  const AdminPromotionCenterScreen({super.key});

  @override
  State<AdminPromotionCenterScreen> createState() =>
      _AdminPromotionCenterScreenState();
}

class _AdminPromotionCenterScreenState
    extends State<AdminPromotionCenterScreen> {
  static const List<_PromotionDestinationOption> _destinationOptions = [
    _PromotionDestinationOption(
      id: 'home',
      label: 'Главный экран',
      description: 'Откроет клиенту основной экран с чатами.',
      deepLink: '/home',
    ),
    _PromotionDestinationOption(
      id: 'cart',
      label: 'Корзина',
      description: 'Откроет корзину клиента.',
      deepLink: '/cart',
    ),
    _PromotionDestinationOption(
      id: 'profile',
      label: 'Профиль',
      description: 'Откроет экран профиля клиента.',
      deepLink: '/profile',
    ),
    _PromotionDestinationOption(
      id: 'settings',
      label: 'Настройки',
      description: 'Откроет настройки приложения.',
      deepLink: '/settings',
    ),
    _PromotionDestinationOption(
      id: 'support',
      label: 'Поддержка',
      description: 'Переведёт в раздел переписки с поддержкой.',
      deepLink: '/support',
    ),
    _PromotionDestinationOption(
      id: 'delivery',
      label: 'Доставка',
      description: 'Переведёт в переписки по доставке.',
      deepLink: '/delivery',
    ),
    _PromotionDestinationOption(
      id: 'update',
      label: 'Обновление приложения',
      description: 'Откроет раздел, где можно проверить обновление.',
      deepLink: '/update',
    ),
    _PromotionDestinationOption(
      id: 'custom',
      label: 'Свой переход',
      description: 'Если нужен особый путь внутри приложения.',
      deepLink: '',
      requiresManualPath: true,
    ),
    _PromotionDestinationOption(
      id: 'none',
      label: 'Без перехода',
      description: 'Акция просто покажется без дополнительного открытия экрана.',
      deepLink: '',
    ),
  ];

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final TextEditingController _customLinkCtrl = TextEditingController();

  bool _loading = true;
  bool _sending = false;
  bool _imageUploading = false;
  String _message = '';
  String _selectedDestinationId = 'home';
  String _uploadedImageUrl = '';
  List<Map<String, dynamic>> _campaigns = const [];

  bool get _isAdminBaseRole {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'admin';
  }

  _PromotionDestinationOption get _selectedDestination {
    return _destinationOptions.firstWhere(
      (item) => item.id == _selectedDestinationId,
      orElse: () => _destinationOptions.first,
    );
  }

  String get _resolvedDeepLink {
    final selected = _selectedDestination;
    if (!selected.requiresManualPath) {
      return selected.deepLink;
    }
    return _customLinkCtrl.text.trim();
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
    _customLinkCtrl.dispose();
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
          _message = 'Раздел промо-кампаний доступен только администратору.';
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

  Future<void> _pickAndUploadPromotionImage() async {
    if (_imageUploading) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (picked == null || picked.files.isEmpty) return;
    final pickedFile = picked.files.single;

    setState(() {
      _imageUploading = true;
      _message = '';
    });

    try {
      FormData form;
      if (kIsWeb) {
        final bytes = pickedFile.bytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Не удалось прочитать выбранный файл');
        }
        final fileName = pickedFile.name.trim().isNotEmpty
            ? pickedFile.name.trim()
            : 'promo-image.jpg';
        form = FormData.fromMap({
          'image': MultipartFile.fromBytes(bytes, filename: fileName),
        });
      } else {
        final path = pickedFile.path;
        if (path == null || path.isEmpty) {
          throw Exception('Не удалось получить путь к файлу');
        }
        final fileName = pickedFile.name.trim().isNotEmpty
            ? pickedFile.name.trim()
            : 'promo-image.jpg';
        form = FormData.fromMap({
          'image': await MultipartFile.fromFile(path, filename: fileName),
        });
      }

      final response = await authService.dio.post(
        '/api/admin/notifications/promotions/image',
        data: form,
      );
      final root = response.data;
      final nextUrl = root is Map
          ? ((root['data'] is Map ? root['data']['image_url'] : null) ?? '')
                .toString()
                .trim()
          : '';
      if (nextUrl.isEmpty) {
        throw Exception('Сервер не вернул адрес картинки');
      }
      if (!mounted) return;
      setState(() {
        _uploadedImageUrl = nextUrl;
      });
      showGlobalAppNotice(
        'Картинка загружена и прикреплена к акции.',
        title: 'Промо',
        tone: AppNoticeTone.success,
      );
    } catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        _extractDioMessage(error),
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _imageUploading = false;
        });
      } else {
        _imageUploading = false;
      }
    }
  }

  Future<void> _sendPromotion() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    final deepLink = _resolvedDeepLink;
    if (title.isEmpty || body.isEmpty) {
      showAppNotice(
        context,
        'Нужны и заголовок, и текст рассылки',
        tone: AppNoticeTone.warning,
      );
      return;
    }
    if (_selectedDestination.requiresManualPath && deepLink.isEmpty) {
      showAppNotice(
        context,
        'Укажи, какой экран нужно открыть после нажатия на акцию.',
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
          'deep_link': deepLink,
          if (_uploadedImageUrl.trim().isNotEmpty)
            'media': <String, dynamic>{'image_url': _uploadedImageUrl.trim()},
        },
      );
      _titleCtrl.clear();
      _bodyCtrl.clear();
      _customLinkCtrl.clear();
      _uploadedImageUrl = '';
      _selectedDestinationId = 'home';
      if (!mounted) return;
      showGlobalAppNotice(
        'Промо-кампания поставлена в отправку по opt-in клиентам.',
        title: 'Промо-рассылка',
        tone: AppNoticeTone.success,
      );
      await _loadCampaigns();
      if (!mounted) return;
      setState(() {});
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

  Widget _buildDestinationPicker() {
    final selected = _selectedDestination;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _selectedDestinationId,
          decoration: const InputDecoration(
            labelText: 'Куда перевести клиента после нажатия',
            border: OutlineInputBorder(),
          ),
          items: _destinationOptions
              .map(
                (option) => DropdownMenuItem<String>(
                  value: option.id,
                  child: Text(option.label),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _selectedDestinationId = value;
            });
          },
        ),
        const SizedBox(height: 8),
        Text(
          selected.description,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (selected.requiresManualPath) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _customLinkCtrl,
            decoration: const InputDecoration(
              labelText: 'Свой путь внутри приложения',
              hintText: '/support, /profile, /cart',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildImagePicker() {
    final resolvedImage = _uploadedImageUrl.trim().isEmpty
        ? null
        : resolveMediaUrl(
            _uploadedImageUrl.trim(),
            apiBaseUrl: authService.dio.options.baseUrl,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Картинка для акции',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _imageUploading ? null : _pickAndUploadPromotionImage,
              icon: _imageUploading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_outlined),
              label: Text(
                resolvedImage == null ? 'Выбрать с устройства' : 'Заменить',
              ),
            ),
          ],
        ),
        Text(
          'Можно выбрать баннер или любую картинку прямо с устройства.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (resolvedImage != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                resolvedImage,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_not_supported_outlined),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _imageUploading
                  ? null
                  : () {
                      setState(() {
                        _uploadedImageUrl = '';
                      });
                    },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Убрать картинку'),
            ),
          ),
        ],
      ],
    );
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
              'Реальная промо-рассылка идёт только по клиентам вашего tenant, у которых включены акции и промо.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Заголовок акции',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _bodyCtrl,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Текст акции',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            _buildDestinationPicker(),
            const SizedBox(height: 12),
            _buildImagePicker(),
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
              label: const Text('Отправить акцию'),
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
