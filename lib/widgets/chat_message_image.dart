import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../main.dart';
import '../src/utils/media_url.dart';
import 'adaptive_network_image.dart';

final Map<String, Size> _chatMessageImageSizeCache = <String, Size>{};

String _resolvedChatImageUrl(String imageUrl) =>
    resolveMediaUrl(imageUrl, apiBaseUrl: dio.options.baseUrl) ?? imageUrl;

Size? cachedChatMessageImageSize(String imageUrl) {
  return _chatMessageImageSizeCache[_resolvedChatImageUrl(imageUrl)];
}

Future<Size?> warmUpChatMessageImageSize(String imageUrl) async {
  final resolvedUrl = _resolvedChatImageUrl(imageUrl);
  final cached = _chatMessageImageSizeCache[resolvedUrl];
  if (cached != null) return cached;

  final completer = Completer<Size?>();
  final imageProvider = NetworkImage(resolvedUrl);
  final stream = imageProvider.resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      final size = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      _chatMessageImageSizeCache[resolvedUrl] = size;
      if (!completer.isCompleted) completer.complete(size);
      stream.removeListener(listener);
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) completer.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

class ChatMessageImage extends StatefulWidget {
  const ChatMessageImage({
    super.key,
    required this.imageUrl,
    required this.preferredWidth,
    required this.maxBubbleWidth,
    required this.maxHeight,
    required this.onTap,
    this.knownWidth,
    this.knownHeight,
    this.borderRadius = 18,
    this.expandToMaxWidth = false,
    this.onFramePainted,
  });

  final String imageUrl;
  final double preferredWidth;
  final double maxBubbleWidth;
  final double maxHeight;
  final VoidCallback onTap;
  final double? knownWidth;
  final double? knownHeight;
  final double borderRadius;
  final bool expandToMaxWidth;
  final VoidCallback? onFramePainted;

  @override
  State<ChatMessageImage> createState() => _ChatMessageImageState();
}

class _ChatMessageImageState extends State<ChatMessageImage> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  Size? _intrinsicSize;

  @override
  void initState() {
    super.initState();
    _intrinsicSize = _sizeFromKnownDimensions();
    _resolveIntrinsicSizeIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ChatMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKnown = _sizeFromKnownDimensions();
    if (widget.imageUrl != oldWidget.imageUrl ||
        widget.knownWidth != oldWidget.knownWidth ||
        widget.knownHeight != oldWidget.knownHeight) {
      _removeImageStreamListener();
      _intrinsicSize = nextKnown;
      _resolveIntrinsicSizeIfNeeded();
    }
  }

  @override
  void dispose() {
    _removeImageStreamListener();
    super.dispose();
  }

  Size? _sizeFromKnownDimensions() {
    final width = widget.knownWidth;
    final height = widget.knownHeight;
    if (width == null || height == null) return null;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  void _resolveIntrinsicSizeIfNeeded() {
    if (_intrinsicSize != null) return;
    final resolvedUrl = _resolvedChatImageUrl(widget.imageUrl);
    final cached = _chatMessageImageSizeCache[resolvedUrl];
    if (cached != null) {
      _intrinsicSize = cached;
      return;
    }
    final imageProvider = NetworkImage(resolvedUrl);
    final stream = imageProvider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        _chatMessageImageSizeCache[resolvedUrl] = size;
        if (!mounted) return;
        setState(() => _intrinsicSize = size);
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
      },
    );
    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
  }

  void _removeImageStreamListener() {
    final stream = _imageStream;
    final listener = _imageStreamListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageStreamListener = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final intrinsic = _intrinsicSize ?? const Size(1200, 1500);
    final geometry = _ChatImageGeometry.resolve(
      intrinsic: intrinsic,
      preferredWidth: widget.preferredWidth,
      maxBubbleWidth: widget.maxBubbleWidth,
      maxHeight: widget.maxHeight,
      expandToMaxWidth: widget.expandToMaxWidth,
    );

    Widget buildPlaceholder({bool loading = false}) => Container(
      width: geometry.boxWidth,
      height: geometry.boxHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loading ? Icons.image_search_outlined : Icons.image_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            loading ? 'Загружаем фото...' : 'Фото недоступно',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: SizedBox(
          width: geometry.boxWidth,
          height: geometry.boxHeight,
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                if (geometry.usesBackdrop) ...[
                  Positioned.fill(
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                      child: Transform.scale(
                        scale: 1.08,
                        child: AdaptiveNetworkImage(
                          widget.imageUrl,
                          width: geometry.boxWidth,
                          height: geometry.boxHeight,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          maxScaleForDecode: 0.65,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            theme.colorScheme.surface.withValues(alpha: 0.10),
                            theme.colorScheme.surface.withValues(alpha: 0.22),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                Center(
                  child: SizedBox(
                    width: geometry.contentWidth,
                    height: geometry.contentHeight,
                    child: AdaptiveNetworkImage(
                      widget.imageUrl,
                      width: geometry.contentWidth,
                      height: geometry.contentHeight,
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                      frameBuilder: (context, child, frame, sync) {
                        if (sync || frame != null) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            widget.onFramePainted?.call();
                          });
                        }
                        return child;
                      },
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return buildPlaceholder(loading: true);
                      },
                      errorBuilder: (context, error, stackTrace) =>
                          buildPlaceholder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatImageGeometry {
  const _ChatImageGeometry({
    required this.boxWidth,
    required this.boxHeight,
    required this.contentWidth,
    required this.contentHeight,
    required this.usesBackdrop,
  });

  final double boxWidth;
  final double boxHeight;
  final double contentWidth;
  final double contentHeight;
  final bool usesBackdrop;

  static _ChatImageGeometry resolve({
    required Size intrinsic,
    required double preferredWidth,
    required double maxBubbleWidth,
    required double maxHeight,
    required bool expandToMaxWidth,
  }) {
    final safeWidth = intrinsic.width > 0 ? intrinsic.width : 1200.0;
    final safeHeight = intrinsic.height > 0 ? intrinsic.height : 1500.0;
    final ratio = (safeWidth / safeHeight).clamp(0.12, 8.0).toDouble();
    final availableWidth = math.min(maxBubbleWidth, preferredWidth);
    final isWide = ratio >= 1.55;
    final isTall = ratio <= 0.72;

    if (isWide) {
      final boxWidth = availableWidth;
      final boxHeight = math.min(
        maxHeight,
        math.max(208.0, availableWidth * 0.58),
      );
      return _withContainedContent(
        imageWidth: safeWidth,
        imageHeight: safeHeight,
        boxWidth: boxWidth,
        boxHeight: boxHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        usesBackdrop: true,
      );
    }

    if (isTall) {
      final boxHeight = maxHeight;
      final boxWidth = math.max(
        208.0,
        math.min(availableWidth * 0.82, boxHeight * 0.76),
      );
      return _withContainedContent(
        imageWidth: safeWidth,
        imageHeight: safeHeight,
        boxWidth: boxWidth,
        boxHeight: boxHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        usesBackdrop: true,
      );
    }

    if (expandToMaxWidth) {
      final boxWidth = availableWidth;
      final boxHeight = math.min(
        maxHeight,
        math.max(220.0, availableWidth / ratio),
      );
      return _withContainedContent(
        imageWidth: safeWidth,
        imageHeight: safeHeight,
        boxWidth: boxWidth,
        boxHeight: boxHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        usesBackdrop: false,
      );
    }

    final scale = math.min(availableWidth / safeWidth, maxHeight / safeHeight);
    final contentWidth = (safeWidth * scale).clamp(156.0, availableWidth);
    final contentHeight = (safeHeight * scale).clamp(156.0, maxHeight);
    return _ChatImageGeometry(
      boxWidth: contentWidth.toDouble(),
      boxHeight: contentHeight.toDouble(),
      contentWidth: contentWidth.toDouble(),
      contentHeight: contentHeight.toDouble(),
      usesBackdrop: false,
    );
  }

  static _ChatImageGeometry _withContainedContent({
    required double imageWidth,
    required double imageHeight,
    required double boxWidth,
    required double boxHeight,
    required EdgeInsets padding,
    required bool usesBackdrop,
  }) {
    final availableContentWidth = math.max(80.0, boxWidth - padding.horizontal);
    final availableContentHeight = math.max(80.0, boxHeight - padding.vertical);
    final scale = math.min(
      availableContentWidth / imageWidth,
      availableContentHeight / imageHeight,
    );
    return _ChatImageGeometry(
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      contentWidth: imageWidth * scale,
      contentHeight: imageHeight * scale,
      usesBackdrop: usesBackdrop,
    );
  }
}
