// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSObject? _bridgeObject() {
  return globalContext.getProperty<JSObject?>('projectPhoenixBootstrap'.toJS);
}

void _call(String method, [String? message]) {
  final bridge = _bridgeObject();
  if (bridge == null) return;
  try {
    final candidate = bridge.getProperty<JSFunction?>(method.toJS);
    if (candidate == null) return;
    if (message == null) {
      candidate.callAsFunction(bridge);
      return;
    }
    candidate.callAsFunction(bridge, message.toJS);
  } catch (_) {
    // no-op
  }
}

void setStatus(String message) {
  _call('setStatus', message);
}

void markReady() {
  _call('ready');
}

void showError(String message) {
  _call('fail', message);
}
