import 'package:flutter/material.dart';

class AppAvatar extends StatelessWidget {
  final String title;
  final String? imageUrl;
  final double focusX;
  final double focusY;
  final double zoom;
  final double radius;
  final IconData fallbackIcon;
  final Color? backgroundColor;
  final TextStyle? initialsStyle;

  const AppAvatar({
    super.key,
    required this.title,
    this.imageUrl,
    this.focusX = 0,
    this.focusY = 0,
    this.zoom = 1,
    this.radius = 20,
    this.fallbackIcon = Icons.person_outline,
    this.backgroundColor,
    this.initialsStyle,
  });

  String _initials() {
    final parts = title
        .trim()
        .split(' ')
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    return parts.map((part) => part[0]).take(2).join().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final initials = _initials();
    final size = radius * 2;
    final fill =
        backgroundColor ??
        Theme.of(context).colorScheme.surfaceContainerHighest;

    if (imageUrl == null || imageUrl!.trim().isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: fill,
        child: initials == '?'
            ? Icon(
                fallbackIcon,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )
            : Text(
                initials,
                style:
                    initialsStyle ??
                    TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
              ),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: fill,
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Transform.scale(
            scale: zoom.clamp(1.0, 4.0),
            alignment: Alignment(
              focusX.clamp(-1.0, 1.0),
              focusY.clamp(-1.0, 1.0),
            ),
            child: Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              alignment: Alignment(
                focusX.clamp(-1.0, 1.0),
                focusY.clamp(-1.0, 1.0),
              ),
              errorBuilder: (_, error, stackTrace) => Center(
                child: initials == '?'
                    ? Icon(
                        fallbackIcon,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )
                    : Text(
                        initials,
                        style:
                            initialsStyle ??
                            TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
