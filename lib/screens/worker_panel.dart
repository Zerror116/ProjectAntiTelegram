// lib/screens/worker_panel.dart
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';

class WorkerPanel extends StatefulWidget {
  const WorkerPanel({super.key});

  @override
  State<WorkerPanel> createState() => _WorkerPanelState();
}

class _WorkerPanelState extends State<WorkerPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  StreamSubscription? _chatEventsSub;
  Timer? _ownPostsRefreshDebounce;

  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController(text: '1');
  final _searchCtrl = TextEditingController();
  final _revisionPercentCtrl = TextEditingController(text: '-10');

  final ImagePicker _imagePicker = ImagePicker();
  XFile? _pickedImage;
  String? _existingImageUrl;
  bool _removeImageOnSubmit = false;

  bool get _cameraSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  bool get _preferFilePickerForGallery {
    if (kIsWeb) return true;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  bool _loadingChannels = true;
  bool _loadingOwnPosts = false;
  bool _posting = false;
  bool _searching = false;
  bool _savingOwnPost = false;
  bool _loadingRevisionDates = false;
  bool _loadingRevisionPosts = false;
  bool _runningRevision = false;
  bool _autoHideOldRevisionPosts = true;
  String _message = '';

  double _toDoubleValue(dynamic value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(
      value?.toString().replaceAll(',', '.') ?? '',
    );
    return parsed ?? fallback;
  }

  int _toIntValue(dynamic value, [int fallback = 0]) {
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed ?? fallback;
  }

  List<Map<String, dynamic>> _channels = [];
  String? _selectedChannelId;
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _ownQueuedPosts = [];
  List<Map<String, dynamic>> _revisionDates = [];
  List<Map<String, dynamic>> _revisionPosts = [];
  Set<String> _selectedRevisionDates = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadChannels();
    _loadOwnQueuedPosts();
    _loadRevisionDates();
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if (type == 'chat:created' || type == 'chat:deleted') {
        _loadChannels();
      }
      if (type == 'chat:updated') {
        _ownPostsRefreshDebounce?.cancel();
        _ownPostsRefreshDebounce = Timer(
          const Duration(milliseconds: 650),
          () async {
            await _loadOwnQueuedPosts();
            await _loadRevisionPosts();
          },
        );
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    _ownPostsRefreshDebounce?.cancel();
    _tabController.dispose();
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    _quantityCtrl.dispose();
    _searchCtrl.dispose();
    _revisionPercentCtrl.dispose();
    super.dispose();
  }

  String? _resolveImageUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    final base = authService.dio.options.baseUrl.trim();
    if (base.isEmpty) {
      return value;
    }
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  String? _normalizedImageUrlFromForm() {
    if (_removeImageOnSubmit) return null;
    final normalized = _existingImageUrl?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }

  void _resetProductForm() {
    _titleCtrl.clear();
    _descriptionCtrl.clear();
    _priceCtrl.clear();
    _quantityCtrl.text = '1';
    _pickedImage = null;
    _existingImageUrl = null;
    _removeImageOnSubmit = false;
  }

  Color _messageColor(ThemeData theme) {
    final normalized = _message.toLowerCase();
    final isError =
        normalized.contains('ошибка') ||
        normalized.contains('не удалось') ||
        normalized.contains('добавьте') ||
        normalized.contains('введите') ||
        normalized.contains('выберите');
    return isError ? theme.colorScheme.error : theme.colorScheme.primary;
  }

  int _countLetterRunes(String text) {
    var count = 0;
    for (final rune in text.runes) {
      final isLatin =
          (rune >= 0x0041 && rune <= 0x005A) ||
          (rune >= 0x0061 && rune <= 0x007A) ||
          (rune >= 0x00C0 && rune <= 0x024F);
      final isCyrillic =
          (rune >= 0x0400 && rune <= 0x04FF) ||
          (rune >= 0x0500 && rune <= 0x052F);
      final isArmenian = rune >= 0x0530 && rune <= 0x058F;
      final isGreek = rune >= 0x0370 && rune <= 0x03FF;
      final isGeorgian =
          (rune >= 0x10A0 && rune <= 0x10FF) ||
          (rune >= 0x1C90 && rune <= 0x1CBF);
      final isHebrew = rune >= 0x0590 && rune <= 0x05FF;
      final isArabic =
          (rune >= 0x0600 && rune <= 0x06FF) ||
          (rune >= 0x0750 && rune <= 0x077F) ||
          (rune >= 0x08A0 && rune <= 0x08FF);
      if (isLatin ||
          isCyrillic ||
          isArmenian ||
          isGreek ||
          isGeorgian ||
          isHebrew ||
          isArabic) {
        count += 1;
      }
    }
    return count;
  }

  String? _validateProductFields({
    required String title,
    required String description,
    required double? price,
    required int quantity,
    required bool hasImage,
  }) {
    if (title.isEmpty) {
      return 'Введите название товара';
    }
    if (!hasImage) {
      return 'Добавьте фото товара';
    }
    if (description.isEmpty) {
      return 'Введите описание товара';
    }
    if (_countLetterRunes(description) < 2) {
      return 'Описание должно содержать минимум 2 буквы, а не только цифры';
    }
    if (price == null || price <= 0) {
      return 'Цена должна быть больше нуля';
    }
    if (quantity <= 0) {
      return 'Количество должно быть больше нуля';
    }
    return null;
  }

  Future<void> _openImagePickerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_cameraSupported)
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Сделать фото'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImageWithDelay(ImageSource.camera);
                  },
                )
              else
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Камера недоступна на этом устройстве'),
                  subtitle: Text(
                    'На macOS/Windows/Linux выберите фото из файлов',
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(
                  _preferFilePickerForGallery
                      ? 'Выбрать фото с устройства'
                      : 'Выбрать из галереи',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageWithDelay(ImageSource.gallery);
                },
              ),
              if (_pickedImage != null ||
                  (_existingImageUrl?.isNotEmpty ?? false))
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Удалить фото'),
                  onTap: () {
                    Navigator.pop(context);
                    _clearSelectedImage();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickImageWithDelay(ImageSource source) async {
    // On desktop/macOS opening picker right after bottomsheet close may no-op.
    await Future.delayed(const Duration(milliseconds: 120));
    await _pickImage(source);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      var effectiveSource = source;
      if (source == ImageSource.camera && !_cameraSupported) {
        if (mounted) {
          setState(
            () => _message =
                'Камера недоступна на этом устройстве. Выберите фото из файлов.',
          );
        }
        effectiveSource = ImageSource.gallery;
      }

      XFile? picked;
      if (effectiveSource == ImageSource.gallery &&
          _preferFilePickerForGallery) {
        // On desktop first try ImagePicker, then fallback to FilePicker.
        try {
          picked = await _imagePicker.pickImage(
            source: ImageSource.gallery,
            imageQuality: 88,
            maxWidth: 2200,
          );
        } catch (_) {}

        try {
          if (picked == null) {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.image,
              allowMultiple: false,
              withData: false,
            );
            final path = result?.files.single.path;
            if (path != null && path.isNotEmpty) {
              picked = XFile(path);
            }
          }
        } catch (_) {
          // Ignore and handle below.
        }
      } else {
        picked = await _imagePicker.pickImage(
          source: effectiveSource,
          imageQuality: 88,
          maxWidth: 2200,
        );
      }

      if (picked == null) {
        if (!mounted) return;
        setState(() {
          _message = 'Фото не выбрано';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _pickedImage = picked;
        _removeImageOnSubmit = false;
        _message = '';
      });
      showAppNotice(
        context,
        'Фото добавлено',
        tone: AppNoticeTone.success,
        duration: const Duration(milliseconds: 900),
      );
      await playAppSound(AppUiSound.tap);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось выбрать фото: $e');
    }
  }

  void _clearSelectedImage() {
    setState(() {
      _pickedImage = null;
      _existingImageUrl = null;
      _removeImageOnSubmit = true;
    });
  }

  Future<FormData> _buildCreateProductPayload({
    required String title,
    required String description,
    required double price,
    required int quantity,
  }) async {
    final map = <String, dynamic>{
      'title': title,
      'description': description,
      'price': price,
      'quantity': quantity,
    };

    if (_pickedImage != null) {
      map['image'] = await MultipartFile.fromFile(
        _pickedImage!.path,
        filename: _pickedImage!.name,
      );
    } else {
      final imageUrl = _normalizedImageUrlFromForm();
      if (imageUrl != null) {
        map['image_url'] = imageUrl;
      }
    }

    return FormData.fromMap(map);
  }

  Future<FormData> _buildRequeuePayload({
    required Map<String, dynamic> product,
    required String channelId,
    required String title,
    required String description,
    required double price,
    required int quantity,
  }) async {
    final map = <String, dynamic>{
      'channel_id': channelId,
      'title': title,
      'description': description,
      'price': price,
      'quantity': quantity,
    };

    if (_pickedImage != null) {
      map['image'] = await MultipartFile.fromFile(
        _pickedImage!.path,
        filename: _pickedImage!.name,
      );
    } else if (_removeImageOnSubmit) {
      map['image_url'] = '';
    } else {
      final imageUrl = _normalizedImageUrlFromForm();
      if (imageUrl != null) {
        map['image_url'] = imageUrl;
      } else if ((product['image_url'] ?? '').toString().trim().isNotEmpty) {
        map['image_url'] = (product['image_url'] ?? '').toString().trim();
      }
    }

    return FormData.fromMap(map);
  }

  Future<void> _loadChannels() async {
    setState(() {
      _loadingChannels = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get('/api/worker/channels');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final channels = List<Map<String, dynamic>>.from(data['data']);
        setState(() {
          _channels = channels;
          _selectedChannelId = channels.isNotEmpty
              ? channels.first['id']?.toString()
              : null;
        });
      } else {
        setState(() => _message = 'Не удалось загрузить каналы');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка загрузки каналов: $e');
    } finally {
      if (mounted) setState(() => _loadingChannels = false);
    }
  }

  Future<void> _loadOwnQueuedPosts() async {
    if (mounted) {
      setState(() => _loadingOwnPosts = true);
    }
    try {
      final resp = await authService.dio.get('/api/worker/queue/mine');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (!mounted) return;
        setState(() {
          _ownQueuedPosts = List<Map<String, dynamic>>.from(data['data']);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка загрузки своих постов: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingOwnPosts = false);
      }
    }
  }

  Future<void> _loadRevisionDates() async {
    if (mounted) {
      setState(() => _loadingRevisionDates = true);
    }
    try {
      final resp = await authService.dio.get('/api/worker/revision/dates');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final dates = List<Map<String, dynamic>>.from(data['data']);
        final nextSelected = dates
            .map((e) => (e['day'] ?? '').toString())
            .where((e) => e.isNotEmpty)
            .take(2)
            .toSet();
        if (!mounted) return;
        setState(() {
          _revisionDates = dates;
          _selectedRevisionDates = nextSelected;
        });
        await _loadRevisionPosts();
      } else {
        if (!mounted) return;
        setState(() {
          _revisionDates = [];
          _selectedRevisionDates = {};
          _revisionPosts = [];
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка загрузки дат ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingRevisionDates = false);
      }
    }
  }

  Future<void> _loadRevisionPosts() async {
    if (mounted) {
      setState(() => _loadingRevisionPosts = true);
    }
    try {
      final selected = _selectedRevisionDates.toList()..sort();
      final resp = await authService.dio.get(
        '/api/worker/revision/posts',
        queryParameters: {if (selected.isNotEmpty) 'dates': selected.join(',')},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        final posts = payload['posts'] is List
            ? List<Map<String, dynamic>>.from(payload['posts'])
            : <Map<String, dynamic>>[];
        final dates = payload['dates'] is List
            ? (payload['dates'] as List)
                  .map((e) => e?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .toSet()
            : _selectedRevisionDates;
        if (!mounted) return;
        setState(() {
          _revisionPosts = posts;
          _selectedRevisionDates = dates;
        });
      } else {
        if (!mounted) return;
        setState(() => _revisionPosts = []);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка загрузки постов ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingRevisionPosts = false);
      }
    }
  }

  Future<void> _toggleRevisionDate(String day) async {
    final next = Set<String>.from(_selectedRevisionDates);
    if (next.contains(day)) {
      if (next.length == 1) return;
      next.remove(day);
    } else {
      if (next.length >= 2) return;
      next.add(day);
    }
    if (!mounted) return;
    setState(() => _selectedRevisionDates = next);
    await _loadRevisionPosts();
  }

  Future<void> _runAutoRevision() async {
    final rawPercent = _revisionPercentCtrl.text.trim().replaceAll(',', '.');
    final percent = double.tryParse(rawPercent);
    if (percent == null) {
      setState(() => _message = 'Введите корректный процент ревизии');
      return;
    }
    if (_selectedRevisionDates.isEmpty) {
      setState(() => _message = 'Выберите хотя бы одну дату ревизии');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Авто-ревизия'),
        content: Text(
          'Изменить цены на $rawPercent% и '
          '${_autoHideOldRevisionPosts ? 'скрыть старые версии постов' : 'оставить старые версии'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Запустить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (mounted) {
      setState(() => _runningRevision = true);
    }
    try {
      final resp = await authService.dio.post(
        '/api/worker/revision/auto',
        data: {
          'dates': _selectedRevisionDates.toList(),
          'percent': percent,
          'hide_old_versions': _autoHideOldRevisionPosts,
        },
      );
      final data = resp.data;
      final updatedCount = _toIntValue(
        data is Map && data['data'] is Map
            ? (data['data'] as Map)['updated_count']
            : null,
      );
      final queuedCount = _toIntValue(
        data is Map && data['data'] is Map
            ? (data['data'] as Map)['queued_count']
            : updatedCount,
      );
      final reusedCount = _toIntValue(
        data is Map && data['data'] is Map
            ? (data['data'] as Map)['reused_pending_count']
            : null,
      );
      if (!mounted) return;
      setState(
        () => _message =
            'Авто-ревизия: в очередь поставлено $queuedCount '
            '(обновлено существующих в очереди: $reusedCount). '
            'В канал уйдёт только после кнопки админа "Отправить посты на канал".',
      );
      showAppNotice(
        context,
        'Авто-ревизия поставлена в очередь',
        tone: AppNoticeTone.success,
      );
      await playAppSound(AppUiSound.success);
      await _loadRevisionPosts();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка авто-ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _runningRevision = false);
      }
    }
  }

  Future<void> _manualRevisionEdit(Map<String, dynamic> post) async {
    final titleCtrl = TextEditingController(
      text: (post['title'] ?? '').toString(),
    );
    final descriptionCtrl = TextEditingController(
      text: (post['description'] ?? '').toString(),
    );
    final priceCtrl = TextEditingController(
      text: _toDoubleValue(post['price']).toStringAsFixed(0),
    );
    final quantityCtrl = TextEditingController(
      text: _toIntValue(post['quantity'], 1).toString(),
    );

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ручная ревизия товара'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Название',
                    border: OutlineInputBorder(),
                  ),
                  controller: titleCtrl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Описание',
                    border: OutlineInputBorder(),
                  ),
                  controller: descriptionCtrl,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Цена',
                          border: OutlineInputBorder(),
                        ),
                        controller: priceCtrl,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: quantityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Кол-во',
                          border: OutlineInputBorder(),
                        ),
                        controller: quantityCtrl,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final title = titleCtrl.text.trim();
    final description = descriptionCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim().replaceAll(',', '.'));
    final quantity = int.tryParse(quantityCtrl.text.trim()) ?? 0;
    final hasImage = (post['image_url'] ?? '').toString().trim().isNotEmpty;
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      if (!mounted) return;
      setState(() => _message = validationError);
      return;
    }

    if (mounted) {
      setState(() => _runningRevision = true);
    }
    try {
      await authService.dio.post(
        '/api/worker/revision/manual',
        data: {
          'entries': [
            {
              'product_id': (post['product_id'] ?? '').toString(),
              'message_id': (post['message_id'] ?? '').toString(),
              'title': title,
              'description': description,
              'price': price,
              'quantity': quantity,
              'image_url': (post['image_url'] ?? '').toString(),
            },
          ],
        },
      );
      if (!mounted) return;
      setState(() => _message = 'Ревизия товара сохранена');
      showAppNotice(
        context,
        'Изменения ревизии сохранены',
        tone: AppNoticeTone.success,
      );
      await playAppSound(AppUiSound.success);
      await _loadRevisionPosts();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка ручной ревизии: $e');
    } finally {
      if (mounted) {
        setState(() => _runningRevision = false);
      }
    }
  }

  Future<void> _queueProduct() async {
    final channelId = _selectedChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _message = 'Выберите канал для публикации');
      return;
    }

    final title = _titleCtrl.text.trim();
    final description = _descriptionCtrl.text.trim();
    final priceText = _priceCtrl.text.trim().replaceAll(',', '.');
    final qtyText = _quantityCtrl.text.trim();
    final hasImage =
        _pickedImage != null ||
        ((_existingImageUrl?.trim().isNotEmpty ?? false) &&
            !_removeImageOnSubmit);

    if (title.isEmpty) {
      setState(() => _message = 'Введите название товара');
      return;
    }
    final price = double.tryParse(priceText);
    final quantity = int.tryParse(qtyText) ?? 1;
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      setState(() => _message = validationError);
      return;
    }

    setState(() {
      _posting = true;
      _message = '';
    });

    try {
      final payload = await _buildCreateProductPayload(
        title: title,
        description: description,
        price: price!,
        quantity: quantity,
      );

      final resp = await authService.dio.post(
        '/api/worker/channels/$channelId/posts',
        data: payload,
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        final data = resp.data;
        String? queueId;
        String? productCode;
        if (data is Map && data['data'] is Map) {
          final dataMap = Map<String, dynamic>.from(data['data']);
          final queue = dataMap['queue'];
          if (queue is Map) {
            queueId = queue['id']?.toString();
          }
          final product = dataMap['product'];
          if (product is Map) {
            productCode = product['product_code']?.toString();
          }
        }
        setState(() {
          if (productCode != null && productCode.isNotEmpty) {
            _message = 'Товар отправлен в очередь. ID товара: $productCode';
          } else if (queueId != null) {
            _message = 'Товар отправлен в очередь. ID заявки: $queueId';
          } else {
            _message = 'Товар отправлен в очередь';
          }
        });
        _resetProductForm();
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productCode != null && productCode.isNotEmpty
                ? 'Товар отправлен в очередь. ID: $productCode'
                : 'Товар отправлен в очередь',
            tone: AppNoticeTone.success,
            duration: const Duration(milliseconds: 1400),
          );
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось отправить товар в очередь');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка отправки: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _searchOldProducts() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() {
      _searching = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.get(
        '/api/worker/products/search',
        queryParameters: {'q': q},
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        setState(
          () => _searchResults = List<Map<String, dynamic>>.from(data['data']),
        );
      } else {
        setState(() => _message = 'Не удалось выполнить поиск');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка поиска: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _fillFormFromProduct(Map<String, dynamic> product) {
    _titleCtrl.text = (product['title'] ?? '').toString();
    _descriptionCtrl.text = (product['description'] ?? '').toString();
    _priceCtrl.text = (product['price'] ?? '').toString();
    _quantityCtrl.text = ((product['quantity'] ?? 1)).toString();
    setState(() {
      _pickedImage = null;
      _existingImageUrl = (product['image_url'] ?? '').toString();
      _removeImageOnSubmit = false;
      _message = 'Данные товара подставлены. Проверьте и отправьте в очередь.';
    });
    _tabController.animateTo(0);
  }

  Future<void> _requeueProduct(Map<String, dynamic> product) async {
    final channelId = _selectedChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _message = 'Сначала выберите канал');
      return;
    }
    final productId = product['id']?.toString();
    if (productId == null || productId.isEmpty) return;

    final title = _titleCtrl.text.trim().isNotEmpty
        ? _titleCtrl.text.trim()
        : (product['title'] ?? '').toString();
    final description = _descriptionCtrl.text.trim().isNotEmpty
        ? _descriptionCtrl.text.trim()
        : (product['description'] ?? '').toString();

    final rawPriceInput = _priceCtrl.text.trim().replaceAll(',', '.');
    final editedPrice = rawPriceInput.isNotEmpty
        ? double.tryParse(rawPriceInput)
        : null;
    if (rawPriceInput.isNotEmpty && editedPrice == null) {
      setState(() => _message = 'Введите корректную цену');
      return;
    }
    final fallbackPrice = _toDoubleValue(product['price'], 0);
    final price = editedPrice ?? fallbackPrice;

    final rawQtyInput = _quantityCtrl.text.trim();
    final editedQty = rawQtyInput.isNotEmpty ? int.tryParse(rawQtyInput) : null;
    if (rawQtyInput.isNotEmpty && (editedQty == null || editedQty <= 0)) {
      setState(() => _message = 'Количество должно быть больше нуля');
      return;
    }
    final fallbackQty = _toIntValue(product['quantity'], 1);
    final quantity = editedQty ?? fallbackQty;
    final existingImage = (product['image_url'] ?? '').toString().trim();
    final hasImage =
        _pickedImage != null ||
        ((_existingImageUrl?.trim().isNotEmpty ?? false) &&
            !_removeImageOnSubmit) ||
        (existingImage.isNotEmpty && !_removeImageOnSubmit);
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      setState(() => _message = validationError);
      return;
    }

    setState(() {
      _posting = true;
      _message = '';
    });
    try {
      final payload = await _buildRequeuePayload(
        product: product,
        channelId: channelId,
        title: title,
        description: description,
        price: price,
        quantity: quantity,
      );

      final resp = await authService.dio.post(
        '/api/worker/products/$productId/requeue',
        data: payload,
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        String? productCode;
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final body = Map<String, dynamic>.from(data['data']);
          final product = body['product'];
          if (product is Map) {
            productCode = product['product_code']?.toString();
          }
        }
        setState(() {
          _message = productCode != null && productCode.isNotEmpty
              ? 'Старый товар отправлен в очередь. ID товара: $productCode'
              : 'Старый товар отправлен в очередь повторно';
          _removeImageOnSubmit = false;
        });
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productCode != null && productCode.isNotEmpty
                ? 'Товар снова в очереди. ID: $productCode'
                : 'Товар снова отправлен в очередь',
            tone: AppNoticeTone.success,
          );
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось отправить товар в очередь');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка повторной отправки: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _quickDuplicateProduct(Map<String, dynamic> product) async {
    final channelId = _selectedChannelId;
    if (channelId == null || channelId.isEmpty) {
      setState(() => _message = 'Сначала выберите канал');
      return;
    }

    final productId = product['id']?.toString();
    if (productId == null || productId.isEmpty) {
      setState(() => _message = 'Не удалось определить товар');
      return;
    }

    final title = (product['title'] ?? '').toString().trim();
    final description = (product['description'] ?? '').toString().trim();
    final price = _toDoubleValue(product['price'], 0);
    final quantity = _toIntValue(product['quantity'], 1);
    final imageUrl = (product['image_url'] ?? '').toString().trim();

    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: imageUrl.isNotEmpty,
    );
    if (validationError != null) {
      setState(() => _message = validationError);
      return;
    }

    setState(() {
      _posting = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/worker/products/$productId/requeue',
        data: {
          'channel_id': channelId,
          'title': title,
          'description': description,
          'price': price,
          'quantity': quantity,
          'image_url': imageUrl,
        },
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        String? productCode;
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final body = Map<String, dynamic>.from(data['data']);
          final productMap = body['product'];
          if (productMap is Map) {
            productCode = productMap['product_code']?.toString();
          }
        }
        setState(() {
          _message = productCode != null && productCode.isNotEmpty
              ? 'Дубль товара отправлен. ID товара: $productCode'
              : 'Дубль товара отправлен в очередь';
        });
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productCode != null && productCode.isNotEmpty
                ? 'Дубль готов. ID: $productCode'
                : 'Товар продублирован в очередь',
            tone: AppNoticeTone.success,
          );
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось продублировать товар');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка дубля товара: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Widget _buildPhotoPicker() {
    final theme = Theme.of(context);
    final localPath = _pickedImage?.path;
    final remoteUrl = _resolveImageUrl(_existingImageUrl);
    final hasImage = localPath != null || remoteUrl != null;
    const previewWidth = 220.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Фото товара',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (hasImage)
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: previewWidth,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: localPath != null
                      ? Image.file(File(localPath), fit: BoxFit.cover)
                      : Image.network(
                          remoteUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, error, stackTrace) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: previewWidth,
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.photo_outlined,
                        size: 28,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Фото не выбрано',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _openImagePickerSheet,
                icon: const Icon(Icons.attach_file),
                label: Text(hasImage ? 'Изменить фото' : 'Добавить фото'),
              ),
            ),
            if (hasImage) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: _clearSelectedImage,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Удалить фото',
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildQueueTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_loadingChannels)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: PhoenixLoadingView(
              title: 'Загружаем каналы',
              subtitle: 'Получаем доступные каналы для публикации',
              size: 50,
            ),
          )
        else if (_channels.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Системный "Основной канал" недоступен. Проверьте сервер инициализации.',
            ),
          )
        else
          DropdownButtonFormField<String>(
            key: ValueKey<String?>(_selectedChannelId),
            initialValue: _selectedChannelId,
            decoration: const InputDecoration(
              labelText: 'Канал для публикации',
              border: OutlineInputBorder(),
            ),
            items: _channels
                .map(
                  (c) => DropdownMenuItem<String>(
                    value: c['id']?.toString(),
                    child: Text((c['title'] ?? 'Канал').toString()),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _selectedChannelId = v),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _titleCtrl,
          decoration: withInputLanguageBadge(
            const InputDecoration(
              labelText: 'Название товара',
              border: OutlineInputBorder(),
            ),
            controller: _titleCtrl,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionCtrl,
          minLines: 3,
          maxLines: 5,
          decoration: withInputLanguageBadge(
            const InputDecoration(
              labelText: 'Описание',
              border: OutlineInputBorder(),
            ),
            controller: _descriptionCtrl,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Цена',
                    border: OutlineInputBorder(),
                  ),
                  controller: _priceCtrl,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _quantityCtrl,
                keyboardType: TextInputType.number,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Кол-во',
                    border: OutlineInputBorder(),
                  ),
                  controller: _quantityCtrl,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildPhotoPicker(),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _posting ? null : _queueProduct,
            icon: _posting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send),
            label: Text(_posting ? 'Отправка...' : 'Отправить в очередь'),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Поиск старого товара по описанию',
                    border: OutlineInputBorder(),
                  ),
                  controller: _searchCtrl,
                ),
                onSubmitted: (_) => _searchOldProducts(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _searching ? null : _searchOldProducts,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_searching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: PhoenixLoadingView(
              title: 'Ищем товары',
              subtitle: 'Подбираем похожие позиции по описанию',
              size: 46,
            ),
          ),
        if (!_searching && _searchResults.isEmpty)
          const Text('Результаты появятся здесь'),
        ..._searchResults.map((p) {
          final code = p['product_code']?.toString() ?? 'без ID';
          final imageUrl = _resolveImageUrl((p['image_url'] ?? '').toString());
          return Card(
            child: ListTile(
              leading: imageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        imageUrl,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, error, stackTrace) => Container(
                          width: 52,
                          height: 52,
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.image_not_supported_outlined,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : null,
              title: Text((p['title'] ?? 'Товар').toString()),
              subtitle: Text(
                'ID: $code\n'
                'Цена: ${p['price']} RUB\n'
                '${(p['description'] ?? '').toString()}',
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'fill') {
                    _fillFormFromProduct(p);
                  } else if (v == 'requeue') {
                    _requeueProduct(p);
                  } else if (v == 'quick_requeue') {
                    _quickDuplicateProduct(p);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'quick_requeue',
                    child: Text('Быстрый дубль (1 клик)'),
                  ),
                  PopupMenuItem(
                    value: 'fill',
                    child: Text('Подставить в форму'),
                  ),
                  PopupMenuItem(
                    value: 'requeue',
                    child: Text('Сразу в очередь'),
                  ),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Быстрый дубль',
                      onPressed: _posting
                          ? null
                          : () => _quickDuplicateProduct(p),
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                    const Icon(Icons.more_vert),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _editOwnQueuedPost(Map<String, dynamic> post) async {
    final titleCtrl = TextEditingController(
      text: (post['product_title'] ?? '').toString(),
    );
    final descriptionCtrl = TextEditingController(
      text: (post['product_description'] ?? '').toString(),
    );
    final priceCtrl = TextEditingController(
      text: (post['product_price'] ?? '').toString(),
    );
    final quantityCtrl = TextEditingController(
      text: (post['product_quantity'] ?? '1').toString(),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Изменить свой пост'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Название товара',
                    border: OutlineInputBorder(),
                  ),
                  controller: titleCtrl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Описание',
                    border: OutlineInputBorder(),
                  ),
                  controller: descriptionCtrl,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Цена',
                          border: OutlineInputBorder(),
                        ),
                        controller: priceCtrl,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: quantityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: withInputLanguageBadge(
                        const InputDecoration(
                          labelText: 'Кол-во',
                          border: OutlineInputBorder(),
                        ),
                        controller: quantityCtrl,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final title = titleCtrl.text.trim();
    final description = descriptionCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim().replaceAll(',', '.'));
    final quantity = int.tryParse(quantityCtrl.text.trim()) ?? 0;
    final hasImage = ((post['product_image_url'] ?? '')
        .toString()
        .trim()
        .isNotEmpty);
    final validationError = _validateProductFields(
      title: title,
      description: description,
      price: price,
      quantity: quantity,
      hasImage: hasImage,
    );
    if (validationError != null) {
      if (!mounted) return;
      setState(() => _message = validationError);
      return;
    }

    if (mounted) {
      setState(() => _savingOwnPost = true);
    }
    try {
      await authService.dio.patch(
        '/api/worker/queue/${post['id']}',
        data: {
          'title': title,
          'description': description,
          'price': price,
          'quantity': quantity,
        },
      );
      await _loadOwnQueuedPosts();
      if (!mounted) return;
      setState(() => _message = 'Пост обновлен');
      showAppNotice(context, 'Свой пост обновлен', tone: AppNoticeTone.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Ошибка сохранения поста: $e');
    } finally {
      if (mounted) {
        setState(() => _savingOwnPost = false);
      }
    }
  }

  Widget _buildOwnPostsTab() {
    final theme = Theme.of(context);
    if (_loadingOwnPosts) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: PhoenixLoadingView(
          title: 'Загружаем ваши посты',
          subtitle: 'Собираем еще не опубликованные позиции',
          size: 46,
        ),
      );
    }
    if (_ownQueuedPosts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [Text('У вас пока нет своих постов в очереди')],
      );
    }
    return RefreshIndicator(
      onRefresh: _loadOwnQueuedPosts,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _ownQueuedPosts.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final post = _ownQueuedPosts[index];
          final imageUrl = _resolveImageUrl(
            (post['product_image_url'] ?? '').toString(),
          );
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 92,
                        height: 92,
                        child: imageUrl != null
                            ? Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.image_not_supported_outlined,
                                      ),
                                    ),
                              )
                            : Container(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: const Icon(Icons.photo_outlined),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (post['product_title'] ?? 'Товар').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            (post['product_description'] ?? '').toString(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _statChip(
                                'ID ${(post['product_code'] ?? '—').toString()}',
                              ),
                              _statChip(
                                '${_toDoubleValue(post['product_price']).toStringAsFixed(0)} RUB',
                              ),
                              _statChip(
                                'x${_toIntValue(post['product_quantity'])}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        (post['channel_title'] ?? 'Основной канал').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _savingOwnPost
                          ? null
                          : () => _editOwnQueuedPost(post),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Изменить'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRevisionTab() {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async {
        await _loadRevisionDates();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: const Text(
              'Ревизия: выберите до 2 дат публикации, затем запускайте авто-ревизию '
              'или вручную редактируйте карточки.',
            ),
          ),
          const SizedBox(height: 12),
          if (_loadingRevisionDates)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: PhoenixLoadingView(
                title: 'Загружаем даты ревизии',
                subtitle: 'Собираем последние даты публикаций',
                size: 44,
              ),
            )
          else if (_revisionDates.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Нет данных для ревизии'),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _revisionDates.map((item) {
                final day = (item['day'] ?? '').toString();
                final label = (item['label'] ?? day).toString();
                final count = _toIntValue(item['posts'], 0);
                final selected = _selectedRevisionDates.contains(day);
                return FilterChip(
                  selected: selected,
                  onSelected: (_) => _toggleRevisionDate(day),
                  label: Text('$label • $count'),
                );
              }).toList(),
            ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _revisionPercentCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Процент ревизии (например: -10, 15)',
                      border: OutlineInputBorder(),
                    ),
                    controller: _revisionPercentCtrl,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _runningRevision ? null : _runAutoRevision,
                  icon: _runningRevision
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_fix_high_outlined),
                  label: const Text('Авто'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _autoHideOldRevisionPosts,
            onChanged: _runningRevision
                ? null
                : (v) => setState(() => _autoHideOldRevisionPosts = v),
            title: const Text('Скрывать старые версии постов'),
            subtitle: const Text(
              'Оставлять только самый свежий вариант товара',
            ),
          ),
          const SizedBox(height: 8),
          if (_loadingRevisionPosts)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: PhoenixLoadingView(
                title: 'Загружаем посты ревизии',
                subtitle: 'Собираем товары по выбранным датам',
                size: 44,
              ),
            )
          else if (_revisionPosts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Нет постов для выбранных дат'),
            )
          else
            ..._revisionPosts.map((post) {
              final imageUrl = _resolveImageUrl(
                (post['image_url'] ?? '').toString(),
              );
              final code = (post['product_code'] ?? '—').toString();
              final createdAt = (post['created_at'] ?? '').toString();
              final createdAtShort = createdAt.length >= 16
                  ? createdAt.substring(0, 16).replaceFirst('T', ' ')
                  : createdAt;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 78,
                        height: 78,
                        child: imageUrl != null
                            ? Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.photo_outlined),
                                    ),
                              )
                            : Container(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: const Icon(Icons.photo_outlined),
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (post['title'] ?? 'Товар').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            (post['description'] ?? '').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _statChip('ID $code'),
                              _statChip(
                                '${_toDoubleValue(post['price']).toStringAsFixed(0)} RUB',
                              ),
                              _statChip('x${_toIntValue(post['quantity'], 1)}'),
                            ],
                          ),
                          if (createdAtShort.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              createdAtShort,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Ручная ревизия',
                      onPressed: _runningRevision
                          ? null
                          : () => _manualRevisionEdit(post),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _statChip(String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Панель работника'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Новый товар'),
            Tab(text: 'Старые товары'),
            Tab(text: 'Свои посты'),
            Tab(text: 'Ревизия'),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  _message,
                  style: TextStyle(
                    color: _messageColor(Theme.of(context)),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildQueueTab(),
                  _buildSearchTab(),
                  _buildOwnPostsTab(),
                  _buildRevisionTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
