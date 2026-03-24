import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

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

Offset _clampCropOffset({
  required Offset offset,
  required int sourceWidth,
  required int sourceHeight,
  required double viewportWidth,
  required double viewportHeight,
  required double zoom,
}) {
  final baseScale = math.max(
    viewportWidth / sourceWidth,
    viewportHeight / sourceHeight,
  );
  final renderedWidth = sourceWidth * baseScale * zoom;
  final renderedHeight = sourceHeight * baseScale * zoom;

  final maxX = math.max(0.0, (renderedWidth - viewportWidth) / 2);
  final maxY = math.max(0.0, (renderedHeight - viewportHeight) / 2);

  return Offset(
    offset.dx.clamp(-maxX, maxX).toDouble(),
    offset.dy.clamp(-maxY, maxY).toDouble(),
  );
}

img.Image _cropViewport({
  required img.Image source,
  required double viewportWidth,
  required double viewportHeight,
  required Offset offset,
  required double zoom,
}) {
  final baseScale = math.max(
    viewportWidth / source.width,
    viewportHeight / source.height,
  );
  final effectiveScale = baseScale * zoom;
  final renderedWidth = source.width * effectiveScale;
  final renderedHeight = source.height * effectiveScale;

  final imageLeft = (viewportWidth - renderedWidth) / 2 + offset.dx;
  final imageTop = (viewportHeight - renderedHeight) / 2 + offset.dy;

  final srcXf = (0 - imageLeft) / effectiveScale;
  final srcYf = (0 - imageTop) / effectiveScale;
  final srcWf = viewportWidth / effectiveScale;
  final srcHf = viewportHeight / effectiveScale;

  final srcX = srcXf.floor().clamp(0, source.width - 1);
  final srcY = srcYf.floor().clamp(0, source.height - 1);
  final srcW = srcWf.ceil().clamp(1, source.width - srcX);
  final srcH = srcHf.ceil().clamp(1, source.height - srcY);

  return img.copyCrop(source, x: srcX, y: srcY, width: srcW, height: srcH);
}

img.Image _normalizeForUpload(img.Image source, {int maxLongestSide = 2600}) {
  final longestSide = math.max(source.width, source.height);
  if (longestSide <= maxLongestSide) return source;
  final scale = maxLongestSide / longestSide;
  final targetWidth = (source.width * scale).round().clamp(1, maxLongestSide);
  final targetHeight = (source.height * scale).round().clamp(1, maxLongestSide);
  return img.copyResize(
    source,
    width: targetWidth,
    height: targetHeight,
    interpolation: img.Interpolation.cubic,
  );
}

Uint8List _encodeTelegramLikeJpeg(img.Image source) {
  var working = _normalizeForUpload(source);
  const maxUploadBytes = 7 * 1024 * 1024;
  const qualitySteps = <int>[97, 95, 93, 90, 87, 84];

  for (final quality in qualitySteps) {
    final output = Uint8List.fromList(img.encodeJpg(working, quality: quality));
    if (output.lengthInBytes <= maxUploadBytes ||
        quality == qualitySteps.last) {
      return output;
    }
  }

  return Uint8List.fromList(img.encodeJpg(working, quality: 82));
}

String _buildCroppedFilename(String originalFileName) {
  final normalizedPath = originalFileName.replaceAll('\\', '/').trim();
  final lastSegment = normalizedPath.split('/').last.trim();
  final baseWithExt = lastSegment.isEmpty ? 'product-photo' : lastSegment;
  final dotIndex = baseWithExt.lastIndexOf('.');
  final base = dotIndex > 0 ? baseWithExt.substring(0, dotIndex) : baseWithExt;
  final safeBase = base
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  final clean = safeBase.isEmpty ? 'product-photo' : safeBase;
  return '${clean}_crop.jpg';
}

String _buildOriginalFilename(String originalFileName) {
  final normalizedPath = originalFileName.replaceAll('\\', '/').trim();
  final lastSegment = normalizedPath.split('/').last.trim();
  if (lastSegment.isEmpty) return 'product-photo.jpg';
  final safe = lastSegment
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  return safe.isEmpty ? 'product-photo.jpg' : safe;
}

Future<ProductPhotoCropResult?> showProductPhotoCropDialog({
  required BuildContext context,
  required Uint8List sourceBytes,
  required String originalFileName,
  double? cropAspectRatio,
}) async {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw Exception('Не удалось прочитать выбранное изображение');
  }
  final source = img.bakeOrientation(decoded);
  final fileName = _buildCroppedFilename(originalFileName);
  final passthroughFileName = _buildOriginalFilename(originalFileName);
  if (!context.mounted) return null;

  return showDialog<ProductPhotoCropResult>(
    context: context,
    builder: (dialogContext) {
      final media = MediaQuery.of(dialogContext);
      final maxDialogWidth = (media.size.width - 34).clamp(300.0, 680.0);
      final maxViewportHeight = (media.size.height - 320).clamp(220.0, 460.0);
      final sourceAspect = source.width > 0 && source.height > 0
          ? source.width / source.height
          : 1.0;
      final resolvedAspect =
          (cropAspectRatio != null && cropAspectRatio > 0
                  ? cropAspectRatio
                  : sourceAspect)
              .clamp(0.45, 2.4)
              .toDouble();
      var viewportWidth = maxDialogWidth;
      var viewportHeight = viewportWidth / resolvedAspect;
      if (viewportHeight > maxViewportHeight) {
        viewportHeight = maxViewportHeight;
        viewportWidth = viewportHeight * resolvedAspect;
      }

      const minZoom = 1.0;
      const maxZoom = 5.0;
      var zoom = 1.0;
      var offset = Offset.zero;
      var scaleBase = zoom;
      var startOffset = offset;
      var startFocal = Offset.zero;
      var exporting = false;
      var localError = '';

      return StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            title: const Text('Обрезка фото товара'),
            content: SizedBox(
              width: maxDialogWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Перемещайте и масштабируйте фото. Рамка показывает итоговый кадр.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: viewportWidth,
                        height: viewportHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(color: Colors.black12),
                            Listener(
                              onPointerSignal: (event) {
                                if (event is! PointerScrollEvent) return;
                                setModalState(() {
                                  final next =
                                      zoom +
                                      (event.scrollDelta.dy > 0 ? -0.08 : 0.08);
                                  zoom = next
                                      .clamp(minZoom, maxZoom)
                                      .toDouble();
                                  offset = _clampCropOffset(
                                    offset: offset,
                                    sourceWidth: source.width,
                                    sourceHeight: source.height,
                                    viewportWidth: viewportWidth,
                                    viewportHeight: viewportHeight,
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
                                    offset = _clampCropOffset(
                                      offset: startOffset + translated,
                                      sourceWidth: source.width,
                                      sourceHeight: source.height,
                                      viewportWidth: viewportWidth,
                                      viewportHeight: viewportHeight,
                                      zoom: zoom,
                                    );
                                  });
                                },
                                child: Transform.translate(
                                  offset: offset,
                                  child: Transform.scale(
                                    scale: zoom,
                                    child: Image.memory(
                                      sourceBytes,
                                      width: viewportWidth,
                                      height: viewportHeight,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _CropViewportFramePainter(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Масштаб: ${(zoom * 100).round()}%',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    Slider(
                      value: zoom,
                      min: minZoom,
                      max: maxZoom,
                      divisions: ((maxZoom - minZoom) * 20).round().clamp(
                        1,
                        120,
                      ),
                      onChanged: (next) {
                        setModalState(() {
                          zoom = next;
                          offset = _clampCropOffset(
                            offset: offset,
                            sourceWidth: source.width,
                            sourceHeight: source.height,
                            viewportWidth: viewportWidth,
                            viewportHeight: viewportHeight,
                            zoom: zoom,
                          );
                        });
                      },
                    ),
                    if (localError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
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
                onPressed: exporting
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: exporting
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop(
                          ProductPhotoCropResult(
                            bytes: sourceBytes,
                            fileName: passthroughFileName,
                            width: source.width,
                            height: source.height,
                          ),
                        );
                      },
                child: const Text('Без обрезки'),
              ),
              TextButton(
                onPressed: exporting
                    ? null
                    : () {
                        setModalState(() {
                          zoom = 1.0;
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
                          final cropped = _cropViewport(
                            source: source,
                            viewportWidth: viewportWidth,
                            viewportHeight: viewportHeight,
                            offset: offset,
                            zoom: zoom,
                          );
                          final prepared = _encodeTelegramLikeJpeg(cropped);
                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop(
                            ProductPhotoCropResult(
                              bytes: prepared,
                              fileName: fileName,
                              width: cropped.width,
                              height: cropped.height,
                            ),
                          );
                        } catch (_) {
                          setModalState(() {
                            exporting = false;
                            localError = 'Не удалось обработать изображение';
                          });
                        }
                      },
                child: exporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Применить обрезку'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _CropViewportFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRect(rect, borderPaint);

    final oneThirdX = size.width / 3;
    final twoThirdX = (size.width / 3) * 2;
    final oneThirdY = size.height / 3;
    final twoThirdY = (size.height / 3) * 2;

    canvas.drawLine(
      Offset(oneThirdX, 0),
      Offset(oneThirdX, size.height),
      guidePaint,
    );
    canvas.drawLine(
      Offset(twoThirdX, 0),
      Offset(twoThirdX, size.height),
      guidePaint,
    );
    canvas.drawLine(
      Offset(0, oneThirdY),
      Offset(size.width, oneThirdY),
      guidePaint,
    );
    canvas.drawLine(
      Offset(0, twoThirdY),
      Offset(size.width, twoThirdY),
      guidePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
