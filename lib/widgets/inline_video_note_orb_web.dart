// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class InlineVideoNoteOrb extends StatefulWidget {
  const InlineVideoNoteOrb({
    super.key,
    required this.videoUrl,
    required this.durationMs,
    required this.accentColor,
  });

  final String videoUrl;
  final int durationMs;
  final Color accentColor;

  @override
  State<InlineVideoNoteOrb> createState() => _InlineVideoNoteOrbState();
}

class _InlineVideoNoteOrbState extends State<InlineVideoNoteOrb> {
  late final String _viewType;
  late final html.DivElement _wrapperElement;
  late final html.VideoElement _videoElement;
  StreamSubscription<html.MouseEvent>? _wrapperClickSub;
  StreamSubscription<html.TouchEvent>? _wrapperTouchEndSub;

  StreamSubscription<html.Event>? _loadedMetadataSub;
  StreamSubscription<html.Event>? _timeUpdateSub;
  StreamSubscription<html.Event>? _playSub;
  StreamSubscription<html.Event>? _pauseSub;
  StreamSubscription<html.Event>? _endedSub;
  StreamSubscription<html.Event>? _errorSub;
  StreamSubscription<html.Event>? _canPlaySub;

  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _hasFinished = false;
  bool _hasError = false;
  bool _playRequested = false;
  DateTime? _lastUserToggleAt;

  @override
  void initState() {
    super.initState();
    _viewType =
        'projectphoenix-inline-video-note-${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 20)}';
    _duration = widget.durationMs > 0
        ? Duration(milliseconds: widget.durationMs)
        : Duration.zero;

    _wrapperElement = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.borderRadius = '9999px'
      ..style.overflow = 'hidden'
      ..style.cursor = 'pointer'
      ..style.touchAction = 'manipulation'
      ..style.background =
          'radial-gradient(circle at 30% 18%, rgba(255,255,255,0.22), rgba(255,255,255,0.02) 38%, rgba(14,19,28,0.94) 74%)';

    _videoElement = html.VideoElement()
      ..src = widget.videoUrl
      ..preload = 'auto'
      ..loop = false
      ..muted = false
      ..autoplay = false
      ..controls = false
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..style.display = 'block'
      ..style.backgroundColor = '#101720'
      ..style.pointerEvents = 'none';

    _videoElement.setAttribute('playsinline', 'true');
    _videoElement.setAttribute('webkit-playsinline', 'true');
    _videoElement.setAttribute('x-webkit-airplay', 'allow');

    _wrapperElement.children.add(_videoElement);

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      return _wrapperElement;
    });

    _bindEvents();
    _videoElement.load();
  }

  void _bindEvents() {
    _wrapperClickSub = _wrapperElement.onClick.listen((event) {
      event
        ..preventDefault()
        ..stopPropagation();
      unawaited(_handleUserToggle());
    });
    _wrapperTouchEndSub = _wrapperElement.onTouchEnd.listen((event) {
      event
        ..preventDefault()
        ..stopPropagation();
      unawaited(_handleUserToggle());
    });

    _loadedMetadataSub = _videoElement.onLoadedMetadata.listen((_) {
      final seconds = _videoElement.duration;
      if (seconds.isFinite && seconds > 0) {
        _duration = Duration(milliseconds: (seconds * 1000).round());
      }
      if (mounted) {
        setState(() {
          _hasError = false;
        });
      }
    });

    _canPlaySub = _videoElement.onCanPlay.listen((_) {
      if (mounted) {
        setState(() {
          _hasError = false;
        });
      }
      if (_playRequested) {
        unawaited(_attemptPlay());
      }
    });

    _timeUpdateSub = _videoElement.onTimeUpdate.listen((_) {
      final total = _videoElement.duration;
      if (total.isFinite && total > 0) {
        _duration = Duration(milliseconds: (total * 1000).round());
      }
      if (mounted) {
        setState(() {});
      }
    });

    _playSub = _videoElement.onPlay.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _hasFinished = false;
        _hasError = false;
      });
    });

    _pauseSub = _videoElement.onPause.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
      });
    });

    _endedSub = _videoElement.onEnded.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _hasFinished = true;
      });
    });

    _errorSub = _videoElement.onError.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _hasError = true;
      });
    });
  }

  Future<void> _attemptPlay() async {
    _playRequested = true;
    try {
      if (_hasFinished) {
        _videoElement.currentTime = 0;
        _hasFinished = false;
      }
      await _videoElement.play();
      _playRequested = false;
    } catch (_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    }
  }

  Future<void> _handleUserToggle() async {
    final now = DateTime.now();
    final last = _lastUserToggleAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 420)) {
      return;
    }
    _lastUserToggleAt = now;
    await _togglePlayback();
  }

  Future<void> _togglePlayback() async {
    if (_hasError) {
      _videoElement.load();
      if (mounted) {
        setState(() {
          _hasError = false;
        });
      }
      return;
    }
    if (_isPlaying) {
      _videoElement.pause();
      return;
    }
    await _attemptPlay();
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds.clamp(0, 99 * 3600);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void didUpdateWidget(covariant InlineVideoNoteOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl == widget.videoUrl) return;
    _videoElement.src = widget.videoUrl;
    _videoElement.load();
    _duration = widget.durationMs > 0
        ? Duration(milliseconds: widget.durationMs)
        : Duration.zero;
    _isPlaying = false;
    _hasFinished = false;
    _hasError = false;
    _playRequested = false;
  }

  @override
  void dispose() {
    _wrapperClickSub?.cancel();
    _wrapperTouchEndSub?.cancel();
    _loadedMetadataSub?.cancel();
    _timeUpdateSub?.cancel();
    _playSub?.cancel();
    _pauseSub?.cancel();
    _endedSub?.cancel();
    _errorSub?.cancel();
    _canPlaySub?.cancel();
    try {
      _videoElement.pause();
    } catch (_) {}
    _videoElement.src = '';
    _wrapperElement.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalDuration = _duration;
    final durationLabel = totalDuration <= Duration.zero
        ? '0:00'
        : _formatDuration(totalDuration);

    Widget durationBadge() {
      return IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            durationLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 250,
      height: 222,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: 212,
            height: 212,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  startAngle: -math.pi * 0.62,
                  endAngle: math.pi * 1.38,
                  colors: [
                    const Color(0xFF3B82FF),
                    const Color(0xFF20D6E9),
                    const Color(0xFFFF8848),
                    widget.accentColor,
                    const Color(0xFF3B82FF),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3B82FF).withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.24),
                    blurRadius: 24,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0F131B),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipOval(
                        child: ColoredBox(
                          color: const Color(0xFF11161D),
                          child: HtmlElementView(viewType: _viewType),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ClipOval(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.04),
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.18),
                                ],
                                stops: const [0, 0.60, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(right: 0, bottom: 0, child: durationBadge()),
        ],
      ),
    );
  }
}
