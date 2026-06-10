import 'app_audio_session_service_stub.dart'
    if (dart.library.html) 'app_audio_session_service_web.dart'
    as impl;

class AppAudioSessionService {
  const AppAudioSessionService._();

  static void configureUiSoundForMixing() {
    impl.configureUiSoundForMixing();
  }
}
