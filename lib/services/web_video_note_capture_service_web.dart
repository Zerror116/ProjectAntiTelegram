// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

html.MediaRecorder? _recorder;
html.MediaStream? _stream;
html.VideoElement? _previewElement;
DateTime? _startedAt;
String _selectedMimeType = '';
bool _cancelRequested = false;
Completer<Map<String, dynamic>?>? _stopCompleter;
final List<html.Blob> _chunks = <html.Blob>[];
const String _previewViewType = 'project-fenix-video-note-preview';
bool _previewViewRegistered = false;

bool isSupported() {
  try {
    return html.window.navigator.mediaDevices != null &&
        js.context['MediaRecorder'] != null;
  } catch (_) {
    return false;
  }
}

String _bestMimeType() {
  const candidates = <String>[
    'video/webm;codecs=vp8,opus',
    'video/webm;codecs=vp9,opus',
    'video/webm',
    'video/mp4;codecs=h264,aac',
    'video/mp4',
  ];
  for (final candidate in candidates) {
    try {
      if (html.MediaRecorder.isTypeSupported(candidate)) {
        return candidate;
      }
    } catch (_) {
      // Browser may expose MediaRecorder without isTypeSupported.
    }
  }
  return '';
}

String _extensionForMime(String mimeType) {
  final lower = mimeType.toLowerCase();
  if (lower.contains('mp4')) return 'mp4';
  if (lower.contains('quicktime')) return 'mov';
  return 'webm';
}

Map<String, dynamic> _videoConstraints() {
  return <String, dynamic>{
    'facingMode': 'user',
    'width': <String, dynamic>{'ideal': 720},
    'height': <String, dynamic>{'ideal': 720},
    'aspectRatio': <String, dynamic>{'ideal': 1},
  };
}

Future<void> start() async {
  if (!isSupported()) {
    throw UnsupportedError('MediaRecorder is not supported in this browser');
  }
  if (_recorder != null) {
    throw StateError('Video note recording is already active');
  }

  final mediaDevices = html.window.navigator.mediaDevices;
  if (mediaDevices == null) {
    throw UnsupportedError('mediaDevices is not available');
  }

  final stream = await mediaDevices.getUserMedia(<String, dynamic>{
    'audio': true,
    'video': _videoConstraints(),
  });
  _attachPreviewElement(stream);

  final mimeType = _bestMimeType();
  final options = <String, dynamic>{
    if (mimeType.isNotEmpty) 'mimeType': mimeType,
    'videoBitsPerSecond': 900000,
    'audioBitsPerSecond': 64000,
  };
  final recorder = options.isEmpty
      ? html.MediaRecorder(stream)
      : html.MediaRecorder(stream, options);

  _stream = stream;
  _recorder = recorder;
  _selectedMimeType = recorder.mimeType?.trim().isNotEmpty == true
      ? recorder.mimeType!.trim()
      : mimeType;
  _startedAt = DateTime.now();
  _cancelRequested = false;
  _chunks.clear();

  recorder.addEventListener('dataavailable', _handleDataAvailable);
  recorder.addEventListener('stop', _handleStop);
  recorder.addEventListener('error', _handleError);
  recorder.start(250);
}

Future<Map<String, dynamic>> stop() async {
  final recorder = _recorder;
  if (recorder == null) {
    throw StateError('Video note recording is not active');
  }
  _cancelRequested = false;
  final completer = Completer<Map<String, dynamic>?>();
  _stopCompleter = completer;
  try {
    recorder.requestData();
  } catch (_) {
    // Some browsers throw if data is already being flushed.
  }
  recorder.stop();
  final result = await completer.future.timeout(const Duration(seconds: 12));
  if (result == null) {
    throw StateError('Video note recording was cancelled');
  }
  return result;
}

Future<void> cancel() async {
  final recorder = _recorder;
  if (recorder == null) {
    _cleanup();
    return;
  }
  _cancelRequested = true;
  final completer = Completer<Map<String, dynamic>?>();
  _stopCompleter = completer;
  try {
    recorder.stop();
    await completer.future.timeout(const Duration(seconds: 4));
  } catch (_) {
    _cleanup();
  }
}

Widget previewWidget({Key? key}) {
  _ensurePreviewViewRegistered();
  return HtmlElementView(key: key, viewType: _previewViewType);
}

void _ensurePreviewViewRegistered() {
  if (_previewViewRegistered) return;
  ui_web.platformViewRegistry.registerViewFactory(_previewViewType, (
    int viewId,
  ) {
    return _previewElement ?? _buildEmptyPreviewElement();
  });
  _previewViewRegistered = true;
}

html.Element _buildEmptyPreviewElement() {
  return html.DivElement()
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.background = '#241631';
}

void _attachPreviewElement(html.MediaStream stream) {
  _ensurePreviewViewRegistered();
  final element = html.VideoElement()
    ..autoplay = true
    ..muted = true
    ..srcObject = stream;
  element.setAttribute('playsinline', 'true');
  element.setAttribute('webkit-playsinline', 'true');
  element.style
    ..width = '100%'
    ..height = '100%'
    ..objectFit = 'cover'
    ..backgroundColor = '#000'
    ..transform = 'scaleX(-1)';
  unawaited(element.play().catchError((_) {}));
  _previewElement = element;
}

void _handleDataAvailable(html.Event event) {
  final blob = event is html.BlobEvent ? event.data : null;
  if (blob != null && blob.size > 0) {
    _chunks.add(blob);
  }
}

void _handleStop(html.Event event) {
  final completer = _stopCompleter;
  _stopCompleter = null;
  if (completer == null || completer.isCompleted) {
    _cleanup();
    return;
  }
  if (_cancelRequested) {
    _cleanup();
    completer.complete(null);
    return;
  }
  unawaited(_completeStop(completer));
}

void _handleError(html.Event event) {
  final completer = _stopCompleter;
  if (completer != null && !completer.isCompleted) {
    completer.completeError(StateError('MediaRecorder error'));
  }
  _cleanup();
}

Future<void> _completeStop(Completer<Map<String, dynamic>?> completer) async {
  try {
    final mimeType = _selectedMimeType.isNotEmpty
        ? _selectedMimeType
        : (_chunks.isNotEmpty ? _chunks.first.type : 'video/webm');
    final blob = html.Blob(_chunks, mimeType);
    final bytes = await _blobToBytes(blob);
    final durationMs = DateTime.now()
        .difference(_startedAt ?? DateTime.now())
        .inMilliseconds;
    _cleanup();
    completer.complete(<String, dynamic>{
      'bytes': bytes,
      'filename':
          'video-note-${DateTime.now().millisecondsSinceEpoch}.${_extensionForMime(mimeType)}',
      'duration_ms': durationMs,
      'mime_type': mimeType.isNotEmpty ? mimeType : 'video/webm',
    });
  } catch (error) {
    _cleanup();
    completer.completeError(error);
  }
}

Future<Uint8List> _blobToBytes(html.Blob blob) {
  final reader = html.FileReader();
  final completer = Completer<Uint8List>();
  late StreamSubscription<html.ProgressEvent> loadSub;
  late StreamSubscription<html.ProgressEvent> errorSub;
  loadSub = reader.onLoad.listen((_) {
    errorSub.cancel();
    loadSub.cancel();
    final result = reader.result;
    if (result is Uint8List) {
      completer.complete(result);
      return;
    }
    if (result is ByteBuffer) {
      completer.complete(Uint8List.view(result));
      return;
    }
    completer.completeError(StateError('Unexpected blob reader result'));
  });
  errorSub = reader.onError.listen((_) {
    loadSub.cancel();
    errorSub.cancel();
    completer.completeError(reader.error ?? StateError('Blob read failed'));
  });
  reader.readAsArrayBuffer(blob);
  return completer.future;
}

void _cleanup() {
  final recorder = _recorder;
  if (recorder != null) {
    try {
      recorder.removeEventListener('dataavailable', _handleDataAvailable);
      recorder.removeEventListener('stop', _handleStop);
      recorder.removeEventListener('error', _handleError);
    } catch (_) {
      // ignore
    }
  }
  final stream = _stream;
  if (stream != null) {
    for (final track in stream.getTracks()) {
      try {
        track.stop();
      } catch (_) {
        // ignore
      }
    }
  }
  _previewElement
    ?..pause()
    ..srcObject = null
    ..remove();
  _previewElement = null;
  _recorder = null;
  _stream = null;
  _startedAt = null;
  _selectedMimeType = '';
  _cancelRequested = false;
  _chunks.clear();
}
