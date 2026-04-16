import 'dart:math';
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

img.Image _decodeAndBake(
  Uint8List bytes, {
  String errorText = 'Не удалось прочитать изображение',
}) {
  final safeBytes = Uint8List.fromList(bytes);
  img.Image? decoded;
  try {
    decoded = img.decodeImage(safeBytes);
  } on RangeError {
    throw Exception('$errorText: файл поврежден или прочитан не полностью');
  } catch (_) {
    throw Exception(errorText);
  }
  if (decoded == null) {
    throw Exception(errorText);
  }
  return img.bakeOrientation(decoded);
}

img.Image _resizeIfNeeded(img.Image source, {required int maxLongestSide}) {
  final longestSide = source.width > source.height
      ? source.width
      : source.height;
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
    if (output.lengthInBytes <= maxUploadBytes ||
        quality == qualitySteps.last) {
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

class PhoenixCropCore extends StatefulWidget {
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
    this.edgeHandleTopBottomTouchTarget = 30,
    this.edgeHandleSideTouchTarget = 44,
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
  final double edgeHandleTopBottomTouchTarget;
  final double edgeHandleSideTouchTarget;

  @override
  State<PhoenixCropCore> createState() => _PhoenixCropCoreState();
}

class _PhoenixCropCoreState extends State<PhoenixCropCore> {
  static const double _minCropExtent = 72;
  static const double _edgeHandleVisualLength = 36;
  static const double _edgeHandleVisualThickness = 8;

  Rect _cropRect = Rect.zero;
  Rect _imageRect = Rect.zero;
  Rect? _lastValidCropRect;
  Rect? _lastValidImageRect;

  Rect get _displayCropRect =>
      _isStableRect(_cropRect) ? _cropRect : (_lastValidCropRect ?? Rect.zero);

  Rect get _displayImageRect => _isStableRect(_imageRect)
      ? _imageRect
      : (_lastValidImageRect ?? Rect.zero);

  bool get _ready =>
      _isStableRect(_displayCropRect) && _isStableRect(_displayImageRect);

  double? get _effectiveAspectRatio =>
      widget.withCircleUi ? 1.0 : widget.aspectRatio;

  Rect _normalizeRect(Rect rect) {
    final left = min(rect.left, rect.right);
    final right = max(rect.left, rect.right);
    final top = min(rect.top, rect.bottom);
    final bottom = max(rect.top, rect.bottom);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  bool _isFiniteRect(Rect rect) {
    return rect.left.isFinite &&
        rect.top.isFinite &&
        rect.right.isFinite &&
        rect.bottom.isFinite;
  }

  bool _isStableRect(Rect rect) {
    if (!_isFiniteRect(rect)) return false;
    return rect.width > 0 && rect.height > 0;
  }

  bool _isInsideRect(Rect inner, Rect outer, {double epsilon = 0.75}) {
    return inner.left >= outer.left - epsilon &&
        inner.top >= outer.top - epsilon &&
        inner.right <= outer.right + epsilon &&
        inner.bottom <= outer.bottom + epsilon;
  }

  bool _isValidCropRect(Rect cropRect, Rect? imageRect) {
    if (!_isStableRect(cropRect)) return false;
    if (imageRect == null || !_isStableRect(imageRect)) return true;
    return _isInsideRect(cropRect, imageRect);
  }

  double _touchTargetForAlignment(Alignment alignment) {
    if (alignment == Alignment.centerLeft ||
        alignment == Alignment.centerRight) {
      return widget.edgeHandleSideTouchTarget;
    }
    return widget.edgeHandleTopBottomTouchTarget;
  }

  @override
  void didUpdateWidget(covariant PhoenixCropCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imageBytes, widget.imageBytes)) {
      _cropRect = Rect.zero;
      _imageRect = Rect.zero;
      _lastValidCropRect = null;
      _lastValidImageRect = null;
    }
  }

  void _handleMoved(Rect cropRect, Rect imageRect) {
    final normalizedCropRect = _normalizeRect(cropRect);
    final normalizedImageRect = _normalizeRect(imageRect);

    final hasValidImage = _isStableRect(normalizedImageRect);
    final imageForValidation = hasValidImage
        ? normalizedImageRect
        : _lastValidImageRect;

    final hasValidCrop = _isValidCropRect(
      normalizedCropRect,
      imageForValidation,
    );

    final nextImageRect = hasValidImage
        ? normalizedImageRect
        : _displayImageRect;
    final nextCropRect = hasValidCrop ? normalizedCropRect : _displayCropRect;

    if (hasValidImage) {
      _lastValidImageRect = normalizedImageRect;
    }
    if (hasValidCrop) {
      _lastValidCropRect = normalizedCropRect;
    }

    if (mounted) {
      setState(() {
        _imageRect = nextImageRect;
        _cropRect = nextCropRect;
      });
    } else {
      _imageRect = nextImageRect;
      _cropRect = nextCropRect;
    }

    widget.onMoved?.call(nextCropRect, nextImageRect);
  }

  Rect? _resizeFromHorizontalHandle(double delta, {required bool leading}) {
    if (!_ready) return null;
    final current = _displayCropRect;
    final imageRect = _displayImageRect;
    final aspectRatio = _effectiveAspectRatio;

    if (aspectRatio == null) {
      final minWidth = _minCropExtent.toDouble();
      final nextLeft = leading
          ? (current.left + delta).clamp(
              imageRect.left,
              current.right - minWidth,
            )
          : current.left;
      final nextRight = leading
          ? current.right
          : (current.right + delta).clamp(
              current.left + minWidth,
              imageRect.right,
            );
      return Rect.fromLTRB(nextLeft, current.top, nextRight, current.bottom);
    }

    final anchorX = leading ? current.right : current.left;
    var targetWidth = leading
        ? anchorX - (current.left + delta)
        : (current.right + delta) - anchorX;
    final minWidth = _minCropExtent.toDouble();
    final centerY = current.center.dy;
    final maxHalfHeight = min(
      centerY - imageRect.top,
      imageRect.bottom - centerY,
    );
    final maxWidthByHeight = maxHalfHeight * 2 * aspectRatio;
    final maxWidthByAnchor = leading
        ? anchorX - imageRect.left
        : imageRect.right - anchorX;
    var maxWidth = min(maxWidthByHeight, maxWidthByAnchor);
    if (maxWidth < minWidth) {
      maxWidth = minWidth;
    }
    targetWidth = targetWidth.clamp(minWidth, maxWidth).toDouble();

    final targetHeight = targetWidth / aspectRatio;
    var top = centerY - (targetHeight / 2);
    var bottom = centerY + (targetHeight / 2);
    if (top < imageRect.top) {
      bottom += imageRect.top - top;
      top = imageRect.top;
    }
    if (bottom > imageRect.bottom) {
      top -= bottom - imageRect.bottom;
      bottom = imageRect.bottom;
    }

    final left = leading ? anchorX - targetWidth : anchorX;
    final right = leading ? anchorX : anchorX + targetWidth;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect? _resizeFromVerticalHandle(double delta, {required bool topEdge}) {
    if (!_ready) return null;
    final current = _displayCropRect;
    final imageRect = _displayImageRect;
    final aspectRatio = _effectiveAspectRatio;

    if (aspectRatio == null) {
      final minHeight = _minCropExtent.toDouble();
      final nextTop = topEdge
          ? (current.top + delta).clamp(
              imageRect.top,
              current.bottom - minHeight,
            )
          : current.top;
      final nextBottom = topEdge
          ? current.bottom
          : (current.bottom + delta).clamp(
              current.top + minHeight,
              imageRect.bottom,
            );
      return Rect.fromLTRB(current.left, nextTop, current.right, nextBottom);
    }

    final anchorY = topEdge ? current.bottom : current.top;
    var targetHeight = topEdge
        ? anchorY - (current.top + delta)
        : (current.bottom + delta) - anchorY;
    final minHeight = (_minCropExtent / aspectRatio).clamp(
      _minCropExtent.toDouble(),
      double.infinity,
    );
    final centerX = current.center.dx;
    final maxHalfWidth = min(
      centerX - imageRect.left,
      imageRect.right - centerX,
    );
    final maxHeightByWidth = (maxHalfWidth * 2) / aspectRatio;
    final maxHeightByAnchor = topEdge
        ? anchorY - imageRect.top
        : imageRect.bottom - anchorY;
    var maxHeight = min(maxHeightByWidth, maxHeightByAnchor);
    if (maxHeight < minHeight) {
      maxHeight = minHeight;
    }
    targetHeight = targetHeight.clamp(minHeight, maxHeight).toDouble();

    final targetWidth = targetHeight * aspectRatio;
    var left = centerX - (targetWidth / 2);
    var right = centerX + (targetWidth / 2);
    if (left < imageRect.left) {
      right += imageRect.left - left;
      left = imageRect.left;
    }
    if (right > imageRect.right) {
      left -= right - imageRect.right;
      right = imageRect.right;
    }

    final top = topEdge ? anchorY - targetHeight : anchorY;
    final bottom = topEdge ? anchorY : anchorY + targetHeight;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _applyCropRect(Rect? rect) {
    if (rect == null) return;
    final normalizedRect = _normalizeRect(rect);
    if (!_isStableRect(normalizedRect)) return;
    if (_isStableRect(_displayImageRect) &&
        !_isInsideRect(normalizedRect, _displayImageRect, epsilon: 1.0)) {
      return;
    }
    _lastValidCropRect = normalizedRect;
    widget.controller.cropRect = normalizedRect;
  }

  Widget _buildEdgeHandle({
    required Alignment alignment,
    required double left,
    required double top,
    required double width,
    required double height,
    required void Function(DragUpdateDetails details) onPanUpdate,
  }) {
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: onPanUpdate,
        child: SizedBox(
          width: width,
          height: height,
          child: Align(
            alignment: alignment,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: SizedBox(
                width:
                    alignment == Alignment.centerLeft ||
                        alignment == Alignment.centerRight
                    ? _edgeHandleVisualThickness
                    : _edgeHandleVisualLength,
                height:
                    alignment == Alignment.centerLeft ||
                        alignment == Alignment.centerRight
                    ? _edgeHandleVisualLength
                    : _edgeHandleVisualThickness,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.withCircleUi ? 24 : 18),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Crop(
              image: widget.imageBytes,
              controller: widget.controller,
              onCropped: widget.onCropped,
              aspectRatio: widget.aspectRatio,
              withCircleUi: widget.withCircleUi,
              interactive: false,
              fixCropRect: false,
              radius: widget.withCircleUi ? 0 : 20,
              baseColor: theme.colorScheme.surfaceContainerHighest,
              maskColor: Colors.black.withValues(alpha: 0.48),
              filterQuality: FilterQuality.high,
              initialRectBuilder: InitialRectBuilder.withSizeAndRatio(
                size: widget.withCircleUi ? 0.84 : 0.9,
                aspectRatio: widget.withCircleUi ? 1.0 : widget.aspectRatio,
              ),
              onMoved: _handleMoved,
              cornerDotBuilder: (size, _) =>
                  const DotControl(color: Colors.white, padding: 10),
              overlayBuilder: widget.showGrid
                  ? (context, rect) => CustomPaint(
                      painter: _CropGridPainter(rect: rect),
                      size: Size.infinite,
                    )
                  : null,
            ),
            if (_ready) ...[
              // Визуальный размер ручек остается прежним; увеличиваем только зону касания.
              _buildEdgeHandle(
                alignment: Alignment.topCenter,
                left:
                    _displayCropRect.center.dx -
                    (_touchTargetForAlignment(Alignment.topCenter) / 2),
                top:
                    _displayCropRect.top -
                    (_touchTargetForAlignment(Alignment.topCenter) / 2),
                width: _touchTargetForAlignment(Alignment.topCenter),
                height: _touchTargetForAlignment(Alignment.topCenter),
                onPanUpdate: (details) => _applyCropRect(
                  _resizeFromVerticalHandle(details.delta.dy, topEdge: true),
                ),
              ),
              _buildEdgeHandle(
                alignment: Alignment.bottomCenter,
                left:
                    _displayCropRect.center.dx -
                    (_touchTargetForAlignment(Alignment.bottomCenter) / 2),
                top:
                    _displayCropRect.bottom -
                    (_touchTargetForAlignment(Alignment.bottomCenter) / 2),
                width: _touchTargetForAlignment(Alignment.bottomCenter),
                height: _touchTargetForAlignment(Alignment.bottomCenter),
                onPanUpdate: (details) => _applyCropRect(
                  _resizeFromVerticalHandle(details.delta.dy, topEdge: false),
                ),
              ),
              _buildEdgeHandle(
                alignment: Alignment.centerLeft,
                left:
                    _displayCropRect.left -
                    (_touchTargetForAlignment(Alignment.centerLeft) / 2),
                top:
                    _displayCropRect.center.dy -
                    (_touchTargetForAlignment(Alignment.centerLeft) / 2),
                width: _touchTargetForAlignment(Alignment.centerLeft),
                height: _touchTargetForAlignment(Alignment.centerLeft),
                onPanUpdate: (details) => _applyCropRect(
                  _resizeFromHorizontalHandle(details.delta.dx, leading: true),
                ),
              ),
              _buildEdgeHandle(
                alignment: Alignment.centerRight,
                left:
                    _displayCropRect.right -
                    (_touchTargetForAlignment(Alignment.centerRight) / 2),
                top:
                    _displayCropRect.center.dy -
                    (_touchTargetForAlignment(Alignment.centerRight) / 2),
                width: _touchTargetForAlignment(Alignment.centerRight),
                height: _touchTargetForAlignment(Alignment.centerRight),
                onPanUpdate: (details) => _applyCropRect(
                  _resizeFromHorizontalHandle(details.delta.dx, leading: false),
                ),
              ),
            ],
          ],
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
    final ready =
        cropRect.width > 0 &&
        cropRect.height > 0 &&
        imageRect.width > 0 &&
        imageRect.height > 0;
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
        border: Border.all(color: theme.colorScheme.outlineVariant),
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

    canvas.drawLine(
      Offset(oneThirdX, rect.top),
      Offset(oneThirdX, rect.bottom),
      guidePaint,
    );
    canvas.drawLine(
      Offset(twoThirdX, rect.top),
      Offset(twoThirdX, rect.bottom),
      guidePaint,
    );
    canvas.drawLine(
      Offset(rect.left, oneThirdY),
      Offset(rect.right, oneThirdY),
      guidePaint,
    );
    canvas.drawLine(
      Offset(rect.left, twoThirdY),
      Offset(rect.right, twoThirdY),
      guidePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CropGridPainter oldDelegate) =>
      oldDelegate.rect != rect;
}
