import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class PhoenixPreparedImage {
  const PhoenixPreparedImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

class PhoenixProcessedImage {
  const PhoenixProcessedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.fileName,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String fileName;
}

enum PhoenixPostCropPreset {
  square,
  portrait,
  wide,
  uncropped;

  String get label => switch (this) {
    PhoenixPostCropPreset.square => 'Квадрат',
    PhoenixPostCropPreset.portrait => 'Вертикально',
    PhoenixPostCropPreset.wide => 'Широко',
    PhoenixPostCropPreset.uncropped => 'Без обрезки',
  };

  double? get aspectRatio => switch (this) {
    PhoenixPostCropPreset.square => 1.0,
    PhoenixPostCropPreset.portrait => 4 / 5,
    PhoenixPostCropPreset.wide => 16 / 9,
    PhoenixPostCropPreset.uncropped => null,
  };
}

img.Image _decodeAndBake(Uint8List bytes, {String errorText = 'Не удалось прочитать изображение'}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw Exception(errorText);
  }
  return img.bakeOrientation(decoded);
}

img.Image _resizeIfNeeded(img.Image source, {required int maxLongestSide}) {
  final longestSide = source.width > source.height ? source.width : source.height;
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

String _sanitizeBaseName(String originalFileName, {required String fallback}) {
  final normalizedPath = originalFileName.replaceAll('\\', '/').trim();
  final lastSegment = normalizedPath.split('/').last.trim();
  final baseWithExt = lastSegment.isEmpty ? fallback : lastSegment;
  final dotIndex = baseWithExt.lastIndexOf('.');
  final base = dotIndex > 0 ? baseWithExt.substring(0, dotIndex) : baseWithExt;
  final safeBase = base
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  return safeBase.isEmpty ? fallback : safeBase;
}

String buildAvatarFileName(String originalFileName) {
  final base = _sanitizeBaseName(originalFileName, fallback: 'avatar');
  return '${base}_avatar.jpg';
}

String buildCroppedPhotoFileName(String originalFileName) {
  final base = _sanitizeBaseName(originalFileName, fallback: 'product-photo');
  return '${base}_crop.jpg';
}

String buildNormalizedPhotoFileName(String originalFileName) {
  final base = _sanitizeBaseName(originalFileName, fallback: 'product-photo');
  return '${base}_normalized.jpg';
}

PhoenixPreparedImage prepareImageForEditing(
  Uint8List sourceBytes, {
  int maxLongestSide = 2600,
}) {
  final baked = _decodeAndBake(sourceBytes);
  final normalized = _resizeIfNeeded(baked, maxLongestSide: maxLongestSide);
  final encoded = Uint8List.fromList(img.encodeJpg(normalized, quality: 96));
  return PhoenixPreparedImage(
    bytes: encoded,
    width: normalized.width,
    height: normalized.height,
  );
}

PhoenixProcessedImage buildAvatarUploadImage(
  Uint8List croppedBytes,
  String originalFileName,
) {
  final baked = _decodeAndBake(croppedBytes);
  final resized = img.copyResize(
    baked,
    width: 1024,
    height: 1024,
    interpolation: img.Interpolation.cubic,
  );
  final encoded = Uint8List.fromList(img.encodeJpg(resized, quality: 95));
  return PhoenixProcessedImage(
    bytes: encoded,
    width: resized.width,
    height: resized.height,
    fileName: buildAvatarFileName(originalFileName),
  );
}

Uint8List _encodeJpegWithinBudget(
  img.Image source, {
  int maxUploadBytes = 7 * 1024 * 1024,
}) {
  final working = _resizeIfNeeded(source, maxLongestSide: 2600);
  const qualitySteps = <int>[97, 95, 93, 90, 87, 84, 82];
  for (final quality in qualitySteps) {
    final output = Uint8List.fromList(img.encodeJpg(working, quality: quality));
    if (output.lengthInBytes <= maxUploadBytes || quality == qualitySteps.last) {
      return output;
    }
  }
  return Uint8List.fromList(img.encodeJpg(working, quality: 82));
}

PhoenixProcessedImage buildPostUploadImage(
  Uint8List sourceBytes,
  String originalFileName, {
  required bool cropped,
}) {
  final baked = _decodeAndBake(sourceBytes);
  final encoded = _encodeJpegWithinBudget(baked);
  final decodedPrepared = _decodeAndBake(encoded);
  return PhoenixProcessedImage(
    bytes: encoded,
    width: decodedPrepared.width,
    height: decodedPrepared.height,
    fileName: cropped
        ? buildCroppedPhotoFileName(originalFileName)
        : buildNormalizedPhotoFileName(originalFileName),
  );
}

class PhoenixCropCore extends StatelessWidget {
  const PhoenixCropCore({
    super.key,
    required this.imageBytes,
    required this.controller,
    required this.onCropped,
    required this.aspectRatio,
    this.withCircleUi = false,
    this.onMoved,
    this.height = 320,
    this.width,
    this.showGrid = false,
  });

  final Uint8List imageBytes;
  final CropController controller;
  final ValueChanged<CropResult> onCropped;
  final double? aspectRatio;
  final bool withCircleUi;
  final void Function(Rect cropRect, Rect imageRect)? onMoved;
  final double height;
  final double? width;
  final bool showGrid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(withCircleUi ? 24 : 18),
      child: SizedBox(
        width: width,
        height: height,
        child: Crop(
          image: imageBytes,
          controller: controller,
          onCropped: onCropped,
          aspectRatio: aspectRatio,
          withCircleUi: withCircleUi,
          interactive: true,
          fixCropRect: true,
          radius: withCircleUi ? 0 : 20,
          baseColor: theme.colorScheme.surfaceContainerHighest,
          maskColor: Colors.black.withValues(alpha: 0.48),
          filterQuality: FilterQuality.high,
          scrollZoomSensitivity: 0.08,
          initialRectBuilder: InitialRectBuilder.withSizeAndRatio(
            size: withCircleUi ? 0.84 : 0.9,
            aspectRatio: withCircleUi ? 1.0 : aspectRatio,
          ),
          onMoved: onMoved,
          overlayBuilder: showGrid
              ? (context, rect) => CustomPaint(
                    painter: _CropGridPainter(rect: rect),
                    size: Size.infinite,
                  )
              : null,
        ),
      ),
    );
  }
}

class PhoenixAvatarLivePreview extends StatelessWidget {
  const PhoenixAvatarLivePreview({
    super.key,
    required this.imageBytes,
    required this.cropRect,
    required this.imageRect,
    this.size = 92,
  });

  final Uint8List imageBytes;
  final Rect cropRect;
  final Rect imageRect;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = cropRect.width > 0 && cropRect.height > 0 && imageRect.width > 0 && imageRect.height > 0;
    if (!ready) {
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Image.memory(
            imageBytes,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          ),
        ),
      );
    }

    final scaleX = size / cropRect.width;
    final scaleY = size / cropRect.height;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: (imageRect.left - cropRect.left) * scaleX,
            top: (imageRect.top - cropRect.top) * scaleY,
            width: imageRect.width * scaleX,
            height: imageRect.height * scaleY,
            child: Image.memory(
              imageBytes,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        ],
      ),
    );
  }
}

class _CropGridPainter extends CustomPainter {
  const _CropGridPainter({required this.rect});

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final oneThirdX = rect.left + rect.width / 3;
    final twoThirdX = rect.left + (rect.width / 3) * 2;
    final oneThirdY = rect.top + rect.height / 3;
    final twoThirdY = rect.top + (rect.height / 3) * 2;

    canvas.drawLine(Offset(oneThirdX, rect.top), Offset(oneThirdX, rect.bottom), guidePaint);
    canvas.drawLine(Offset(twoThirdX, rect.top), Offset(twoThirdX, rect.bottom), guidePaint);
    canvas.drawLine(Offset(rect.left, oneThirdY), Offset(rect.right, oneThirdY), guidePaint);
    canvas.drawLine(Offset(rect.left, twoThirdY), Offset(rect.right, twoThirdY), guidePaint);
  }

  @override
  bool shouldRepaint(covariant _CropGridPainter oldDelegate) => oldDelegate.rect != rect;
}
