import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import 'phoenix_crop_core.dart';

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
  if (!context.mounted) return null;
  return showDialog<ProductPhotoCropResult>(
    context: context,
    builder: (_) => _ProductPhotoCropDialog(
      prepared: prepared,
      originalFileName: originalFileName,
      initialPreset: initialPreset,
    ),
  );
}

class _ProductPhotoCropDialog extends StatefulWidget {
  const _ProductPhotoCropDialog({
    required this.prepared,
    required this.originalFileName,
    required this.initialPreset,
  });

  final PhoenixPreparedImage prepared;
  final String originalFileName;
  final PhoenixPostCropPreset initialPreset;

  @override
  State<_ProductPhotoCropDialog> createState() => _ProductPhotoCropDialogState();
}

class _ProductPhotoCropDialogState extends State<_ProductPhotoCropDialog> {
  final CropController _controller = CropController();
  late PhoenixPostCropPreset _preset = widget.initialPreset;
  bool _exporting = false;
  String _localError = '';

  void _resetEditor() {
    _controller.withCircleUi = false;
    _controller.aspectRatio = _preset.aspectRatio;
    _controller.image = widget.prepared.bytes;
    setState(() {
      _localError = '';
    });
  }

  void _applyPreset(PhoenixPostCropPreset preset) {
    setState(() {
      _preset = preset;
      _localError = '';
    });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final dialogWidth = (media.size.width - 34).clamp(300.0, 700.0);
    final cropAspect = _preset.aspectRatio ?? 1.0;
    final maxViewportHeight = (media.size.height - 340).clamp(220.0, 470.0);
    var viewportWidth = dialogWidth;
    var viewportHeight = viewportWidth / cropAspect;
    if (viewportHeight > maxViewportHeight) {
      viewportHeight = maxViewportHeight;
      viewportWidth = viewportHeight * cropAspect;
    }

    return AlertDialog(
      title: const Text('Фото товара'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Выберите кадр для поста. При желании можно сохранить фото целиком без обрезки.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: PhoenixPostCropPreset.values.map((preset) {
                  return ChoiceChip(
                    label: Text(preset.label),
                    selected: _preset == preset,
                    onSelected: _exporting ? null : (_) => _applyPreset(preset),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              Center(
                child: _preset == PhoenixPostCropPreset.uncropped
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          width: dialogWidth,
                          constraints: BoxConstraints(
                            minHeight: 220,
                            maxHeight: maxViewportHeight,
                          ),
                          color: theme.colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
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
                        height: viewportHeight,
                        width: viewportWidth,
                        showGrid: true,
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                _preset == PhoenixPostCropPreset.uncropped
                    ? 'Фото сохранится целиком. Мы только выровняем ориентацию и подготовим размер для загрузки.'
                    : 'Перемещайте и приближайте фото внутри рамки. Итоговый кадр будет таким же, как в редакторе.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_localError.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _localError,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: _exporting ? null : _resetEditor,
          child: const Text('Сбросить'),
        ),
        ElevatedButton(
          onPressed: _exporting ? null : _applyCrop,
          child: _exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _preset == PhoenixPostCropPreset.uncropped
                      ? 'Сохранить без обрезки'
                      : 'Готово',
                ),
        ),
      ],
    );
  }
}
