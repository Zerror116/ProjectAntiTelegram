// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class InlineVideoNoteOrb extends StatefulWidget {
  const InlineVideoNoteOrb({
    super.key,
    required this.videoUrl,
    required this.durationMs,
    required this.accentColor,
    required this.footerText,
  });

  final String videoUrl;
  final int durationMs;
  final Color accentColor;
  final String footerText;

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

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isReady = false;
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
          _isReady = true;
          _hasError = false;
        });
      }
    });

    _canPlaySub = _videoElement.onCanPlay.listen((_) {
      if (mounted) {
        setState(() {
          _isReady = true;
          _hasError = false;
        });
      }
      if (_playRequested) {
        unawaited(_attemptPlay());
      }
    });

    _timeUpdateSub = _videoElement.onTimeUpdate.listen((_) {
      final seconds = _videoElement.currentTime;
      final total = _videoElement.duration;
      if (total.isFinite && total > 0) {
        _duration = Duration(milliseconds: (total * 1000).round());
      }
      if (seconds.isFinite && seconds >= 0) {
        _position = Duration(milliseconds: (seconds * 1000).round());
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
        _isReady = true;
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
        if (_duration > Duration.zero) {
          _position = _duration;
        }
      });
    });

    _errorSub = _videoElement.onError.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _isReady = false;
        _hasError = true;
      });
    });
  }

  Future<void> _attemptPlay() async {
    _playRequested = true;
    try {
      if (_hasFinished) {
        _videoElement.currentTime = 0;
        _position = Duration.zero;
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
          _isReady = false;
          _position = Duration.zero;
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
    _position = Duration.zero;
    _duration = widget.durationMs > 0
        ? Duration(milliseconds: widget.durationMs)
        : Duration.zero;
    _isReady = false;
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
    final progress = totalDuration.inMilliseconds > 0
        ? (_position.inMilliseconds / totalDuration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble()
        : 0.0;
    final durationLabel = totalDuration <= Duration.zero
        ? '0:00'
        : (!_hasFinished &&
              !_isPlaying &&
              _position <= const Duration(milliseconds: 160))
        ? _formatDuration(totalDuration)
        : '${_formatDuration(_position)} / ${_formatDuration(totalDuration)}';

    IconData actionIcon;
    if (_hasError) {
      actionIcon = Icons.refresh_rounded;
    } else if (_isPlaying) {
      actionIcon = Icons.pause_rounded;
    } else if (_hasFinished) {
      actionIcon = Icons.replay_rounded;
    } else {
      actionIcon = Icons.play_arrow_rounded;
    }

    final footerLabel = _hasError
        ? 'Нажмите, чтобы попробовать снова'
        : _isPlaying
        ? 'Нажмите для паузы'
        : _isReady
        ? widget.footerText
        : 'Подготавливаем воспроизведение';

    return Container(
      width: 196,
      height: 196,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.accentColor.withValues(alpha: 0.82),
            const Color(0xFF1C2631),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
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
                          Colors.black.withValues(alpha: 0.06),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.32),
                        ],
                        stops: const [0, 0.56, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isPlaying
                          ? Icons.equalizer_rounded
                          : Icons.videocam_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isPlaying ? 'видео' : 'кружок',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.94),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
              left: 16,
              right: 16,
              bottom: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.18),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          footerLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.86),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          durationLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Center(
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 74,
                      height: 74,
                      child: CircularProgressIndicator(
                        value: !_isReady && !_hasError ? null : progress,
                        strokeWidth: 3.2,
                        backgroundColor: Colors.white.withValues(alpha: 0.14),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 10,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: (!_isReady && !_hasError)
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  widget.accentColor,
                                ),
                              ),
                            )
                          : Icon(actionIcon, color: widget.accentColor, size: 34),
                    ),
                  ],
                ),
              ),
          ),
        ],
      ),
    );
  }
}
