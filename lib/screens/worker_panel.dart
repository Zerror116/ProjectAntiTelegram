// lib/screens/worker_panel.dart
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../services/web_media_capture_permission_service.dart';
import '../src/utils/media_url.dart';
import '../widgets/adaptive_network_image.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/product_photo_crop_dialog.dart';

class WorkerPanel extends StatefulWidget {
  const WorkerPanel({super.key});

  @override
  State<WorkerPanel> createState() => _WorkerPanelState();
}

class _WorkerTabSpec {
  const _WorkerTabSpec({
    required this.id,
    required this.label,
    required this.builder,
  });

  final String id;
  final String label;
  final Widget Function() builder;
}

class _WorkerPanelState extends State<WorkerPanel>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  StreamSubscription? _authSub;
  List<_WorkerTabSpec> _visibleTabs = const <_WorkerTabSpec>[];
  StreamSubscription? _chatEventsSub;
  Timer? _ownPostsRefreshDebounce;

  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController(text: '1');
  final _searchCtrl = TextEditingController();
  final _revisionPercentCtrl = TextEditingController(text: '10');
  final Map<String, int> _quickDuplicateCounters = {};

  final ImagePicker _imagePicker = ImagePicker();
  XFile? _pickedImage;
  Uint8List? _pickedImageBytes;
  String? _pickedImageUploadFileName;
  String? _existingImageUrl;
  bool _removeImageOnSubmit = false;

  bool get _isMobileWeb =>
      kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _cameraSupported {
    if (kIsWeb) {
      return _isMobileWeb && WebMediaCapturePermissionService.isSupported;
    }
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

  void _dismissKeyboard() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.hasFocus ?? false) {
      focus?.unfocus();
    }
  }

  String _extractRequestError(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 413) {
        return 'Фото слишком большое для загрузки. Уменьшите размер и попробуйте снова.';
      }
      final data = error.response?.data;
      if (data is Map) {
        final raw = (data['error'] ?? data['message'] ?? '').toString().trim();
        if (raw.isNotEmpty) return raw;
      }
      final message = (error.message ?? '').trim();
      if (message.isNotEmpty) return message;
    }
    return error.toString();
  }

  int _resolveShelfNumberFromValue(dynamic value, {int fallback = 1}) {
    final parsed = _toIntValue(value, fallback);
    if (parsed <= 0) return fallback;
    return parsed;
  }

  String _formatProductLabel(dynamic productCode, dynamic shelfNumber) {
    final code = _toIntValue(productCode, 0);
    final shelf = _resolveShelfNumberFromValue(shelfNumber, fallback: 1);
    final codePart = code > 0 ? '$code' : '—';
    final shelfPart = shelf > 0 ? shelf.toString().padLeft(2, '0') : '—';
    return '$codePart--$shelfPart';
  }

  int? _extractShelfFromProductLabel(String? label) {
    final raw = (label ?? '').trim();
    if (raw.isEmpty) return null;
    final parts = raw.split('--');
    if (parts.length < 2) return null;
    final shelfDigits = parts.last.replaceAll(RegExp(r'[^0-9]'), '');
    final shelf = int.tryParse(shelfDigits);
    if (shelf == null || shelf <= 0) return null;
    return shelf;
  }

  int _queuedQuantityForProduct(String productId) {
    if (productId.isEmpty) return 0;
    final matches = _ownQueuedPosts.where(
      (row) => (row['product_id'] ?? '').toString() == productId,
    );
    if (matches.isEmpty) return 0;
    final latest = matches.first;
    final byProduct = _toIntValue(latest['product_quantity'], 0);
    if (byProduct > 0) return byProduct;
    final payload = latest['payload'];
    if (payload is Map) {
      return _toIntValue(payload['quantity'], 0);
    }
    return 0;
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
    _rebuildVisibleTabs(force: true, notify: false);
    _loadVisibleTabData();
    _chatEventsSub = chatEventsController.stream.listen((event) {
      final type = event['type']?.toString() ?? '';
      if ((type == 'chat:created' || type == 'chat:deleted') &&
          (_hasVisibleTab('new') || _hasVisibleTab('old'))) {
        _loadChannels();
      }
      if (type == 'chat:updated') {
        _ownPostsRefreshDebounce?.cancel();
        _ownPostsRefreshDebounce = Timer(
          const Duration(milliseconds: 650),
          () async {
            if (_hasVisibleTab('own')) {
              await _loadOwnQueuedPosts();
            }
            if (_hasVisibleTab('revision')) {
              await _loadRevisionPosts();
            }
          },
        );
      }
    });
    _authSub = authService.authStream.listen((_) {
      final changed = _rebuildVisibleTabs();
      if (changed) {
        _loadVisibleTabData();
      }
    });
  }

  @override
  void dispose() {
    _chatEventsSub?.cancel();
    _authSub?.cancel();
    _ownPostsRefreshDebounce?.cancel();
    _tabController?.dispose();
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    _quantityCtrl.dispose();
    _searchCtrl.dispose();
    _revisionPercentCtrl.dispose();
    super.dispose();
  }

  bool _hasAnyPermission(List<String> keys) {
    for (final key in keys) {
      if (authService.hasPermission(key)) return true;
    }
    return false;
  }

  bool _hasFullWorkerMenuAccess() {
    final role = authService.effectiveRole.toLowerCase().trim();
    return role == 'creator' || role == 'tenant';
  }

  bool _canViewNewTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const ['product.create']);
  }

  bool _canViewOldTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const ['product.requeue', 'product.create']);
  }

  bool _canViewOwnTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const [
      'product.edit.own_pending',
      'product.create',
    ]);
  }

  bool _canViewRevisionTab() {
    if (_hasFullWorkerMenuAccess()) return true;
    return _hasAnyPermission(const [
      'product.requeue',
      'product.edit.own_pending',
      'product.create',
    ]);
  }

  List<_WorkerTabSpec> _buildVisibleTabs() {
    final tabs = <_WorkerTabSpec>[
      if (_canViewNewTab())
        _WorkerTabSpec(
          id: 'new',
          label: 'Новый товар',
          builder: _buildQueueTab,
        ),
      if (_canViewOldTab())
        _WorkerTabSpec(
          id: 'old',
          label: 'Старые товары',
          builder: _buildSearchTab,
        ),
      if (_canViewOwnTab())
        _WorkerTabSpec(
          id: 'own',
          label: 'Свои посты',
          builder: _buildOwnPostsTab,
        ),
      if (_canViewRevisionTab())
        _WorkerTabSpec(
          id: 'revision',
          label: 'Ревизия',
          builder: _buildRevisionTab,
        ),
    ];
    if (tabs.isNotEmpty) return tabs;
    return <_WorkerTabSpec>[
      _WorkerTabSpec(
        id: 'no_access',
        label: 'Доступ',
        builder: _buildNoAccessTab,
      ),
    ];
  }

  bool _rebuildVisibleTabs({bool force = false, bool notify = true}) {
    final nextTabs = _buildVisibleTabs();
    final prevTabs = _visibleTabs;
    final unchanged =
        !force &&
        prevTabs.length == nextTabs.length &&
        List.generate(prevTabs.length, (i) => prevTabs[i].id).join('|') ==
            List.generate(nextTabs.length, (i) => nextTabs[i].id).join('|');
    if (unchanged && _tabController != null) return false;

    final oldId = (() {
      final controller = _tabController;
      if (controller == null || prevTabs.isEmpty) return null;
      final safeIndex = controller.index.clamp(0, prevTabs.length - 1);
      return prevTabs[safeIndex].id;
    })();

    _tabController?.dispose();
    _visibleTabs = nextTabs;
    final mappedIndex = oldId == null
        ? 0
        : nextTabs.indexWhere((tab) => tab.id == oldId);
    final initialIndex = mappedIndex >= 0 ? mappedIndex : 0;
    _tabController = TabController(
      length: nextTabs.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    if (notify && mounted) {
      setState(() {});
    }
    return true;
  }

  bool _hasVisibleTab(String id) {
    return _visibleTabs.any((tab) => tab.id == id);
  }

  void _animateToTab(String id) {
    final controller = _tabController;
    if (controller == null) return;
    final index = _visibleTabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    controller.animateTo(index);
  }

  void _loadVisibleTabData() {
    if (_hasVisibleTab('new') || _hasVisibleTab('old')) {
      _loadChannels();
    }
    if (_hasVisibleTab('own')) {
      _loadOwnQueuedPosts();
    }
    if (_hasVisibleTab('revision')) {
      _loadRevisionDates();
    }
  }

  String? _resolveImageUrl(String? raw) {
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
  }

  String? _normalizedImageUrlFromForm() {
    if (_removeImageOnSubmit) return null;
    final normalized = _existingImageUrl?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }

  Map<String, dynamic> _productFromOwnQueuedPost(Map<String, dynamic> post) {
    return {
      'id': (post['product_id'] ?? '').toString(),
      'title': (post['product_title'] ?? '').toString(),
      'description': (post['product_description'] ?? '').toString(),
      'price': post['product_price'],
      'quantity': post['product_quantity'],
      'image_url': (post['product_image_url'] ?? '').toString(),
      'product_code': post['product_code'],
      'shelf_number': post['product_shelf_number'],
    };
  }

  Future<void> _showShelfFullscreenNotice(
    int shelfNumber, {
    String? productLabel,
  }) async {
    if (!mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'shelf_notice',
      barrierColor: Colors.black.withValues(alpha: 0.72),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final theme = Theme.of(dialogContext);
        return SafeArea(
          child: Material(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.98),
            child: InkWell(
              onTap: () => Navigator.of(dialogContext).pop(),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inventory_2_rounded,
                        size: 72,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Положите товар на полку $shelfNumber',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if ((productLabel ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          'ID товара',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onErrorContainer
                                .withValues(alpha: 0.86),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onErrorContainer
                                .withValues(alpha: 0.09),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: theme.colorScheme.onErrorContainer
                                  .withValues(alpha: 0.18),
                            ),
                          ),
                          child: Text(
                            productLabel!.trim(),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        'Нажмите в любом месте, чтобы закрыть',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _resetProductForm() {
    _titleCtrl.clear();
    _descriptionCtrl.clear();
    _priceCtrl.clear();
    _quantityCtrl.text = '1';
    _pickedImage = null;
    _pickedImageBytes = null;
    _pickedImageUploadFileName = null;
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
                    'На этом устройстве используйте выбор фото с устройства',
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

  String _resolvedPickedFileName(XFile? picked) {
    final preferred = _pickedImageUploadFileName?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      return preferred;
    }
    final fromName = picked?.name.trim() ?? '';
    if (fromName.isNotEmpty) return fromName;
    final path = picked?.path.trim() ?? '';
    if (path.isNotEmpty) {
      final normalized = path.replaceAll('\\', '/');
      final fromPath = normalized.split('/').last.trim();
      if (fromPath.isNotEmpty) return fromPath;
    }
    return 'product-photo.jpg';
  }

  Future<void> _cropCurrentPickedImage() async {
    final picked = _pickedImage;
    Uint8List? sourceBytes = _pickedImageBytes;
    if ((sourceBytes == null || sourceBytes.isEmpty) && picked != null) {
      try {
        sourceBytes = await picked.readAsBytes();
      } catch (_) {
        sourceBytes = null;
      }
    }
    if (sourceBytes == null || sourceBytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _message = 'Сначала выберите фото, затем обрежьте его';
      });
      return;
    }

    try {
      if (!mounted) return;
      final result = await showProductPhotoCropDialog(
        context: context,
        sourceBytes: sourceBytes,
        originalFileName: _resolvedPickedFileName(picked),
      );
      if (result == null || !mounted) return;
      setState(() {
        _pickedImageBytes = result.bytes;
        _pickedImageUploadFileName = result.fileName;
        _removeImageOnSubmit = false;
        _message = '';
      });
      showAppNotice(
        context,
        'Обрезка фото применена',
        tone: AppNoticeTone.success,
        duration: const Duration(milliseconds: 900),
      );
      await playAppSound(AppUiSound.tap);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Не удалось обрезать фото: $e');
    }
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
      Uint8List? preloadedBytes;
      String? preloadedFileName;
      if (kIsWeb && effectiveSource == ImageSource.camera) {
        try {
          await WebMediaCapturePermissionService.requestPreferredAccess(
            includeVideo: true,
          );
        } catch (_) {}
        try {
          picked = await _imagePicker.pickImage(
            source: ImageSource.camera,
            preferredCameraDevice: CameraDevice.rear,
          );
        } catch (_) {}
        if (picked == null) {
          final result = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
            withData: true,
          );
          final selected = result?.files.single;
          final bytes = selected?.bytes;
          if (bytes != null && bytes.isNotEmpty) {
            preloadedBytes = bytes;
            preloadedFileName = (selected?.name ?? 'camera-image.jpg').trim();
            picked = XFile.fromData(bytes, name: preloadedFileName);
          }
        }
      } else if (effectiveSource == ImageSource.gallery &&
          _preferFilePickerForGallery) {
        if (kIsWeb) {
          // Web: read bytes directly from FilePicker to avoid revoked Blob URLs.
          final result = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
            withData: true,
          );
          final selected = result?.files.single;
          final bytes = selected?.bytes;
          if (bytes != null && bytes.isNotEmpty) {
            preloadedBytes = bytes;
            preloadedFileName = (selected?.name ?? 'image.jpg').trim();
            picked = XFile.fromData(bytes, name: preloadedFileName);
          } else if (selected != null) {
            if (!mounted) return;
            setState(() {
              _message = 'Браузер не отдал данные фото. Повторите выбор файла.';
            });
            return;
          }
        } else {
          // Desktop: first try ImagePicker, then fallback to FilePicker.
          try {
            picked = await _imagePicker.pickImage(source: ImageSource.gallery);
          } catch (_) {}

          try {
            if (picked == null) {
              final result = await FilePicker.platform.pickFiles(
                type: FileType.image,
                allowMultiple: false,
                withData: false,
              );
              final selected = result?.files.single;
              final path = selected?.path;
              if (path != null && path.isNotEmpty) {
                picked = XFile(path, name: selected?.name ?? '');
              } else {
                final bytes = selected?.bytes;
                if (bytes != null && bytes.isNotEmpty) {
                  preloadedBytes = bytes;
                  preloadedFileName = (selected?.name ?? 'image.jpg').trim();
                  picked = XFile.fromData(bytes, name: preloadedFileName);
                }
              }
            }
          } catch (_) {
            // Ignore and handle below.
          }
        }
      } else {
        picked = await _imagePicker.pickImage(source: effectiveSource);
      }

      if (picked == null &&
          (preloadedBytes == null || preloadedBytes.isEmpty)) {
        if (!mounted) return;
        setState(() {
          _message = 'Фото не выбрано';
        });
        return;
      }

      Uint8List pickedBytes;
      if (preloadedBytes != null && preloadedBytes.isNotEmpty) {
        pickedBytes = preloadedBytes;
      } else {
        try {
          pickedBytes = await picked!.readAsBytes();
        } catch (e) {
          if (!mounted) return;
          setState(() => _message = 'Не удалось прочитать фото: $e');
          return;
        }
      }
      if (pickedBytes.isEmpty) {
        if (!mounted) return;
        setState(() => _message = 'Выбрано пустое изображение');
        return;
      }

      if (!mounted) return;
      if (preloadedFileName != null && preloadedFileName.isNotEmpty) {
        _pickedImageUploadFileName = preloadedFileName;
      }
      final cropResult = await showProductPhotoCropDialog(
        context: context,
        sourceBytes: pickedBytes,
        originalFileName: _resolvedPickedFileName(picked),
      );
      if (cropResult == null) {
        if (!mounted) return;
        setState(() {
          _message = 'Выбор фото отменен';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _pickedImage = picked;
        _pickedImageBytes = cropResult.bytes;
        _pickedImageUploadFileName = cropResult.fileName;
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
      _pickedImageBytes = null;
      _pickedImageUploadFileName = null;
      _existingImageUrl = null;
      _removeImageOnSubmit = true;
    });
  }

  Future<MultipartFile?> _buildPickedImageMultipart() async {
    final picked = _pickedImage;
    final fileName = _resolvedPickedFileName(picked);
    final preparedBytes = _pickedImageBytes;
    if (preparedBytes != null && preparedBytes.isNotEmpty) {
      return MultipartFile.fromBytes(preparedBytes, filename: fileName);
    }
    if (picked == null) return null;

    if (kIsWeb) {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return null;
      return MultipartFile.fromBytes(bytes, filename: fileName);
    }

    final path = picked.path;
    if (path.isEmpty) return null;
    return MultipartFile.fromFile(path, filename: fileName);
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

    if (_pickedImage != null || (_pickedImageBytes?.isNotEmpty ?? false)) {
      final imageFile = await _buildPickedImageMultipart();
      if (imageFile != null) {
        map['image'] = imageFile;
      }
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

    if (_pickedImage != null || (_pickedImageBytes?.isNotEmpty ?? false)) {
      final imageFile = await _buildPickedImageMultipart();
      if (imageFile != null) {
        map['image'] = imageFile;
      }
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
      setState(
        () => _message = 'Ошибка загрузки каналов: ${_extractRequestError(e)}',
      );
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
      setState(
        () => _message =
            'Ошибка загрузки своих постов: ${_extractRequestError(e)}',
      );
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
        final availableDays = dates
            .map((e) => (e['day'] ?? '').toString())
            .where((e) => e.isNotEmpty)
            .toList();
        final preservedSelection = availableDays
            .where((day) => _selectedRevisionDates.contains(day))
            .take(2)
            .toSet();
        final nextSelected =
            preservedSelection.isNotEmpty
                ? preservedSelection
                : availableDays.take(1).toSet();
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

  String _revisionDayOf(Map<String, dynamic> post) {
    final explicit = (post['day'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final createdAt = (post['created_at'] ?? '').toString().trim();
    if (createdAt.length >= 10) return createdAt.substring(0, 10);
    return '';
  }

  bool _isRevisionBlocked(Map<String, dynamic> post) {
    return post['revision_allowed'] == false;
  }

  String _revisionBlockedNote(Map<String, dynamic> post) {
    return (post['revision_note'] ?? '').toString().trim();
  }

  void _applyRevisionProductsRemovedLocally(Set<String> productIds) {
    if (productIds.isEmpty || !mounted) return;
    final remainingPosts = _revisionPosts
        .where(
          (post) => !productIds.contains((post['product_id'] ?? '').toString().trim()),
        )
        .toList();
    final countsByDay = <String, int>{};
    for (final post in remainingPosts) {
      final day = _revisionDayOf(post);
      if (day.isEmpty) continue;
      countsByDay.update(day, (value) => value + 1, ifAbsent: () => 1);
    }

    final nextDates = <Map<String, dynamic>>[];
    for (final item in _revisionDates) {
      final copy = Map<String, dynamic>.from(item);
      final day = (copy['day'] ?? '').toString().trim();
      final nextCount = countsByDay[day] ?? 0;
      if (nextCount <= 0) continue;
      copy['posts'] = nextCount;
      nextDates.add(copy);
    }

    var nextSelected = _selectedRevisionDates
        .where((day) => nextDates.any((item) => (item['day'] ?? '').toString() == day))
        .toSet();
    if (nextSelected.isEmpty && nextDates.isNotEmpty) {
      nextSelected = {(nextDates.first['day'] ?? '').toString()};
    }

    setState(() {
      _revisionPosts = remainingPosts;
      _revisionDates = nextDates;
      _selectedRevisionDates = nextSelected;
    });
  }

  void _mergeOwnQueuedPostLocally(Map<String, dynamic> queuedItem) {
    if (!mounted) return;
    final queueId = (queuedItem['queue_id'] ?? queuedItem['id'] ?? '').toString().trim();
    if (queueId.isEmpty) return;

    final payload = queuedItem['payload'] is Map
        ? Map<String, dynamic>.from(queuedItem['payload'])
        : <String, dynamic>{
            'title': queuedItem['product_title'],
            'description': queuedItem['product_description'],
            'price': queuedItem['product_price'],
            'quantity': queuedItem['product_quantity'],
            'shelf_number': queuedItem['product_shelf_number'],
            'image_url': queuedItem['product_image_url'],
          };

    final nextRow = <String, dynamic>{
      'id': queueId,
      'product_id': (queuedItem['product_id'] ?? '').toString(),
      'channel_id': (_selectedChannelId ?? '').toString(),
      'queued_by': authService.currentUser?.id,
      'status': 'pending',
      'is_sent': false,
      'payload': payload,
      'created_at':
          queuedItem['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
      'product_code': queuedItem['product_code'],
      'product_shelf_number': queuedItem['product_shelf_number'],
      'product_title': queuedItem['product_title'],
      'product_description': queuedItem['product_description'],
      'product_price': queuedItem['product_price'],
      'product_quantity': queuedItem['product_quantity'],
      'product_image_url': queuedItem['product_image_url'],
    };

    final nextItems = List<Map<String, dynamic>>.from(_ownQueuedPosts);
    final index = nextItems.indexWhere(
      (row) => (row['id'] ?? '').toString().trim() == queueId,
    );
    if (index >= 0) {
      nextItems[index] = {...nextItems[index], ...nextRow};
    } else {
      nextItems.insert(0, nextRow);
    }

    nextItems.sort((a, b) {
      final left = DateTime.tryParse((a['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final right = DateTime.tryParse((b['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });

    setState(() => _ownQueuedPosts = nextItems);
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
    final enteredPercent = double.tryParse(rawPercent);
    if (enteredPercent == null) {
      setState(() => _message = 'Введите корректный процент ревизии');
      return;
    }
    if (enteredPercent <= 0 || enteredPercent > 95) {
      setState(
        () => _message = 'Процент снижения должен быть больше 0 и не больше 95',
      );
      return;
    }
    final percent = enteredPercent.abs();
    if (_selectedRevisionDates.isEmpty) {
      setState(() => _message = 'Выберите хотя бы одну дату ревизии');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Авто-ревизия'),
        content: Text(
          'Снизить цены на ${enteredPercent.toStringAsFixed(enteredPercent % 1 == 0 ? 0 : 1)}% и '
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
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      final updatedCount = _toIntValue(
        payload['updated_count'],
      );
      final queuedCount = _toIntValue(
        payload['queued_count'],
        updatedCount,
      );
      final reusedCount = _toIntValue(
        payload['reused_pending_count'],
      );
      final queuedItems = payload['queued_items'] is List
          ? List<Map<String, dynamic>>.from(payload['queued_items'])
          : const <Map<String, dynamic>>[];
      final affectedProductIds = queuedItems
          .map((item) => (item['product_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      _applyRevisionProductsRemovedLocally(affectedProductIds);
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
      unawaited(_loadOwnQueuedPosts());
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
    if (_isRevisionBlocked(post)) {
      if (!mounted) return;
      final note = _revisionBlockedNote(post);
      setState(
        () => _message = note.isNotEmpty ? note : 'Этот товар сейчас нельзя ревизовать',
      );
      return;
    }
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
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
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
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 180,
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
                    SizedBox(
                      width: 140,
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
      final resp = await authService.dio.post(
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
      final data = resp.data;
      final payload = data is Map && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      final queuedItems = payload['queued_items'] is List
          ? List<Map<String, dynamic>>.from(payload['queued_items'])
          : const <Map<String, dynamic>>[];
      final affectedProductIds = queuedItems
          .map((item) => (item['product_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      _applyRevisionProductsRemovedLocally(
        affectedProductIds.isEmpty
            ? {(post['product_id'] ?? '').toString().trim()}
            : affectedProductIds,
      );
      if (queuedItems.isNotEmpty) {
        _mergeOwnQueuedPostLocally(queuedItems.first);
      }
      if (!mounted) return;
      setState(() => _message = 'Ревизия товара сохранена');
      showAppNotice(
        context,
        'Изменения ревизии сохранены',
        tone: AppNoticeTone.success,
      );
      await playAppSound(AppUiSound.success);
      unawaited(_loadOwnQueuedPosts());
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
        (_pickedImageBytes?.isNotEmpty ?? false) ||
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
        String? productLabel;
        if (data is Map && data['data'] is Map) {
          final dataMap = Map<String, dynamic>.from(data['data']);
          final queue = dataMap['queue'];
          if (queue is Map) {
            queueId = queue['id']?.toString();
          }
          productLabel = dataMap['product_label']?.toString();
          final product = dataMap['product'];
          if (product is Map) {
            productLabel ??= _formatProductLabel(
              product['product_code'],
              product['shelf_number'],
            );
          }
        }
        final shelfNumber = _extractShelfFromProductLabel(productLabel);
        setState(() {
          if (productLabel != null && productLabel.isNotEmpty) {
            _message = shelfNumber != null
                ? 'Товар отправлен в очередь. ID товара: $productLabel. Полка: $shelfNumber'
                : 'Товар отправлен в очередь. ID товара: $productLabel';
          } else if (queueId != null) {
            _message = 'Товар отправлен в очередь. ID заявки: $queueId';
          } else {
            _message = 'Товар отправлен в очередь';
          }
        });
        _resetProductForm();
        await _loadOwnQueuedPosts();
        _animateToTab('own');
        if (mounted) {
          showAppNotice(
            context,
            productLabel != null && productLabel.isNotEmpty
                ? 'Товар отправлен в очередь. ID: $productLabel'
                : 'Товар отправлен в очередь',
            tone: AppNoticeTone.success,
            duration: const Duration(milliseconds: 1400),
          );
          if (shelfNumber != null) {
            await _showShelfFullscreenNotice(
              shelfNumber,
              productLabel: productLabel,
            );
          }
        }
        await playAppSound(AppUiSound.success);
      } else {
        setState(() => _message = 'Не удалось отправить товар в очередь');
      }
    } catch (e) {
      setState(() => _message = 'Ошибка отправки: ${_extractRequestError(e)}');
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
    _quantityCtrl.text = '1';
    setState(() {
      _pickedImage = null;
      _pickedImageBytes = null;
      _pickedImageUploadFileName = null;
      _existingImageUrl = (product['image_url'] ?? '').toString();
      _removeImageOnSubmit = false;
      _message = 'Данные товара подставлены. Проверьте и отправьте в очередь.';
    });
    _animateToTab('new');
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
        (_pickedImageBytes?.isNotEmpty ?? false) ||
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
        String? productLabel;
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final body = Map<String, dynamic>.from(data['data']);
          productLabel = body['product_label']?.toString();
          final product = body['product'];
          if (product is Map) {
            productLabel ??= _formatProductLabel(
              product['product_code'],
              product['shelf_number'],
            );
          }
        }
        final shelfNumber = _extractShelfFromProductLabel(productLabel);
        setState(() {
          _message = productLabel != null && productLabel.isNotEmpty
              ? (shelfNumber != null
                    ? 'Старый товар отправлен в очередь. ID товара: $productLabel. Полка: $shelfNumber'
                    : 'Старый товар отправлен в очередь. ID товара: $productLabel')
              : 'Старый товар отправлен в очередь повторно';
          _removeImageOnSubmit = false;
        });
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productLabel != null && productLabel.isNotEmpty
                ? 'Товар снова в очереди. ID: $productLabel'
                : 'Товар снова отправлен в очередь',
            tone: AppNoticeTone.success,
          );
          if (shelfNumber != null) {
            await _showShelfFullscreenNotice(
              shelfNumber,
              productLabel: productLabel,
            );
          }
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
    final queuedQuantity = _queuedQuantityForProduct(productId);
    final lastCounter = _quickDuplicateCounters[productId] ?? 0;
    final baseQuantity = queuedQuantity > 0 ? queuedQuantity : lastCounter;
    final quantity = (baseQuantity + 1).clamp(1, 999999);
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
          'merge_pending': true,
        },
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        _quickDuplicateCounters[productId] = quantity;
        String? productLabel;
        final data = resp.data;
        if (data is Map && data['data'] is Map) {
          final body = Map<String, dynamic>.from(data['data']);
          productLabel = body['product_label']?.toString();
          final productMap = body['product'];
          if (productMap is Map) {
            productLabel ??= _formatProductLabel(
              productMap['product_code'],
              productMap['shelf_number'],
            );
          }
        }
        final shelfNumber = _extractShelfFromProductLabel(productLabel);
        setState(() {
          _message = productLabel != null && productLabel.isNotEmpty
              ? (shelfNumber != null
                    ? 'Дубль товара отправлен. ID товара: $productLabel. Полка: $shelfNumber'
                    : 'Дубль товара отправлен. ID товара: $productLabel')
              : 'Дубль товара отправлен в очередь';
        });
        _loadOwnQueuedPosts();
        if (mounted) {
          showAppNotice(
            context,
            productLabel != null && productLabel.isNotEmpty
                ? 'Дубль готов. ID: $productLabel'
                : 'Товар продублирован в очередь',
            tone: AppNoticeTone.success,
          );
          if (shelfNumber != null) {
            await _showShelfFullscreenNotice(
              shelfNumber,
              productLabel: productLabel,
            );
          }
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
    final localPath = _pickedImage?.path.trim();
    final localBytes = _pickedImageBytes;
    final hasLocalPickedImage =
        (localBytes != null && localBytes.isNotEmpty) ||
        (localPath != null && localPath.isNotEmpty);
    final remoteUrl = _resolveImageUrl(_existingImageUrl);
    final hasImage = hasLocalPickedImage || remoteUrl != null;
    const previewWidth = 220.0;
    Widget withPreviewSurface(Widget child) => Container(
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: child,
    );
    Widget imageErrorPlaceholder() => Container(
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    Widget buildLocalPathPreview(String path) {
      if (kIsWeb) {
        final lower = path.toLowerCase();
        final canUseNetworkLikePath =
            lower.startsWith('http://') ||
            lower.startsWith('https://') ||
            lower.startsWith('blob:') ||
            lower.startsWith('data:');
        if (!canUseNetworkLikePath) {
          return imageErrorPlaceholder();
        }
        return AdaptiveNetworkImage(
          path,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => imageErrorPlaceholder(),
        );
      }
      return withPreviewSurface(
        Image(
          image: FileImage(File(path)),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stackTrace) => imageErrorPlaceholder(),
        ),
      );
    }

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
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: 140,
                    maxHeight: previewWidth * 1.25,
                  ),
                  child: (localBytes != null && localBytes.isNotEmpty)
                      ? withPreviewSurface(
                          Image.memory(
                            localBytes,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        )
                      : (localPath != null && localPath.isNotEmpty)
                      ? buildLocalPathPreview(localPath)
                      : withPreviewSurface(
                          AdaptiveNetworkImage(
                            remoteUrl!,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                imageErrorPlaceholder(),
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
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: 140,
                  maxHeight: previewWidth * 1.25,
                ),
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
              if (hasLocalPickedImage)
                IconButton(
                  onPressed: _cropCurrentPickedImage,
                  icon: const Icon(Icons.crop),
                  tooltip: 'Обрезать фото',
                ),
              if (hasLocalPickedImage) const SizedBox(width: 2),
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
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
              flex: 3,
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
            Expanded(
              flex: 2,
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
        const SizedBox(height: 8),
        Text(
          'Номер полки назначается автоматически по дате.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        _buildPhotoPicker(),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _posting ? null : _queueProduct,
            icon: _posting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
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
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
          const AppEmptyState(
            title: 'Результаты появятся здесь',
            subtitle: 'Введите описание товара, чтобы найти старые позиции.',
            icon: Icons.search_rounded,
          ),
        ..._searchResults.map((p) {
          final label = _formatProductLabel(
            p['product_code'],
            p['shelf_number'],
          );
          final imageUrl = _resolveImageUrl((p['image_url'] ?? '').toString());
          return Card(
            child: ListTile(
              leading: imageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: AdaptiveNetworkImage(
                        imageUrl,
                        width: 52,
                        height: 52,
                        fit: BoxFit.contain,
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
                'ID: $label\n'
                'Цена: ${p['price']} ₽\n'
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
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
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
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 180,
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
                    SizedBox(
                      width: 140,
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

  Future<void> _deleteOwnQueuedPost(Map<String, dynamic> post) async {
    final title = (post['product_title'] ?? 'этот пост').toString().trim();
    final payload =
        post['payload'] is Map<String, dynamic>
            ? post['payload'] as Map<String, dynamic>
            : post['payload'] is Map
                ? Map<String, dynamic>.from(post['payload'])
                : const <String, dynamic>{};
    final isRevisionPost =
        payload['revision_manual'] == true || payload['revision_auto'] == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить свой пост?'),
        content: Text(
          isRevisionPost
              ? 'Удалить "$title" из очереди ревизии?\n\n'
                  'После этого он не уйдёт на канал, а исходный пост вернётся обратно в Основной канал.'
              : 'Удалить "$title" из очереди?\n\nПосле этого пост не уйдёт на канал.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (mounted) {
      setState(() => _savingOwnPost = true);
    }
    try {
      await authService.dio.delete('/api/worker/queue/${post['id']}');
      await _loadOwnQueuedPosts();
      if (!mounted) return;
      setState(
        () => _message = isRevisionPost
            ? 'Ревизия снята с очереди, исходный пост возвращён в канал'
            : 'Пост удалён из очереди',
      );
      showAppNotice(
        context,
        isRevisionPost
            ? 'Ревизия снята. Исходный пост снова виден в Основном канале.'
            : 'Пост удалён. Он больше не уйдёт на канал.',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = 'Ошибка удаления поста: ${_extractRequestError(e)}',
      );
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
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: const [
          AppEmptyState(
            title: 'У вас пока нет постов в очереди',
            subtitle: 'Отправьте товар в очередь, и он появится здесь.',
            icon: Icons.inventory_2_outlined,
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _loadOwnQueuedPosts,
      child: ListView.separated(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                            ? AdaptiveNetworkImage(
                                imageUrl,
                                fit: BoxFit.contain,
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
                                'ID ${_formatProductLabel(post['product_code'], post['product_shelf_number'])}',
                              ),
                              _statChip(
                                '${_toDoubleValue(post['product_price']).toStringAsFixed(0)} ₽',
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
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _savingOwnPost
                              ? null
                              : () => _editOwnQueuedPost(post),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Изменить'),
                        ),
                        OutlinedButton.icon(
                          onPressed: (_savingOwnPost || _posting)
                              ? null
                              : () => _deleteOwnQueuedPost(post),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Удалить'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _posting
                              ? null
                              : () => _quickDuplicateProduct(
                                  _productFromOwnQueuedPost(post),
                                ),
                          icon: const Icon(Icons.content_copy_outlined, size: 18),
                          label: const Text('Дубль'),
                        ),
                      ],
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
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
              'Ревизия: выберите одну или две первые даты публикации, затем запускайте авто-ревизию '
              'или вручную редактируйте карточки. Купленные, но ещё не обработанные товары '
              'показываются с пометкой и не меняются через ревизию.',
            ),
          ),
          const SizedBox(height: 12),
          if (_loadingRevisionDates)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: PhoenixLoadingView(
                title: 'Загружаем даты ревизии',
                subtitle: 'Собираем первые даты публикаций',
                size: 44,
              ),
            )
          else if (_revisionDates.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Нет данных для ревизии'),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final buttonWidth =
                    _revisionDates.length <= 1
                        ? constraints.maxWidth
                        : ((constraints.maxWidth - 8) / 2).clamp(0.0, double.infinity)
                            .toDouble();
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _revisionDates.map((item) {
                    final day = (item['day'] ?? '').toString();
                    final label = (item['label'] ?? day).toString();
                    final count = _toIntValue(item['posts'], 0);
                    final selected = _selectedRevisionDates.contains(day);
                    final colorScheme = theme.colorScheme;
                    return SizedBox(
                      width: buttonWidth,
                      child: ElevatedButton(
                        onPressed: () => _toggleRevisionDate(day),
                        style: ElevatedButton.styleFrom(
                          elevation: selected ? 0 : 1,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          backgroundColor:
                              selected
                                  ? colorScheme.primaryContainer
                                  : colorScheme.surfaceContainerLow,
                          foregroundColor:
                              selected
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurface,
                          side: BorderSide(
                            color:
                                selected
                                    ? colorScheme.primary
                                    : colorScheme.outlineVariant,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$count товаров',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color:
                                    selected
                                        ? colorScheme.onPrimaryContainer.withValues(alpha: 0.78)
                                        : colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
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
                    signed: false,
                  ),
                  decoration: withInputLanguageBadge(
                    const InputDecoration(
                      labelText: 'Процент снижения (например: 10, 25, 50)',
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
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.auto_fix_high_outlined),
                  label: const Text('Авто'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [10, 25, 50]
                  .map(
                    (value) => ActionChip(
                      label: Text('$value%'),
                      onPressed: _runningRevision
                          ? null
                          : () {
                              _revisionPercentCtrl.text = '$value';
                              _revisionPercentCtrl.selection =
                                  TextSelection.fromPosition(
                                    TextPosition(
                                      offset: _revisionPercentCtrl.text.length,
                                    ),
                                  );
                            },
                    ),
                  )
                  .toList(),
            ),
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
                subtitle: 'Собираем актуальные товары по выбранным датам',
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
              final blocked = _isRevisionBlocked(post);
              final blockedNote = _revisionBlockedNote(post);
              final productLabel = _formatProductLabel(
                post['product_code'],
                post['shelf_number'],
              );
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
                            ? AdaptiveNetworkImage(
                                imageUrl,
                                fit: BoxFit.contain,
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
                              _statChip('ID $productLabel'),
                              _statChip(
                                'Полка ${_toIntValue(post['shelf_number'], 1).toString().padLeft(2, '0')}',
                              ),
                              _statChip(
                                '${_toDoubleValue(post['price']).toStringAsFixed(0)} ₽',
                              ),
                              _statChip('x${_toIntValue(post['quantity'], 1)}'),
                            ],
                          ),
                          if (blockedNote.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                blockedNote,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
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
                      tooltip: blocked
                          ? 'Товар уже купили, отнесите администратору'
                          : 'Ручная ревизия',
                      onPressed: _runningRevision || blocked
                          ? null
                          : () => _manualRevisionEdit(post),
                      icon: Icon(
                        blocked ? Icons.inventory_2_outlined : Icons.edit_outlined,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildNoAccessTab() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Нет прав для панели работника',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Попросите арендатора или администратора выдать доступ к товарам.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
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
    final compact = MediaQuery.of(context).size.width < 700;
    if (_tabController == null || _visibleTabs.isEmpty) {
      _rebuildVisibleTabs(force: true, notify: false);
    }
    final controller = _tabController;
    final tabs = _visibleTabs.map((tab) => Tab(text: tab.label)).toList();
    final tabViews = _visibleTabs.map((tab) => tab.builder()).toList();
    if (controller == null || tabs.isEmpty || tabViews.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Панель работника')),
        body: SafeArea(child: _buildNoAccessTab()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Панель работника'),
        bottom: TabBar(
          controller: controller,
          tabs: tabs,
          isScrollable: compact,
          onTap: (_) => _dismissKeyboard(),
        ),
      ),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismissKeyboard,
          child: Column(
            children: [
              if (_message.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 10 : 16,
                    12,
                    compact ? 10 : 16,
                    0,
                  ),
                  child: Text(
                    _message,
                    style: TextStyle(
                      color: _messageColor(Theme.of(context)),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Expanded(
                child: TabBarView(controller: controller, children: tabViews),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
