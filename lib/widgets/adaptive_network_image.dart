import 'package:flutter/material.dart';

import '../main.dart';
import '../src/utils/media_url.dart';

class AdaptiveNetworkImage extends StatelessWidget {
  const AdaptiveNetworkImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
    this.loadingBuilder,
    this.frameBuilder,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.headers,
    this.maxScaleForDecode = 1.0,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final ImageFrameBuilder? frameBuilder;
  final String? semanticLabel;
  final bool excludeFromSemantics;
  final Map<String, String>? headers;
  final double maxScaleForDecode;

  int? _computeDecodeDimension({
    required double? fixed,
    required double? bounded,
    required double dpr,
    required bool reducedMode,
  }) {
    final target = fixed ?? bounded;
    if (target == null || !target.isFinite || target <= 0) {
      return null;
    }
    final effectiveScale = reducedMode
        ? 0.65
        : maxScaleForDecode.clamp(0.5, 2.5);
    final decoded = (target * dpr * effectiveScale).round();
    if (decoded <= 0) return null;
    if (decoded > 4096) return 4096;
    return decoded;
  }

  @override
  Widget build(BuildContext context) {
    final reducedMode = performanceModeNotifier.value;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
    final resolvedUrl =
        resolveMediaUrl(url, apiBaseUrl: dio.options.baseUrl) ?? url;
    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : null;
        final boundedHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : null;
        final cacheWidth = _computeDecodeDimension(
          fixed: width,
          bounded: boundedWidth,
          dpr: dpr,
          reducedMode: reducedMode,
        );
        final cacheHeight = _computeDecodeDimension(
          fixed: height,
          bounded: boundedHeight,
          dpr: dpr,
          reducedMode: reducedMode,
        );

        return Image.network(
          resolvedUrl,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          semanticLabel: semanticLabel,
          excludeFromSemantics: excludeFromSemantics,
          headers: headers,
          filterQuality: reducedMode ? FilterQuality.none : FilterQuality.low,
          cacheWidth: cacheWidth,
          cacheHeight: cacheHeight,
          isAntiAlias: !reducedMode,
          gaplessPlayback: true,
          errorBuilder: errorBuilder,
          loadingBuilder: loadingBuilder,
          frameBuilder: frameBuilder,
        );
      },
    );
  }
}
