import 'web_media_capture_permission_service_stub.dart'
    if (dart.library.html) 'web_media_capture_permission_service_web.dart'
    as impl;

enum WebMediaCaptureAccessState {
  unsupported,
  defaultState,
  grantedAudioOnly,
  grantedAudioVideo,
  denied,
}

WebMediaCaptureAccessState _parseState(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'granted_audio_only':
      return WebMediaCaptureAccessState.grantedAudioOnly;
    case 'granted_audio_video':
      return WebMediaCaptureAccessState.grantedAudioVideo;
    case 'denied':
      return WebMediaCaptureAccessState.denied;
    case 'default':
      return WebMediaCaptureAccessState.defaultState;
    default:
      return WebMediaCaptureAccessState.unsupported;
  }
}

class WebMediaCapturePermissionService {
  const WebMediaCapturePermissionService._();

  static bool get isSupported => impl.isSupported();

  static Future<WebMediaCaptureAccessState> getPermissionState() async {
    return _parseState(await impl.getPermissionState());
  }

  static Future<WebMediaCaptureAccessState> requestPreferredAccess({
    required bool includeVideo,
    bool allowAudioOnlyFallback = false,
  }) async {
    return _parseState(
      await impl.requestPreferredAccess(
        includeVideo: includeVideo,
        allowAudioOnlyFallback: allowAudioOnlyFallback,
      ),
    );
  }
}
