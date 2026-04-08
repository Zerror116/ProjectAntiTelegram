import 'package:flutter/material.dart';

import 'adaptive_network_image.dart';

class ChatMediaViewerEntry {
  const ChatMediaViewerEntry({
    required this.id,
    required this.imageUrl,
    this.caption = '',
    this.senderName = '',
    this.timeLabel = '',
  });

  final String id;
  final String imageUrl;
  final String caption;
  final String senderName;
  final String timeLabel;
}

Future<void> showChatMediaViewer(
  BuildContext context, {
  required List<ChatMediaViewerEntry> entries,
  int initialIndex = 0,
}) async {
  if (entries.isEmpty) return;
  final safeIndex = initialIndex.clamp(0, entries.length - 1);
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _ChatMediaViewerScreen(
        entries: entries,
        initialIndex: safeIndex,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
      },
    ),
  );
}

class _ChatMediaViewerScreen extends StatefulWidget {
  const _ChatMediaViewerScreen({
    required this.entries,
    required this.initialIndex,
  });

  final List<ChatMediaViewerEntry> entries;
  final int initialIndex;

  @override
  State<_ChatMediaViewerScreen> createState() => _ChatMediaViewerScreenState();
}

class _ChatMediaViewerScreenState extends State<_ChatMediaViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _jumpTo(int nextIndex) {
    if (nextIndex < 0 || nextIndex >= widget.entries.length) return;
    _pageController.animateToPage(
      nextIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final entry = widget.entries[_currentIndex];
    final showDesktopArrows =
        media.size.width >= 820 && widget.entries.length > 1;

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.96),
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.entries.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) {
                final pageEntry = widget.entries[index];
                return _ZoomableMediaPage(entry: pageEntry);
              },
            ),
            Positioned(
              top: 10,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.entries.length > 1
                                ? '${_currentIndex + 1} из ${widget.entries.length}'
                                : 'Фото',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (entry.senderName.trim().isNotEmpty ||
                              entry.timeLabel.trim().isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (entry.senderName.trim().isNotEmpty)
                                  entry.senderName.trim(),
                                if (entry.timeLabel.trim().isNotEmpty)
                                  entry.timeLabel.trim(),
                              ].join(' • '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.34),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (showDesktopArrows)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: false,
                  child: Row(
                    children: [
                      const Spacer(),
                      SizedBox(
                        width: 84,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton.filledTonal(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.30,
                              ),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _currentIndex <= 0
                                ? null
                                : () => _jumpTo(_currentIndex - 1),
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: 84,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: IconButton.filledTonal(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.30,
                              ),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _currentIndex >= widget.entries.length - 1
                                ? null
                                : () => _jumpTo(_currentIndex + 1),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (entry.caption.trim().isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: Text(
                        entry.caption.trim(),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  if (widget.entries.length > 1)
                    SizedBox(
                      height: 74,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: widget.entries.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final thumb = widget.entries[index];
                          final selected = index == _currentIndex;
                          return InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => _jumpTo(index),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 74,
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: selected
                                      ? Colors.white
                                      : Colors.white.withValues(alpha: 0.18),
                                  width: selected ? 2 : 1,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: AdaptiveNetworkImage(
                                  thumb.imageUrl,
                                  width: 70,
                                  height: 70,
                                  fit: BoxFit.cover,
                                  errorBuilder:
                                      (context, error, stackTrace) =>
                                          ColoredBox(
                                    color: Colors.white12,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomableMediaPage extends StatelessWidget {
  const _ZoomableMediaPage({required this.entry});

  final ChatMediaViewerEntry entry;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          media.size.width < 700 ? 12 : 64,
          media.size.width < 700 ? 88 : 64,
          media.size.width < 700 ? 12 : 64,
          media.size.width < 700 ? 132 : 110,
        ),
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4.5,
          child: AdaptiveNetworkImage(
            entry.imageUrl,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.all(32),
              child: const Icon(
                Icons.broken_image_outlined,
                color: Colors.white70,
                size: 44,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
