// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'sticker_print_service_stub.dart';

bool get isStickerPrintSupported =>
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;

Future<void> _waitForPrintDocumentReady(js.JsObject windowRef) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final readyFlag = windowRef['__PHOENIX_STICKER_READY__'];
    if (readyFlag == true) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  throw StateError('Не удалось подготовить страницу печати');
}

String _escapeHtml(String raw) {
  return raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

String _stickerPayloadHash(StickerPrintJob job) {
  final payload = <String, dynamic>{
    'phone': _escapeHtml(job.phone.trim()),
    'name': _escapeHtml(job.name.trim()),
    'productTitle': _escapeHtml((job.productTitle ?? '').trim()),
    'priceLabel': _escapeHtml((job.priceLabel ?? '').trim()),
    'kindLabel': _escapeHtml((job.kindLabel ?? '').trim()),
    'footerText': _escapeHtml((job.footerText ?? 'Феникс').trim()),
    'showFooter': job.showFooter,
  };
  return Uri.encodeComponent(jsonEncode(payload));
}

Future<void> printStickerJob(StickerPrintJob job) async {
  if (!isStickerPrintSupported) {
    throw UnsupportedError('Печать стикеров доступна только на десктоп-сайте');
  }
  final body = html.document.body;
  if (body == null) {
    throw StateError('Не удалось получить документ для печати');
  }

  final cacheBuster = DateTime.now().millisecondsSinceEpoch;
  final frame = html.IFrameElement()
    ..src = 'print_sticker.html?v=$cacheBuster#${_stickerPayloadHash(job)}'
    ..style.position = 'fixed'
    ..style.right = '0'
    ..style.bottom = '0'
    ..style.width = '0'
    ..style.height = '0'
    ..style.border = '0'
    ..style.opacity = '0'
    ..style.pointerEvents = 'none';

  final completer = Completer<void>();
  late StreamSubscription<html.Event> loadSub;
  loadSub = frame.onLoad.listen((_) async {
    await loadSub.cancel();
    if (!completer.isCompleted) completer.complete();
  });

  body.append(frame);
  try {
    await completer.future.timeout(const Duration(seconds: 5));
    final frameWindow = frame.contentWindow;
    if (frameWindow == null) {
      throw StateError('Не удалось открыть встроенное окно печати');
    }
    final windowRef = js.JsObject.fromBrowserObject(frameWindow);
    await _waitForPrintDocumentReady(windowRef);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    windowRef.callMethod('focus');
    windowRef.callMethod('print');
  } finally {
    Future<void>.delayed(const Duration(seconds: 20), () {
      frame.remove();
    });
  }
}
