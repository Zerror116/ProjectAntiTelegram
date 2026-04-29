import 'dart:math';

import 'package:flutter/material.dart';

import 'adaptive_network_image.dart';

class ProductMediaGallery extends StatefulWidget {
  const ProductMediaGallery({
    super.key,
    this.coverImageUrl,
    this.media,
    this.height = 232,
    this.borderRadius = 22,
    this.heroLabel,
    this.fit = BoxFit.cover,
    this.showFrame = true,
  });

  final String? coverImageUrl;
  final List<Map<String, dynamic>>? media;
  final double height;
  final double borderRadius;
  final String? heroLabel;
  final BoxFit fit;
  final bool showFrame;

  @override
  State<ProductMediaGallery> createState() => _ProductMediaGalleryState();
}

class _ProductMediaGalleryState extends State<ProductMediaGallery> {
  late final PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  List<_GalleryItem> get _items {
    final rows = <_GalleryItem>[];
    final seen = <String>{};
    for (final raw in widget.media ?? const <Map<String, dynamic>>[]) {
      final original = _urlOf(raw['original_url'] ?? raw['url']);
      final detail = _urlOf(raw['detail_url']);
      final card = _urlOf(raw['card_url']);
      final thumb = _urlOf(raw['thumb_url']);
      final cover = detail ?? card ?? thumb ?? original;
      if (cover == null) continue;
      if (!seen.add(cover)) continue;
      rows.add(
        _GalleryItem(
          coverUrl: cover,
          originalUrl: original ?? detail ?? cover,
          detailUrl: detail ?? cover,
        ),
      );
    }
    final fallback = _urlOf(widget.coverImageUrl);
    if (fallback != null && rows.every((item) => item.coverUrl != fallback)) {
      rows.insert(
        0,
        _GalleryItem(
          coverUrl: fallback,
          originalUrl: fallback,
          detailUrl: fallback,
        ),
      );
    }
    return rows;
  }

  String? _urlOf(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  Future<void> _openViewer(int index) async {
    final items = _items;
    if (items.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (context) {
        final controller = PageController(initialPage: index);
        return Dialog.fullscreen(
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              PageView.builder(
                controller: controller,
                itemCount: items.length,
                itemBuilder: (context, pageIndex) {
                  final entry = items[pageIndex];
                  return InteractiveViewer(
                    maxScale: 3.2,
                    minScale: 0.85,
                    child: Center(
                      child: AdaptiveNetworkImage(
                        entry.originalUrl,
                        fit: BoxFit.contain,
                      ),
                    ),
                  );
                },
              ),
              Positioned(
                top: 18,
                right: 18,
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: widget.showFrame
              ? Border.all(color: theme.colorScheme.outlineVariant)
              : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.photo_outlined,
          size: 30,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final gallery = Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: PageView.builder(
            controller: _pageController,
            itemCount: items.length,
            onPageChanged: (value) {
              if (!mounted) return;
              setState(() => _currentIndex = value);
            },
            itemBuilder: (context, index) {
              final entry = items[index];
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _openViewer(index),
                  child: Ink(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: AdaptiveNetworkImage(
                      entry.coverUrl,
                      fit: widget.fit,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.04),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.18),
                  ],
                  stops: const [0, 0.52, 1],
                ),
              ),
            ),
          ),
        ),
        if (widget.heroLabel != null && widget.heroLabel!.trim().isNotEmpty)
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              ),
              child: Text(
                widget.heroLabel!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        if (items.length > 1)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Row(
              children: [
                Row(
                  children: List.generate(items.length, (index) {
                    final active = index == _currentIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: active ? 22 : 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: active
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    );
                  }),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Text(
                    '${_currentIndex + 1}/${items.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return Container(
      constraints: BoxConstraints(minHeight: min(widget.height, 140)),
      height: widget.height,
      decoration: widget.showFrame
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            )
          : null,
      child: gallery,
    );
  }
}

class _GalleryItem {
  const _GalleryItem({
    required this.coverUrl,
    required this.originalUrl,
    required this.detailUrl,
  });

  final String coverUrl;
  final String originalUrl;
  final String detailUrl;
}
