// lib/screens/admin_panel.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../main.dart';

class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key});

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _channelTitleCtrl = TextEditingController();
  final _channelDescriptionCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _publishing = false;
  bool _dispatchingOrders = false;
  bool _avatarUpdating = false;

  String _message = '';
  String _newChannelVisibility = 'public';
  String? _pendingFilterChannelId;

  List<Map<String, dynamic>> _channels = [];
  List<Map<String, dynamic>> _pendingPosts = [];
  List<Map<String, dynamic>> _lastPublished = [];
  List<Map<String, dynamic>> _lastDispatchedOrders = [];

  final Map<String, Map<String, dynamic>> _channelOverviews = {};
  final Set<String> _overviewLoading = <String>{};
  final Set<String> _blacklistBusy = <String>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _reloadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _channelTitleCtrl.dispose();
    _channelDescriptionCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.map((e) => _asMap(e)).toList();
  }

  Map<String, dynamic> _settingsOf(Map<String, dynamic> channel) {
    return _asMap(channel['settings']);
  }

  String _channelIdOf(Map<String, dynamic> channel) {
    return (channel['id'] ?? '').toString();
  }

  int _toInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    return int.tryParse('${value ?? ''}') ?? fallback;
  }

  double _toFocus(dynamic value) {
    final parsed = double.tryParse('${value ?? ''}');
    if (parsed == null || !parsed.isFinite) return 0;
    return parsed.clamp(-1.0, 1.0).toDouble();
  }

  double _toAvatarZoom(dynamic value) {
    final parsed = double.tryParse('${value ?? ''}');
    if (parsed == null || !parsed.isFinite) return 1;
    return parsed.clamp(1.0, 4.0).toDouble();
  }

  Offset _clampAvatarOffset({
    required Offset offset,
    required int sourceWidth,
    required int sourceHeight,
    required double previewSize,
    required double cutoutSize,
    required double zoom,
  }) {
    final baseScale = math.max(
      previewSize / sourceWidth,
      previewSize / sourceHeight,
    );
    final renderedWidth = sourceWidth * baseScale * zoom;
    final renderedHeight = sourceHeight * baseScale * zoom;

    final maxX = math.max(0.0, (renderedWidth - cutoutSize) / 2);
    final maxY = math.max(0.0, (renderedHeight - cutoutSize) / 2);

    return Offset(
      offset.dx.clamp(-maxX, maxX).toDouble(),
      offset.dy.clamp(-maxY, maxY).toDouble(),
    );
  }

  Future<String> _exportAvatarCrop({
    required String sourcePath,
    required int sourceWidth,
    required int sourceHeight,
    required double previewSize,
    required double cutoutSize,
    required Offset offset,
    required double zoom,
  }) async {
    final bytes = await File(sourcePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Не удалось прочитать изображение');
    }

    final baseScale = math.max(
      previewSize / sourceWidth,
      previewSize / sourceHeight,
    );
    final effectiveScale = baseScale * zoom;
    final renderedWidth = sourceWidth * effectiveScale;
    final renderedHeight = sourceHeight * effectiveScale;

    final imageLeft = (previewSize - renderedWidth) / 2 + offset.dx;
    final imageTop = (previewSize - renderedHeight) / 2 + offset.dy;
    final cutoutLeft = (previewSize - cutoutSize) / 2;
    final cutoutTop = (previewSize - cutoutSize) / 2;

    final srcXf = (cutoutLeft - imageLeft) / effectiveScale;
    final srcYf = (cutoutTop - imageTop) / effectiveScale;
    final srcWf = cutoutSize / effectiveScale;
    final srcHf = cutoutSize / effectiveScale;

    final srcX = srcXf.floor().clamp(0, decoded.width - 1);
    final srcY = srcYf.floor().clamp(0, decoded.height - 1);
    final srcW = srcWf.ceil().clamp(1, decoded.width - srcX);
    final srcH = srcHf.ceil().clamp(1, decoded.height - srcY);
    final srcSide = math.min(srcW, srcH);

    final cropped = img.copyCrop(
      decoded,
      x: srcX,
      y: srcY,
      width: srcSide,
      height: srcSide,
    );
    final resized = img.copyResize(
      cropped,
      width: 512,
      height: 512,
      interpolation: img.Interpolation.cubic,
    );

    final outputBytes = img.encodeJpg(resized, quality: 92);
    final outputPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}channel_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(outputPath).writeAsBytes(outputBytes, flush: true);
    return outputPath;
  }

  String _displayName(
    Map<String, dynamic> row, {
    String fallback = 'Пользователь',
  }) {
    final name = (row['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final email = (row['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;
    return fallback;
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

  void _emitChatUpdatedIfPresent(dynamic responseData) {
    if (responseData is Map && responseData['data'] is Map) {
      final updated = Map<String, dynamic>.from(responseData['data']);
      chatEventsController.add({
        'type': 'chat:updated',
        'data': {'chat': updated},
      });
    }
  }

  Future<void> _reloadAll() async {
    await _loadChannels();
    await _loadPendingPosts();
  }

  Future<void> _loadChannels() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      final resp = await authService.dio.get('/api/admin/channels');
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        final channels = List<Map<String, dynamic>>.from(data['data']);
        final ids = channels
            .map(_channelIdOf)
            .where((v) => v.isNotEmpty)
            .toSet();
        _channelOverviews.removeWhere((key, _) => !ids.contains(key));
        if (mounted) {
          setState(() => _channels = channels);
        }

        for (final channel in channels.take(3)) {
          final id = _channelIdOf(channel);
          if (id.isEmpty) continue;
          unawaited(_loadChannelOverview(id, silent: true));
        }
      } else {
        if (mounted) {
          setState(() => _message = 'Не удалось загрузить каналы');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки каналов: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, dynamic>?> _loadChannelOverview(
    String channelId, {
    bool force = false,
    bool silent = false,
  }) async {
    if (channelId.isEmpty) return null;
    if (!force && _channelOverviews.containsKey(channelId)) {
      return _channelOverviews[channelId];
    }
    if (_overviewLoading.contains(channelId)) {
      return _channelOverviews[channelId];
    }

    if (mounted) {
      setState(() => _overviewLoading.add(channelId));
    }

    try {
      final resp = await authService.dio.get(
        '/api/admin/channels/$channelId/overview',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final map = Map<String, dynamic>.from(data['data']);
        if (mounted) {
          setState(() => _channelOverviews[channelId] = map);
        }
        return map;
      }
      if (!silent && mounted) {
        setState(() => _message = 'Не удалось загрузить обзор канала');
      }
      return null;
    } catch (e) {
      if (!silent && mounted) {
        setState(
          () => _message = 'Ошибка обзора канала: ${_extractDioError(e)}',
        );
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _overviewLoading.remove(channelId));
      }
    }
  }

  Future<void> _loadPendingPosts() async {
    try {
      final resp = await authService.dio.get(
        '/api/admin/channels/pending_posts',
        queryParameters: {
          if (_pendingFilterChannelId != null &&
              _pendingFilterChannelId!.isNotEmpty)
            'channel_id': _pendingFilterChannelId,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is List) {
        if (mounted) {
          setState(
            () => _pendingPosts = List<Map<String, dynamic>>.from(data['data']),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки очереди: ${_extractDioError(e)}',
        );
      }
    }
  }

  Future<void> _createChannel() async {
    final title = _channelTitleCtrl.text.trim();
    final description = _channelDescriptionCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _message = 'Введите название канала');
      return;
    }

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/channels',
        data: {
          'title': title,
          'description': description,
          'visibility': _newChannelVisibility,
        },
      );
      if (resp.statusCode == 201 || resp.statusCode == 200) {
        final data = resp.data;
        Map<String, dynamic>? createdChat;
        if (data is Map && data['data'] is Map) {
          createdChat = Map<String, dynamic>.from(data['data']);
        }
        if (createdChat != null) {
          chatEventsController.add({
            'type': 'chat:created',
            'data': {'chat': createdChat},
          });
        }
        _channelTitleCtrl.clear();
        _channelDescriptionCtrl.clear();
        await _reloadAll();
        if (mounted) {
          setState(() => _message = 'Канал создан');
          _tabController.animateTo(1);
        }
      } else {
        setState(() => _message = 'Не удалось создать канал');
      }
    } catch (e) {
      setState(
        () => _message = 'Ошибка создания канала: ${_extractDioError(e)}',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteChannel(String channelId, String title) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить канал'),
        content: Text(
          'Удалить канал "$title"?\n'
          'Это удалит сообщения в этом канале.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      await authService.dio.delete('/api/admin/channels/$channelId');
      chatEventsController.add({
        'type': 'chat:deleted',
        'data': {'chatId': channelId},
      });
      _channelOverviews.remove(channelId);
      if (_pendingFilterChannelId == channelId) {
        _pendingFilterChannelId = null;
      }
      await _reloadAll();
      if (mounted) setState(() => _message = 'Канал удалён');
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка удаления канала: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveChannelSettings({
    required String channelId,
    required String title,
    required String description,
    required String visibility,
    required double avatarFocusX,
    required double avatarFocusY,
    required bool isMain,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      if (mounted) {
        setState(() => _message = 'Название канала не может быть пустым');
      }
      return;
    }

    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      final payload = {
        'title': cleanTitle,
        'description': description.trim(),
        'avatar_focus_x': avatarFocusX,
        'avatar_focus_y': avatarFocusY,
        if (!isMain) 'visibility': visibility,
      };
      final resp = await authService.dio.patch(
        '/api/admin/channels/$channelId',
        data: payload,
      );
      _emitChatUpdatedIfPresent(resp.data);
      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) {
        setState(() => _message = 'Настройки канала сохранены');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка сохранения канала: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_AvatarPlacementResult?> _showAvatarPlacementDialog({
    required String filePath,
    required double initialFocusX,
    required double initialFocusY,
    required double initialZoom,
  }) async {
    final imageFile = File(filePath);
    final sourceBytes = await imageFile.readAsBytes();
    final source = img.decodeImage(sourceBytes);
    if (source == null) {
      if (mounted) {
        setState(() => _message = 'Не удалось прочитать изображение');
      }
      return null;
    }

    return showDialog<_AvatarPlacementResult>(
      context: context,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        final maxDialogWidth = media.size.width - 40;
        final maxDialogHeight = media.size.height - 160;
        final dialogWidth = maxDialogWidth.clamp(280.0, 420.0);
        final previewByWidth = (dialogWidth - 32).clamp(220.0, 340.0);
        final previewByHeight = (maxDialogHeight - 180).clamp(180.0, 340.0);
        final previewSize = math.min(previewByWidth, previewByHeight);
        final cutoutSize = (previewSize * 0.58).clamp(110.0, 190.0).toDouble();

        final baseScale = math.max(
          previewSize / source.width,
          previewSize / source.height,
        );
        final minZoom = math
            .max(
              cutoutSize / (source.width * baseScale),
              cutoutSize / (source.height * baseScale),
            )
            .clamp(0.2, 1.0)
            .toDouble();
        const maxZoom = 4.0;
        final initialRenderedWidth = source.width * baseScale * initialZoom;
        final initialRenderedHeight = source.height * baseScale * initialZoom;
        final initialMaxX = math.max(
          0.0,
          (initialRenderedWidth - cutoutSize) / 2,
        );
        final initialMaxY = math.max(
          0.0,
          (initialRenderedHeight - cutoutSize) / 2,
        );

        var offset = Offset(
          initialFocusX.clamp(-1.0, 1.0) * initialMaxX,
          initialFocusY.clamp(-1.0, 1.0) * initialMaxY,
        );
        var zoom = initialZoom.clamp(minZoom, maxZoom).toDouble();
        offset = _clampAvatarOffset(
          offset: offset,
          sourceWidth: source.width,
          sourceHeight: source.height,
          previewSize: previewSize,
          cutoutSize: cutoutSize,
          zoom: zoom,
        );

        var scaleBase = zoom;
        var startOffset = offset;
        var startFocal = Offset.zero;
        var exporting = false;
        var localError = '';

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Text('Позиция аватарки'),
              content: SizedBox(
                width: dialogWidth,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Тяните фото для позиции. Колесо мыши или щипок меняет масштаб.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Listener(
                        onPointerSignal: (event) {
                          if (event is! PointerScrollEvent) return;
                          setModalState(() {
                            final next =
                                zoom +
                                (event.scrollDelta.dy > 0 ? -0.08 : 0.08);
                            zoom = next.clamp(minZoom, maxZoom).toDouble();
                            offset = _clampAvatarOffset(
                              offset: offset,
                              sourceWidth: source.width,
                              sourceHeight: source.height,
                              previewSize: previewSize,
                              cutoutSize: cutoutSize,
                              zoom: zoom,
                            );
                          });
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (details) {
                            scaleBase = zoom;
                            startOffset = offset;
                            startFocal = details.localFocalPoint;
                          },
                          onScaleUpdate: (details) {
                            setModalState(() {
                              zoom = (scaleBase * details.scale)
                                  .clamp(minZoom, maxZoom)
                                  .toDouble();
                              final translated =
                                  details.localFocalPoint - startFocal;
                              offset = _clampAvatarOffset(
                                offset: startOffset + translated,
                                sourceWidth: source.width,
                                sourceHeight: source.height,
                                previewSize: previewSize,
                                cutoutSize: cutoutSize,
                                zoom: zoom,
                              );
                            });
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: SizedBox(
                              width: previewSize,
                              height: previewSize,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(color: Colors.black12),
                                  Transform.translate(
                                    offset: offset,
                                    child: Transform.scale(
                                      scale: zoom,
                                      child: Image.file(
                                        imageFile,
                                        width: previewSize,
                                        height: previewSize,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                  CustomPaint(
                                    painter: _CircleCutoutPainter(
                                      cutoutRadius: cutoutSize / 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Масштаб: ${(zoom * 100).round()}%',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Уменьшить',
                            onPressed: () {
                              setModalState(() {
                                zoom = (zoom - 0.1).clamp(minZoom, maxZoom);
                                offset = _clampAvatarOffset(
                                  offset: offset,
                                  sourceWidth: source.width,
                                  sourceHeight: source.height,
                                  previewSize: previewSize,
                                  cutoutSize: cutoutSize,
                                  zoom: zoom,
                                );
                              });
                            },
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          IconButton(
                            tooltip: 'Увеличить',
                            onPressed: () {
                              setModalState(() {
                                zoom = (zoom + 0.1).clamp(minZoom, maxZoom);
                                offset = _clampAvatarOffset(
                                  offset: offset,
                                  sourceWidth: source.width,
                                  sourceHeight: source.height,
                                  previewSize: previewSize,
                                  cutoutSize: cutoutSize,
                                  zoom: zoom,
                                );
                              });
                            },
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                      Slider(
                        value: zoom,
                        min: minZoom,
                        max: maxZoom,
                        divisions: ((maxZoom - minZoom) * 20).round().clamp(
                          1,
                          100,
                        ),
                        onChanged: (v) {
                          setModalState(() {
                            zoom = v;
                            offset = _clampAvatarOffset(
                              offset: offset,
                              sourceWidth: source.width,
                              sourceHeight: source.height,
                              previewSize: previewSize,
                              cutoutSize: cutoutSize,
                              zoom: zoom,
                            );
                          });
                        },
                      ),
                      if (localError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            localError,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: exporting ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: exporting
                      ? null
                      : () {
                          setModalState(() {
                            zoom = 1.0.clamp(minZoom, maxZoom).toDouble();
                            offset = Offset.zero;
                            localError = '';
                          });
                        },
                  child: const Text('Сброс'),
                ),
                ElevatedButton(
                  onPressed: exporting
                      ? null
                      : () async {
                          setModalState(() {
                            exporting = true;
                            localError = '';
                          });
                          try {
                            final croppedPath = await _exportAvatarCrop(
                              sourcePath: filePath,
                              sourceWidth: source.width,
                              sourceHeight: source.height,
                              previewSize: previewSize,
                              cutoutSize: cutoutSize,
                              offset: offset,
                              zoom: zoom,
                            );
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop(
                              _AvatarPlacementResult(croppedPath: croppedPath),
                            );
                          } catch (_) {
                            setModalState(() {
                              exporting = false;
                              localError = 'Не удалось подготовить аватарку';
                            });
                          }
                        },
                  child: exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Использовать'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _pickAndUploadChannelAvatar(Map<String, dynamic> channel) async {
    final channelId = _channelIdOf(channel);
    if (channelId.isEmpty) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.single.path;
    if (path == null || path.isEmpty) {
      if (mounted) {
        setState(() => _message = 'Не удалось получить путь к файлу');
      }
      return;
    }

    final settings = _settingsOf(channel);
    final placement = await _showAvatarPlacementDialog(
      filePath: path,
      initialFocusX: _toFocus(settings['avatar_focus_x']),
      initialFocusY: _toFocus(settings['avatar_focus_y']),
      initialZoom: _toAvatarZoom(settings['avatar_zoom']),
    );
    if (placement == null) return;

    setState(() {
      _avatarUpdating = true;
      _message = '';
    });
    try {
      final uploadPath = placement.croppedPath;
      final fileName = uploadPath.split(Platform.pathSeparator).last;
      final form = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(uploadPath, filename: fileName),
      });
      final resp = await authService.dio.post(
        '/api/admin/channels/$channelId/avatar',
        data: form,
      );
      _emitChatUpdatedIfPresent(resp.data);

      await authService.dio.patch(
        '/api/admin/channels/$channelId',
        data: {'avatar_focus_x': 0, 'avatar_focus_y': 0, 'avatar_zoom': 1},
      );

      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) setState(() => _message = 'Аватарка канала обновлена');
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка загрузки аватарки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _avatarUpdating = false);
      try {
        await File(placement.croppedPath).delete();
      } catch (_) {}
    }
  }

  Future<void> _removeChannelAvatar(String channelId) async {
    setState(() {
      _avatarUpdating = true;
      _message = '';
    });
    try {
      final resp = await authService.dio.delete(
        '/api/admin/channels/$channelId/avatar',
      );
      _emitChatUpdatedIfPresent(resp.data);
      await _loadChannels();
      await _loadChannelOverview(channelId, force: true, silent: true);
      if (mounted) setState(() => _message = 'Аватарка канала удалена');
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка удаления аватарки: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _avatarUpdating = false);
    }
  }

  Future<void> _addToBlacklist(String channelId, String userId) async {
    if (_blacklistBusy.contains(channelId)) return;
    setState(() => _blacklistBusy.add(channelId));
    try {
      final resp = await authService.dio.post(
        '/api/admin/channels/$channelId/blacklist',
        data: {'user_id': userId},
      );
      final data = resp.data;
      if (data is Map &&
          data['data'] is Map &&
          data['data']['channel'] is Map) {
        chatEventsController.add({
          'type': 'chat:updated',
          'data': {'chat': Map<String, dynamic>.from(data['data']['channel'])},
        });
      }
      await _loadChannelOverview(channelId, force: true, silent: true);
      await _loadChannels();
      if (mounted) {
        setState(() => _message = 'Пользователь добавлен в черный список');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка черного списка: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _blacklistBusy.remove(channelId));
    }
  }

  Future<void> _removeFromBlacklist(String channelId, String userId) async {
    if (_blacklistBusy.contains(channelId)) return;
    setState(() => _blacklistBusy.add(channelId));
    try {
      final resp = await authService.dio.delete(
        '/api/admin/channels/$channelId/blacklist/$userId',
      );
      final data = resp.data;
      if (data is Map &&
          data['data'] is Map &&
          data['data']['channel'] is Map) {
        chatEventsController.add({
          'type': 'chat:updated',
          'data': {'chat': Map<String, dynamic>.from(data['data']['channel'])},
        });
      }
      await _loadChannelOverview(channelId, force: true, silent: true);
      await _loadChannels();
      if (mounted) {
        setState(() => _message = 'Пользователь убран из черного списка');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Ошибка черного списка: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _blacklistBusy.remove(channelId));
    }
  }

  Future<void> _dispatchClientOrders() async {
    setState(() {
      _dispatchingOrders = true;
      _message = '';
      _lastDispatchedOrders = [];
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/orders/dispatch_reserved',
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data']);
        final orders = payload['orders'] is List
            ? List<Map<String, dynamic>>.from(payload['orders'])
            : <Map<String, dynamic>>[];
        if (mounted) {
          setState(() {
            _lastDispatchedOrders = orders;
            _message = orders.isEmpty
                ? 'Новых заказов клиентов нет'
                : 'Заказы клиентов отправлены: ${orders.length}';
          });
        }
      } else {
        if (mounted) {
          setState(() => _message = 'Не удалось отправить заказы клиентов');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message =
              'Ошибка отправки заказов клиентов: ${_extractDioError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _dispatchingOrders = false);
    }
  }

  String _extractDioError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final text = (data['error'] ?? data['message'] ?? '').toString().trim();
        if (text.isNotEmpty) return text;
      }
      return e.message ?? 'Ошибка запроса';
    }
    return e.toString();
  }

  Future<void> _publishPendingPosts() async {
    setState(() {
      _publishing = true;
      _message = '';
      _lastPublished = [];
    });
    try {
      final resp = await authService.dio.post(
        '/api/admin/channels/publish_pending',
        data: {
          if (_pendingFilterChannelId != null &&
              _pendingFilterChannelId!.isNotEmpty)
            'channel_id': _pendingFilterChannelId,
        },
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final published = data['data'] is List
            ? List<Map<String, dynamic>>.from(data['data'])
            : <Map<String, dynamic>>[];
        if (mounted) {
          setState(() {
            _lastPublished = published;
            _message = published.isEmpty
                ? 'Нет постов для публикации'
                : 'Опубликовано постов: ${published.length}. ID товаров выведены ниже.';
          });
        }
        await _loadPendingPosts();
      } else {
        if (mounted) {
          setState(() => _message = 'Не удалось опубликовать посты');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Ошибка публикации: ${_extractDioError(e)}');
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _openChannelSettingsDialog(Map<String, dynamic> channel) async {
    final id = _channelIdOf(channel);
    if (id.isEmpty) return;

    final settings = _settingsOf(channel);
    final systemKey = (settings['system_key'] ?? '').toString();
    final isMain = systemKey == 'main_channel';

    final titleCtrl = TextEditingController(
      text: (channel['title'] ?? 'Канал').toString(),
    );
    final descCtrl = TextEditingController(
      text: (settings['description'] ?? '').toString(),
    );
    var visibility =
        (settings['visibility'] ?? 'public').toString() == 'private'
        ? 'private'
        : 'public';
    var focusX = _toFocus(settings['avatar_focus_x']);
    var focusY = _toFocus(settings['avatar_focus_y']);
    final zoom = _toAvatarZoom(settings['avatar_zoom']);
    final avatarUrl = _resolveImageUrl(
      (settings['avatar_url'] ?? '').toString(),
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        var saving = false;
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: Text(
                'Настройки: ${(channel['title'] ?? 'Канал').toString()}',
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: _buildChannelAvatar(
                          title: titleCtrl.text.trim().isEmpty
                              ? (channel['title'] ?? 'Канал').toString()
                              : titleCtrl.text,
                          imageUrl: avatarUrl,
                          focusX: focusX,
                          focusY: focusY,
                          zoom: zoom,
                          radius: 34,
                          fallbackIcon: Icons.campaign_outlined,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Название канала',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setModalState(() {}),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: descCtrl,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Описание',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (!isMain)
                        DropdownButtonFormField<String>(
                          value: visibility,
                          decoration: const InputDecoration(
                            labelText: 'Тип канала',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'public',
                              child: Text('Публичный'),
                            ),
                            DropdownMenuItem(
                              value: 'private',
                              child: Text('Частный'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setModalState(() => visibility = v);
                          },
                        )
                      else
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Основной канал всегда публичный. Изменение типа отключено.',
                          ),
                        ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Позиция аватарки задается на этапе загрузки фото перетаскиванием.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Отмена'),
                ),
                ElevatedButton.icon(
                  onPressed: saving
                      ? null
                      : () async {
                          setModalState(() => saving = true);
                          await _saveChannelSettings(
                            channelId: id,
                            title: titleCtrl.text,
                            description: descCtrl.text,
                            visibility: visibility,
                            avatarFocusX: focusX,
                            avatarFocusY: focusY,
                            isMain: isMain,
                          );
                          if (!mounted) return;
                          if (Navigator.of(ctx).canPop()) {
                            Navigator.of(ctx).pop();
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(saving ? 'Сохранение...' : 'Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    titleCtrl.dispose();
    descCtrl.dispose();
  }

  Future<void> _openClientsDialog(String channelId, String channelTitle) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final clients = _asMapList(overview['clients']);
    final stats = _asMap(overview['stats']);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Клиенты канала "$channelTitle"'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: clients.isEmpty
              ? const Center(child: Text('Клиенты не найдены'))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Всего клиентов: ${_toInt(stats['clients_total'])}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        itemCount: clients.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final c = clients[index];
                          final blocked = c['is_blacklisted'] == true;
                          final phone = (c['phone'] ?? '').toString().trim();
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              child: Text(
                                _displayName(
                                  c,
                                  fallback: 'Клиент',
                                )[0].toUpperCase(),
                              ),
                            ),
                            title: Text(_displayName(c, fallback: 'Клиент')),
                            subtitle: Text(
                              [
                                (c['email'] ?? '').toString(),
                                if (phone.isNotEmpty) 'Тел: $phone',
                              ].where((v) => v.trim().isNotEmpty).join('\n'),
                            ),
                            isThreeLine: phone.isNotEmpty,
                            trailing: blocked
                                ? const Icon(Icons.block, color: Colors.red)
                                : null,
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openMediaDialog(String channelId, String channelTitle) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final media = _asMapList(overview['media']);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Медиа канала "$channelTitle"'),
        content: SizedBox(
          width: 680,
          height: 480,
          child: media.isEmpty
              ? const Center(child: Text('В канале пока нет медиа'))
              : GridView.builder(
                  itemCount: media.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.86,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final item = media[index];
                    final url = _resolveImageUrl(
                      (item['image_url'] ?? '').toString(),
                    );
                    final caption = (item['text'] ?? '').toString().trim();
                    return Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10),
                              ),
                              child: url == null
                                  ? Container(
                                      color: Colors.grey.shade200,
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.image_not_supported_outlined,
                                      ),
                                    )
                                  : Image.network(
                                      url,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              caption.isEmpty ? 'Без подписи' : caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBlacklistDialog(
    String channelId,
    String channelTitle,
  ) async {
    final overview = await _loadChannelOverview(channelId, force: true);
    if (!mounted || overview == null) return;

    final blacklist = _asMapList(overview['blacklist']);
    final clients = _asMapList(overview['clients']);
    final blacklistedIds = blacklist
        .map((b) => (b['user_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final candidates = clients
        .where((c) => !blacklistedIds.contains((c['user_id'] ?? '').toString()))
        .take(80)
        .toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Черный список "$channelTitle"'),
        content: SizedBox(
          width: 620,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Заблокировано: ${blacklist.length}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: blacklist.isEmpty
                    ? const Center(child: Text('Черный список пуст'))
                    : ListView.separated(
                        itemCount: blacklist.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final item = blacklist[i];
                          final user = _asMap(item['user']);
                          final userId = (item['user_id'] ?? '').toString();
                          final title = user.isEmpty
                              ? userId
                              : _displayName(user, fallback: userId);
                          return ListTile(
                            dense: true,
                            title: Text(title),
                            subtitle: Text(
                              [
                                (user['email'] ?? '').toString(),
                                (user['phone'] ?? '').toString(),
                              ].where((v) => v.trim().isNotEmpty).join('\n'),
                            ),
                            isThreeLine: ((user['phone'] ?? '')
                                .toString()
                                .trim()
                                .isNotEmpty),
                            trailing: IconButton(
                              tooltip: 'Разблокировать',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: _blacklistBusy.contains(channelId)
                                  ? null
                                  : () async {
                                      Navigator.of(ctx).pop();
                                      await _removeFromBlacklist(
                                        channelId,
                                        userId,
                                      );
                                      if (!mounted) return;
                                      await _openBlacklistDialog(
                                        channelId,
                                        channelTitle,
                                      );
                                    },
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Добавить клиента в черный список:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 150,
                child: candidates.isEmpty
                    ? const Center(
                        child: Text('Нет доступных клиентов для добавления'),
                      )
                    : ListView.builder(
                        itemCount: candidates.length,
                        itemBuilder: (context, i) {
                          final c = candidates[i];
                          final userId = (c['user_id'] ?? '').toString();
                          return ListTile(
                            dense: true,
                            title: Text(_displayName(c, fallback: 'Клиент')),
                            subtitle: Text((c['email'] ?? '').toString()),
                            trailing: IconButton(
                              tooltip: 'Заблокировать',
                              icon: const Icon(Icons.block, color: Colors.red),
                              onPressed: _blacklistBusy.contains(channelId)
                                  ? null
                                  : () async {
                                      Navigator.of(ctx).pop();
                                      await _addToBlacklist(channelId, userId);
                                      if (!mounted) return;
                                      await _openBlacklistDialog(
                                        channelId,
                                        channelTitle,
                                      );
                                    },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label: $value'),
    );
  }

  Widget _buildChannelAvatar({
    required String title,
    required String? imageUrl,
    required double focusX,
    required double focusY,
    required double zoom,
    required double radius,
    required IconData fallbackIcon,
  }) {
    final initials = title.trim().isEmpty
        ? '?'
        : title
              .trim()
              .split(' ')
              .where((part) => part.isNotEmpty)
              .map((part) => part[0])
              .take(2)
              .join()
              .toUpperCase();

    if (imageUrl == null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.grey.shade200,
        child: initials == '?'
            ? Icon(fallbackIcon, color: Colors.grey.shade700)
            : Text(initials),
      );
    }

    final size = radius * 2;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey.shade200,
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment(focusX, focusY),
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              alignment: Alignment(focusX, focusY),
              errorBuilder: (_, __, ___) => Center(
                child: Text(
                  initials,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCreateTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _channelTitleCtrl,
          decoration: const InputDecoration(
            labelText: 'Название канала',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _channelDescriptionCtrl,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Описание канала (опционально)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _newChannelVisibility,
          decoration: const InputDecoration(
            labelText: 'Тип нового канала',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: 'public',
              child: Text('Публичный (видят все)'),
            ),
            DropdownMenuItem(
              value: 'private',
              child: Text('Частный (для рабочих/админов)'),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _newChannelVisibility = v);
          },
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _saving ? null : _createChannel,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add),
            label: Text(_saving ? 'Создание...' : 'Создать канал'),
          ),
        ),
      ],
    );
  }

  Widget _buildChannelCard(Map<String, dynamic> channel) {
    final id = _channelIdOf(channel);
    final title = (channel['title'] ?? 'Канал').toString();
    final settings = _settingsOf(channel);
    final description = (settings['description'] ?? '').toString();
    final visibility =
        (settings['visibility'] ?? 'public').toString() == 'private'
        ? 'private'
        : 'public';
    final avatarUrl = _resolveImageUrl(
      (settings['avatar_url'] ?? '').toString(),
    );
    final systemKey = (settings['system_key'] ?? '').toString();
    final isMain = systemKey == 'main_channel';
    final canDelete = !isMain;
    final focusX = _toFocus(settings['avatar_focus_x']);
    final focusY = _toFocus(settings['avatar_focus_y']);
    final avatarZoom = _toAvatarZoom(settings['avatar_zoom']);

    final overview = _channelOverviews[id];
    final overviewStats = _asMap(overview?['stats']);
    final overviewMedia = _asMapList(overview?['media']);
    final overviewBlacklist = _asMapList(overview?['blacklist']);

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded) {
            unawaited(_loadChannelOverview(id, silent: true));
          }
        },
        leading: _buildChannelAvatar(
          title: title,
          imageUrl: avatarUrl,
          focusX: focusX,
          focusY: focusY,
          zoom: avatarZoom,
          radius: 20,
          fallbackIcon: Icons.campaign_outlined,
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          isMain
              ? 'Основной канал • всегда публичный'
              : (visibility == 'private' ? 'Частный канал' : 'Публичный канал'),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (description.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  description,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => _openChannelSettingsDialog(channel),
                icon: const Icon(Icons.tune),
                label: const Text('Настроить'),
              ),
              OutlinedButton.icon(
                onPressed: _avatarUpdating
                    ? null
                    : () => _pickAndUploadChannelAvatar(channel),
                icon: const Icon(Icons.image_outlined),
                label: const Text('Аватарка'),
              ),
              if (avatarUrl != null)
                OutlinedButton.icon(
                  onPressed: _avatarUpdating
                      ? null
                      : () => _removeChannelAvatar(id),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Убрать фото'),
                ),
              OutlinedButton.icon(
                onPressed: _overviewLoading.contains(id)
                    ? null
                    : () => _loadChannelOverview(id, force: true),
                icon: const Icon(Icons.analytics_outlined),
                label: Text(
                  _overviewLoading.contains(id)
                      ? 'Загрузка...'
                      : 'Обновить данные',
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: id));
                  setState(() => _message = 'ID канала скопирован');
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Скопировать ID'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_overviewLoading.contains(id) &&
              !_channelOverviews.containsKey(id))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            )
          else if (overview != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildStatChip(
                  'Клиенты',
                  _toInt(overviewStats['clients_total']).toString(),
                ),
                _buildStatChip(
                  'Участники',
                  _toInt(overviewStats['members_total']).toString(),
                ),
                _buildStatChip(
                  'Медиа',
                  _toInt(overviewStats['media_total']).toString(),
                ),
                _buildStatChip(
                  'Сообщения',
                  _toInt(overviewStats['messages_total']).toString(),
                ),
                _buildStatChip(
                  'За 24ч',
                  _toInt(overviewStats['messages_24h']).toString(),
                ),
                _buildStatChip(
                  'Черный список',
                  _toInt(overviewStats['blacklisted_total']).toString(),
                ),
                _buildStatChip(
                  'В очереди',
                  _toInt(overviewStats['pending_posts_total']).toString(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _openClientsDialog(id, title),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Список клиентов'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _openMediaDialog(id, title),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Список медиа'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _openBlacklistDialog(id, title),
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('Черный список'),
                ),
              ],
            ),
            if (overviewMedia.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Последние фото:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: overviewMedia.length > 8
                      ? 8
                      : overviewMedia.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final item = overviewMedia[i];
                    final url = _resolveImageUrl(
                      (item['image_url'] ?? '').toString(),
                    );
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 72,
                        child: url == null
                            ? Container(
                                color: Colors.grey.shade200,
                                child: const Icon(
                                  Icons.image_not_supported_outlined,
                                ),
                              )
                            : Image.network(url, fit: BoxFit.cover),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (overviewBlacklist.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'В черном списке:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: overviewBlacklist.take(6).map((entry) {
                  final user = _asMap(entry['user']);
                  final userId = (entry['user_id'] ?? '').toString();
                  final label = user.isEmpty
                      ? userId
                      : _displayName(user, fallback: userId);
                  return Chip(
                    label: Text(label),
                    onDeleted: _blacklistBusy.contains(id)
                        ? null
                        : () => _removeFromBlacklist(id, userId),
                  );
                }).toList(),
              ),
            ],
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _saving
                  ? null
                  : (!canDelete ? null : () => _deleteChannel(id, title)),
              icon: Icon(
                Icons.delete_outline,
                color: canDelete ? Colors.red : Colors.grey,
              ),
              label: Text(
                canDelete ? 'Удалить канал' : 'Системный канал',
                style: TextStyle(color: canDelete ? Colors.red : Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_channels.isEmpty) {
      return const Center(child: Text('Каналы пока не созданы'));
    }

    return RefreshIndicator(
      onRefresh: _reloadAll,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _channels.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _buildChannelCard(_channels[index]),
      ),
    );
  }

  Widget _buildModerationTab() {
    return RefreshIndicator(
      onRefresh: _loadPendingPosts,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_channels.isNotEmpty)
            DropdownButtonFormField<String>(
              value: _pendingFilterChannelId,
              decoration: const InputDecoration(
                labelText: 'Фильтр по каналу',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Все каналы'),
                ),
                ..._channels.map(
                  (c) => DropdownMenuItem<String>(
                    value: c['id']?.toString(),
                    child: Text((c['title'] ?? 'Канал').toString()),
                  ),
                ),
              ],
              onChanged: (v) async {
                setState(() => _pendingFilterChannelId = v);
                await _loadPendingPosts();
              },
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _publishing ? null : _publishPendingPosts,
              icon: _publishing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.campaign),
              label: Text(
                _publishing ? 'Публикация...' : 'Отправить посты на каналы',
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _dispatchingOrders ? null : _dispatchClientOrders,
              icon: _dispatchingOrders
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.assignment_turned_in_outlined),
              label: Text(
                _dispatchingOrders ? 'Отправка заказов...' : 'Заказы клиентов',
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_pendingPosts.isEmpty)
            const Text('Очередь пустая')
          else
            ..._pendingPosts.map((p) {
              final title = (p['product_title'] ?? 'Товар').toString();
              final price = p['product_price']?.toString() ?? '0';
              final qty = p['product_quantity']?.toString() ?? '0';
              final channel = (p['channel_title'] ?? 'Канал').toString();
              final workerEmail = (p['queued_by_email'] ?? 'worker').toString();
              return Card(
                child: ListTile(
                  title: Text(title),
                  subtitle: Text(
                    'Канал: $channel\nWorker: $workerEmail\nЦена: $price RUB, Кол-во: $qty',
                  ),
                  isThreeLine: true,
                ),
              );
            }),
          if (_lastPublished.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Опубликованные товары и их ID:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._lastPublished.map((item) {
              final channelTitle = (item['channel_title'] ?? 'Канал')
                  .toString();
              final productCode = item['product_code']?.toString() ?? '—';
              final productId = item['product_id']?.toString() ?? '—';
              return Card(
                child: ListTile(
                  title: Text('ID товара: $productCode'),
                  subtitle: Text('Канал: $channelTitle\nDB ID: $productId'),
                ),
              );
            }),
          ],
          if (_lastDispatchedOrders.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Отправленные заказы клиентов:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._lastDispatchedOrders.map((item) {
              final clientName = (item['client_name'] ?? '—').toString();
              final productCode = (item['product_code'] ?? '—').toString();
              final quantity = (item['quantity'] ?? '—').toString();
              final shelf = (item['shelf_number'] ?? 'не назначена').toString();
              return Card(
                child: ListTile(
                  title: Text('Клиент: $clientName'),
                  subtitle: Text(
                    'ID товара: $productCode\n'
                    'Количество: $quantity\n'
                    'Полка: $shelf',
                  ),
                  isThreeLine: true,
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Админ-панель'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Создание'),
            Tab(text: 'Каналы'),
            Tab(text: 'Модерация'),
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
                children: [
                  _buildCreateTab(),
                  _buildSettingsTab(),
                  _buildModerationTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarPlacementResult {
  const _AvatarPlacementResult({required this.croppedPath});

  final String croppedPath;
}

class _CircleCutoutPainter extends CustomPainter {
  const _CircleCutoutPainter({required this.cutoutRadius});

  final double cutoutRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final overlayPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: cutoutRadius));

    canvas.drawPath(
      overlayPath,
      Paint()..color = Colors.black.withValues(alpha: 0.38),
    );

    canvas.drawCircle(
      center,
      cutoutRadius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.86)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleCutoutPainter oldDelegate) {
    return oldDelegate.cutoutRadius != cutoutRadius;
  }
}
