// lib/screens/worker_panel.dart
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';

class WorkerPanel extends StatefulWidget {
  const WorkerPanel({super.key});

  @override
  State<WorkerPanel> createState() => _WorkerPanelState();
}

class _WorkerPanelState extends State<WorkerPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  StreamSubscription? _chatEventsSub;

  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController(text: '1');
  final _searchCtrl = TextEditingController();

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
  bool _posting = false;
  bool _searching = false;
  String _message = '';
  List<Map<String, dynamic>> _channels = [];
  String? _selectedChannelId;
  List<Map<String, dynamic>> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadChannels();
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if (type == 'chat:created' || type == 'chat:deleted') {
        _loadChannels();
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    _tabController.dispose();
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    _quantityCtrl.dispose();
    _searchCtrl.dispose();
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
    if (!hasImage) {
      setState(() => _message = 'Добавьте фото товара');
      return;
    }

    final price = double.tryParse(priceText);
    if (price == null || price < 0) {
      setState(() => _message = 'Введите корректную цену');
      return;
    }

    final quantity = int.tryParse(qtyText) ?? 1;
    if (quantity <= 0) {
      setState(() => _message = 'Количество должно быть больше нуля');
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
        price: price,
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
    final fallbackPrice = (product['price'] is num)
        ? (product['price'] as num).toDouble()
        : 0.0;
    final price = editedPrice ?? fallbackPrice;

    final rawQtyInput = _quantityCtrl.text.trim();
    final editedQty = rawQtyInput.isNotEmpty ? int.tryParse(rawQtyInput) : null;
    if (rawQtyInput.isNotEmpty && (editedQty == null || editedQty <= 0)) {
      setState(() => _message = 'Количество должно быть больше нуля');
      return;
    }
    final fallbackQty = (product['quantity'] is num)
        ? (product['quantity'] as num).toInt()
        : 1;
    final quantity = editedQty ?? fallbackQty;
    final existingImage = (product['image_url'] ?? '').toString().trim();
    final hasImage =
        _pickedImage != null ||
        ((_existingImageUrl?.trim().isNotEmpty ?? false) &&
            !_removeImageOnSubmit) ||
        (existingImage.isNotEmpty && !_removeImageOnSubmit);
    if (!hasImage) {
      setState(() => _message = 'Добавьте фото товара');
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
      } else {
        setState(() => _message = 'Не удалось отправить товар в очередь');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка повторной отправки: $e');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Widget _buildPhotoPicker() {
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
                            color: Colors.grey[200],
                            alignment: Alignment.center,
                            child: const Icon(Icons.broken_image_outlined),
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
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_outlined, size: 28),
                      SizedBox(height: 6),
                      Text('Фото не выбрано'),
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
            child: Center(child: CircularProgressIndicator()),
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
            value: _selectedChannelId,
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
          decoration: const InputDecoration(
            labelText: 'Название товара',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionCtrl,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Описание',
            border: OutlineInputBorder(),
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
                decoration: const InputDecoration(
                  labelText: 'Цена',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _quantityCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Кол-во',
                  border: OutlineInputBorder(),
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
                decoration: const InputDecoration(
                  labelText: 'Поиск старого товара по описанию',
                  border: OutlineInputBorder(),
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
        if (_searching) const Center(child: CircularProgressIndicator()),
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
                          color: Colors.grey[200],
                          child: const Icon(
                            Icons.image_not_supported_outlined,
                            size: 18,
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
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'fill',
                    child: Text('Подставить в форму'),
                  ),
                  PopupMenuItem(
                    value: 'requeue',
                    child: Text('Сразу в очередь'),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Панель worker'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Новый товар'),
            Tab(text: 'Старые товары'),
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
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildQueueTab(), _buildSearchTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
