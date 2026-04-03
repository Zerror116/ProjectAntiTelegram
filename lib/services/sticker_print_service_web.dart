// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'sticker_print_service_stub.dart';

bool get isStickerPrintSupported =>
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;

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
  final cacheBuster = DateTime.now().millisecondsSinceEpoch;
  final url = 'print_sticker.html?v=$cacheBuster#${_stickerPayloadHash(job)}';
  html.window.open(url, '_blank');
}
