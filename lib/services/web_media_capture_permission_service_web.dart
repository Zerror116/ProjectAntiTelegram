// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;

const _grantedStorageKey = 'projectphoenix_media_capture_access_v1';
const _sessionStorageKey = 'projectphoenix_media_capture_access_session_v1';

bool isSupported() {
  final navigator = js.context['navigator'];
  if (navigator == null) return false;
  return navigator['mediaDevices'] != null;
}

Future<dynamic> _jsPromiseToFuture(dynamic promise) {
  final completer = Completer<dynamic>();
  if (promise == null) {
    completer.complete(null);
    return completer.future;
  }

  final jsPromise = promise is js.JsObject
      ? promise
      : js.JsObject.fromBrowserObject(promise);
  final onFulfilled = js.JsFunction.withThis((_, dynamic value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  });
  final onRejected = js.JsFunction.withThis((_, dynamic error) {
    if (!completer.isCompleted) {
      completer.completeError(error ?? 'js_promise_rejected');
    }
  });
  jsPromise.callMethod('then', [onFulfilled, onRejected]);
  return completer.future;
}

js.JsObject _asJsObject(dynamic value) {
  return value is js.JsObject ? value : js.JsObject.fromBrowserObject(value);
}

String? _readStorageValue(html.Storage? storage, String key) {
  try {
    return storage?[key]?.trim();
  } catch (_) {
    return null;
  }
}

void _writeStorageValue(html.Storage? storage, String key, String? value) {
  try {
    if (value == null || value.isEmpty) {
      storage?.remove(key);
      return;
    }
    storage?[key] = value;
  } catch (_) {
    // ignore
  }
}

String _normalizeStoredState(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'granted_audio_only':
      return 'granted_audio_only';
    case 'granted_audio_video':
      return 'granted_audio_video';
    case 'denied':
      return 'denied';
    default:
      return 'default';
  }
}

String _currentStoredState() {
  final persistent = _normalizeStoredState(
    _readStorageValue(html.window.localStorage, _grantedStorageKey),
  );
  if (persistent == 'granted_audio_video' || persistent == 'granted_audio_only') {
    return persistent;
  }

  final session = _normalizeStoredState(
    _readStorageValue(html.window.sessionStorage, _sessionStorageKey),
  );
  if (session == 'denied') {
    return 'denied';
  }
  return 'default';
}

void _persistGrantedState(String grantedState) {
  _writeStorageValue(html.window.localStorage, _grantedStorageKey, grantedState);
  _writeStorageValue(html.window.sessionStorage, _sessionStorageKey, grantedState);
}

void _persistDeniedState() {
  _writeStorageValue(html.window.sessionStorage, _sessionStorageKey, 'denied');
}

Future<String> getPermissionState() async {
  if (!isSupported()) return 'unsupported';
  return _currentStoredState();
}

bool _looksLikeDeniedError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('notallowed') ||
      text.contains('permission') ||
      text.contains('denied') ||
      text.contains('security');
}

bool _looksLikeMissingDeviceError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('notfound') ||
      text.contains('device not found') ||
      text.contains('requested device not found') ||
      text.contains('overconstrained');
}

Future<String> _requestUserMedia({
  required bool includeVideo,
}) async {
  final navigator = js.context['navigator'];
  if (navigator == null) return 'unsupported';
  final mediaDevices = navigator['mediaDevices'];
  if (mediaDevices == null) return 'unsupported';

  final constraints = js.JsObject.jsify({
    'audio': true,
    'video': includeVideo
        ? {
            'facingMode': 'user',
            'width': {'ideal': 720},
            'height': {'ideal': 720},
          }
        : false,
  });

  final stream = await _jsPromiseToFuture(
    _asJsObject(mediaDevices).callMethod('getUserMedia', [constraints]),
  );
  try {
    final tracks = _asJsObject(stream).callMethod('getTracks') as js.JsArray;
    for (final track in tracks) {
      try {
        _asJsObject(track).callMethod('stop');
      } catch (_) {
        // ignore
      }
    }
  } catch (_) {
    // ignore
  }

  return includeVideo ? 'granted_audio_video' : 'granted_audio_only';
}

Future<String> requestPreferredAccess({
  required bool includeVideo,
  bool allowAudioOnlyFallback = false,
}) async {
  if (!isSupported()) return 'unsupported';

  final stored = _currentStoredState();
  if (includeVideo) {
    if (stored == 'granted_audio_video') {
      return stored;
    }
    if (stored == 'denied') {
      return stored;
    }
  } else {
    if (stored == 'granted_audio_video' || stored == 'granted_audio_only') {
      return stored;
    }
    if (stored == 'denied') {
      return stored;
    }
  }

  try {
    final granted = await _requestUserMedia(includeVideo: includeVideo);
    _persistGrantedState(granted);
    return granted;
  } catch (error) {
    if (includeVideo &&
        allowAudioOnlyFallback &&
        _looksLikeMissingDeviceError(error)) {
      try {
        final granted = await _requestUserMedia(includeVideo: false);
        _persistGrantedState(granted);
        return granted;
      } catch (audioError) {
        if (_looksLikeDeniedError(audioError)) {
          _persistDeniedState();
          return 'denied';
        }
        return 'default';
      }
    }

    if (_looksLikeDeniedError(error)) {
      _persistDeniedState();
      return 'denied';
    }
    return 'default';
  }
}
