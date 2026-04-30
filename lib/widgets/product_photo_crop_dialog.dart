import 'dart:async';
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phoenix_crop_core.dart';

const String _workerCropPresetKey = 'worker_product_photo_crop_preset_v1';
const List<PhoenixPostCropPreset> _workerCropPresets = <PhoenixPostCropPreset>[
  PhoenixPostCropPreset.square,
  PhoenixPostCropPreset.portrait,
  PhoenixPostCropPreset.uncropped,
];

class ProductPhotoCropResult {
  const ProductPhotoCropResult({
    required this.bytes,
    required this.fileName,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String fileName;
  final int width;
  final int height;
}

Future<ProductPhotoCropResult?> showProductPhotoCropDialog({
  required BuildContext context,
  required Uint8List sourceBytes,
  required String originalFileName,
  PhoenixPostCropPreset initialPreset = PhoenixPostCropPreset.square,
}) async {
  final prepared = prepareImageForEditing(sourceBytes);
  final rememberedPreset = await _loadRememberedWorkerCropPreset(
    fallback: initialPreset,
  );
  if (!context.mounted) return null;
  return Navigator.of(context).push<ProductPhotoCropResult>(
    MaterialPageRoute<ProductPhotoCropResult>(
      fullscreenDialog: true,
      builder: (_) => _ProductPhotoCropEditorScreen(
        prepared: prepared,
        originalFileName: originalFileName,
        initialPreset: rememberedPreset,
      ),
    ),
  );
}

Future<PhoenixPostCropPreset> _loadRememberedWorkerCropPreset({
  required PhoenixPostCropPreset fallback,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_workerCropPresetKey)?.trim() ?? '';
    final matched = PhoenixPostCropPreset.values.where((preset) {
      return preset.name == raw && _workerCropPresets.contains(preset);
    });
    if (matched.isNotEmpty) {
      return matched.first;
    }
  } catch (_) {}
  return _workerCropPresets.contains(fallback)
      ? fallback
      : PhoenixPostCropPreset.square;
}

Future<void> _rememberWorkerCropPreset(PhoenixPostCropPreset preset) async {
  if (!_workerCropPresets.contains(preset)) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_workerCropPresetKey, preset.name);
  } catch (_) {}
}

String _workerPresetLabel(PhoenixPostCropPreset preset) => switch (preset) {
  PhoenixPostCropPreset.square => 'Квадрат',
  PhoenixPostCropPreset.portrait => '4:5',
  PhoenixPostCropPreset.uncropped => 'Оригинал',
  PhoenixPostCropPreset.wide => '16:9',
};

class _ProductPhotoCropEditorScreen extends StatefulWidget {
  const _ProductPhotoCropEditorScreen({
    required this.prepared,
    required this.originalFileName,
    required this.initialPreset,
  });

  final PhoenixPreparedImage prepared;
  final String originalFileName;
  final PhoenixPostCropPreset initialPreset;

  @override
  State<_ProductPhotoCropEditorScreen> createState() =>
      _ProductPhotoCropEditorScreenState();
}

class _ProductPhotoCropEditorScreenState
    extends State<_ProductPhotoCropEditorScreen> {
  final CropController _controller = CropController();
  late PhoenixPostCropPreset _preset = widget.initialPreset;
  bool _exporting = false;
  String _localError = '';

  double get _sourceAspectRatio {
    final width = widget.prepared.width <= 0 ? 1 : widget.prepared.width;
    final height = widget.prepared.height <= 0 ? 1 : widget.prepared.height;
    return width / height;
  }

  void _closeEditor() {
    if (_exporting) return;
    Navigator.of(context).pop();
  }

  void _resetEditor() {
    if (_exporting) return;
    _controller.withCircleUi = false;
    _controller.aspectRatio = _preset.aspectRatio;
    _controller.image = widget.prepared.bytes;
    setState(() {
      _localError = '';
    });
  }

  void _applyPreset(PhoenixPostCropPreset preset) {
    if (_exporting || _preset == preset) return;
    setState(() {
      _preset = preset;
      _localError = '';
    });
    unawaited(_rememberWorkerCropPreset(preset));
    if (preset != PhoenixPostCropPreset.uncropped) {
      _controller.withCircleUi = false;
      _controller.aspectRatio = preset.aspectRatio;
      _controller.image = widget.prepared.bytes;
    }
  }

  void _finishWithoutCrop() {
    final preparedUpload = buildPostUploadImage(
      widget.prepared.bytes,
      widget.originalFileName,
      cropped: false,
    );
    Navigator.of(context).pop(
      ProductPhotoCropResult(
        bytes: preparedUpload.bytes,
        fileName: preparedUpload.fileName,
        width: preparedUpload.width,
        height: preparedUpload.height,
      ),
    );
  }

  void _applyCrop() {
    if (_preset == PhoenixPostCropPreset.uncropped) {
      _finishWithoutCrop();
      return;
    }
    setState(() {
      _exporting = true;
      _localError = '';
    });
    _controller.crop();
  }

  Size _resolveViewportSize(BoxConstraints constraints) {
    final availableWidth = constraints.maxWidth;
    final availableHeight = constraints.maxHeight;
    final minWidth = availableWidth < 220 ? availableWidth : 220.0;
    final minHeight = availableHeight < 220 ? availableHeight : 220.0;
    final effectiveAspectRatio = _preset == PhoenixPostCropPreset.uncropped
        ? _sourceAspectRatio
        : (_preset.aspectRatio ?? _sourceAspectRatio);

    var width = availableWidth;
    var height = width / effectiveAspectRatio;
    if (height > availableHeight) {
      height = availableHeight;
      width = height * effectiveAspectRatio;
    }

    return Size(
      width.clamp(minWidth, availableWidth).toDouble(),
      height.clamp(minHeight, availableHeight).toDouble(),
    );
  }

  Widget _buildWorkspace(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = _resolveViewportSize(constraints);
        return Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: viewportSize.width,
            height: viewportSize.height,
            decoration: BoxDecoration(
              color: const Color(0xFF141827),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 24,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _preset == PhoenixPostCropPreset.uncropped
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(
                        widget.prepared.bytes,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  )
                : PhoenixCropCore(
                    imageBytes: widget.prepared.bytes,
                    controller: _controller,
                    onCropped: (result) {
                      switch (result) {
                        case CropSuccess(:final croppedImage):
                          final preparedUpload = buildPostUploadImage(
                            croppedImage,
                            widget.originalFileName,
                            cropped: true,
                          );
                          if (!mounted) return;
                          Navigator.of(context).pop(
                            ProductPhotoCropResult(
                              bytes: preparedUpload.bytes,
                              fileName: preparedUpload.fileName,
                              width: preparedUpload.width,
                              height: preparedUpload.height,
                            ),
                          );
                        case CropFailure():
                          if (!mounted) return;
                          setState(() {
                            _exporting = false;
                            _localError = 'Не удалось обработать изображение';
                          });
                      }
                    },
                    aspectRatio: _preset.aspectRatio,
                    height: viewportSize.height,
                    width: viewportSize.width,
                    showGrid: true,
                    edgeHandleTopBottomTouchTarget: 58,
                    edgeHandleSideTouchTarget: 62,
                    edgeHandleVisualLength: 52,
                    edgeHandleVisualThickness: 10,
                    cornerHandlePadding: 14,
                    initialRectSize: 0.94,
                    maskOpacity: 0.62,
                    gridOpacity: 0.46,
                  ),
          ),
        );
      },
    );
  }

  Widget _buildPresetButton(
    BuildContext context,
    PhoenixPostCropPreset preset,
  ) {
    final theme = Theme.of(context);
    final selected = _preset == preset;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: ChoiceChip(
        label: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(_workerPresetLabel(preset)),
        ),
        selected: selected,
        onSelected: _exporting ? null : (_) => _applyPreset(preset),
        selectedColor: theme.colorScheme.primary,
        backgroundColor: const Color(0xFF1B2132),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.95)
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: selected
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        showCheckmark: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkTheme = theme.copyWith(
      scaffoldBackgroundColor: const Color(0xFF0B0E16),
      colorScheme: theme.colorScheme.copyWith(
        surface: const Color(0xFF121726),
        surfaceContainer: const Color(0xFF161C2A),
        surfaceContainerHighest: const Color(0xFF1B2132),
        onSurface: const Color(0xFFF3F5FA),
        onSurfaceVariant: const Color(0xFFA3ABC1),
      ),
    );

    return Theme(
      data: darkTheme,
      child: Material(
        color: darkTheme.scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _exporting ? null : _closeEditor,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Закрыть'),
                      style: TextButton.styleFrom(
                        foregroundColor: darkTheme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Фото товара',
                            style: darkTheme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            _preset == PhoenixPostCropPreset.uncropped
                                ? 'Оригинал без кадрирования'
                                : 'Подтверди кадр для публикации',
                            style: darkTheme.textTheme.bodySmall?.copyWith(
                              color: darkTheme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _exporting ? null : _applyCrop,
                      style: FilledButton.styleFrom(
                        backgroundColor: darkTheme.colorScheme.primary,
                        foregroundColor: darkTheme.colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                      ),
                      child: _exporting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Готово'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: _buildWorkspace(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF121726),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: _exporting ? null : _resetEditor,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Сброс'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: darkTheme.colorScheme.onSurface,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: _workerCropPresets
                                  .map(
                                    (preset) =>
                                        _buildPresetButton(context, preset),
                                  )
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _preset == PhoenixPostCropPreset.uncropped
                            ? 'Оставим фото целиком. Система только выровняет ориентацию и подготовит размер.'
                            : 'Тяни рамку и ручки. В пост уйдёт ровно этот кадр.',
                        style: darkTheme.textTheme.bodySmall?.copyWith(
                          color: darkTheme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      if (_localError.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          _localError,
                          style: darkTheme.textTheme.bodySmall?.copyWith(
                            color: darkTheme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
