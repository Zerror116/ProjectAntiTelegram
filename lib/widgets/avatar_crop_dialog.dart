import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import 'phoenix_crop_core.dart';

class AvatarCropResult {
  const AvatarCropResult({
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

Future<AvatarCropResult?> showAvatarCropDialog({
  required BuildContext context,
  required Uint8List sourceBytes,
  required String originalFileName,
}) async {
  final prepared = prepareImageForEditing(sourceBytes, maxLongestSide: 2200);
  if (!context.mounted) return null;
  return showDialog<AvatarCropResult>(
    context: context,
    builder: (_) => _AvatarCropDialog(
      prepared: prepared,
      originalFileName: originalFileName,
    ),
  );
}

class _AvatarCropDialog extends StatefulWidget {
  const _AvatarCropDialog({
    required this.prepared,
    required this.originalFileName,
  });

  final PhoenixPreparedImage prepared;
  final String originalFileName;

  @override
  State<_AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<_AvatarCropDialog> {
  final CropController _controller = CropController();
  bool _exporting = false;
  String _localError = '';
  Rect _cropRect = Rect.zero;
  Rect _imageRect = Rect.zero;

  void _resetCrop() {
    _controller.withCircleUi = true;
    _controller.aspectRatio = 1.0;
    _controller.image = widget.prepared.bytes;
    setState(() {
      _localError = '';
      _cropRect = Rect.zero;
      _imageRect = Rect.zero;
    });
  }

  void _applyCrop() {
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
    final dialogWidth = (media.size.width - 28).clamp(300.0, 540.0);
    final editorSize = dialogWidth > 420
        ? 360.0
        : (dialogWidth - 32).clamp(260.0, 340.0);

    return AlertDialog(
      title: const Text('Обрезка аватарки'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Потяните рамку и белые ручки, чтобы выбрать, как аватарка будет выглядеть в профиле.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              PhoenixCropCore(
                imageBytes: widget.prepared.bytes,
                controller: _controller,
                onCropped: (result) {
                  switch (result) {
                    case CropSuccess(:final croppedImage):
                      final preparedUpload = buildAvatarUploadImage(
                        croppedImage,
                        widget.originalFileName,
                      );
                      if (!mounted) return;
                      Navigator.of(context).pop(
                        AvatarCropResult(
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
                        _localError = 'Не удалось подготовить аватарку';
                      });
                  }
                },
                aspectRatio: 1.0,
                withCircleUi: true,
                height: editorSize,
                width: editorSize,
                onMoved: (cropRect, imageRect) {
                  if (!mounted) return;
                  setState(() {
                    _cropRect = cropRect;
                    _imageRect = imageRect;
                  });
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Column(
                    children: [
                      Text(
                        'Как будет выглядеть',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      PhoenixAvatarLivePreview(
                        imageBytes: widget.prepared.bytes,
                        cropRect: _cropRect,
                        imageRect: _imageRect,
                        size: 92,
                      ),
                    ],
                  ),
                ],
              ),
              if (_localError.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _localError,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
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
          onPressed: _exporting ? null : _resetCrop,
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
              : const Text('Готово'),
        ),
      ],
    );
  }
}
