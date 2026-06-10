// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void configureUiSoundForMixing() {
  try {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    final audioSession = navigator?.getProperty<JSObject?>(
      'audioSession'.toJS,
    );
    if (audioSession == null) return;
    audioSession.setProperty('type'.toJS, 'ambient'.toJS);
  } catch (_) {
    // Unsupported browsers keep the default audio behavior.
  }
}
