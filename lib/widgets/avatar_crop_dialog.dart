import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class AvatarCropResult {
  final String croppedPath;

  const AvatarCropResult({required this.croppedPath});
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
      '${Directory.systemTemp.path}${Platform.pathSeparator}profile_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
  await File(outputPath).writeAsBytes(outputBytes, flush: true);
  return outputPath;
}

Future<AvatarCropResult?> showAvatarCropDialog({
  required BuildContext context,
  required String filePath,
  double initialFocusX = 0,
  double initialFocusY = 0,
  double initialZoom = 1,
}) async {
  final imageFile = File(filePath);
  final sourceBytes = await imageFile.readAsBytes();
  final source = img.decodeImage(sourceBytes);
  if (source == null) {
    throw Exception('Не удалось прочитать изображение');
  }
  if (!context.mounted) return null;

  return showDialog<AvatarCropResult>(
    context: context,
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      final maxDialogWidth = media.size.width - 40;
      final maxDialogHeight = media.size.height - 140;
      final dialogWidth = maxDialogWidth.clamp(300.0, 460.0);
      final previewByWidth = (dialogWidth - 32).clamp(240.0, 360.0);
      final previewByHeight = (maxDialogHeight - 200).clamp(220.0, 360.0);
      final previewSize = math.min(previewByWidth, previewByHeight);
      final cutoutSize = (previewSize * 0.78)
          .clamp(180.0, previewSize)
          .toDouble();

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
                              zoom + (event.scrollDelta.dy > 0 ? -0.08 : 0.08);
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
                          borderRadius: BorderRadius.circular(22),
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
                                IgnorePointer(
                                  child: CustomPaint(
                                    painter: _CircleCutoutPainter(
                                      cutoutRadius: cutoutSize / 2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
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
                          Navigator.of(
                            ctx,
                          ).pop(AvatarCropResult(croppedPath: croppedPath));
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

class _CircleCutoutPainter extends CustomPainter {
  final double cutoutRadius;

  const _CircleCutoutPainter({required this.cutoutRadius});

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.46);
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final center = Offset(size.width / 2, size.height / 2);
    final cutout = Path()
      ..addOval(Rect.fromCircle(center: center, radius: cutoutRadius));

    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final overlay = Path.combine(PathOperation.difference, full, cutout);

    canvas.drawPath(overlay, overlayPaint);
    canvas.drawCircle(center, cutoutRadius, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _CircleCutoutPainter oldDelegate) {
    return oldDelegate.cutoutRadius != cutoutRadius;
  }
}
