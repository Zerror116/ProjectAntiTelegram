// ignore_for_file: deprecated_member_use

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

const _rootWorkerUrl = '/flutter_service_worker.js';

Future<html.ServiceWorkerRegistration?> _ensureImageWorkerRegistration() async {
  final sw = html.window.navigator.serviceWorker;
  if (sw == null) return null;
  try {
    final dynamic existing = await sw.getRegistration();
    if (existing != null) return existing;
  } catch (_) {
    // ignore
  }
  try {
    return await sw.register(_rootWorkerUrl);
  } catch (_) {
    return null;
  }
}

Future<void> primeWebImageCache(List<String> urls) async {
  if (urls.isEmpty) return;
  final sw = html.window.navigator.serviceWorker;
  if (sw == null) return;
  final registration = await _ensureImageWorkerRegistration();
  if (registration == null) return;

  final cleanedUrls = urls
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
  if (cleanedUrls.isEmpty) return;

  void postTo(dynamic worker) {
    if (worker == null) return;
    try {
      worker.postMessage(<String, dynamic>{
        'type': 'precache-images',
        'urls': cleanedUrls,
      });
    } catch (_) {
      // ignore
    }
  }

  postTo(sw.controller);
  postTo(registration.active);
  postTo(registration.waiting);
  postTo(registration.installing);
  try {
    final ready = await sw.ready.timeout(const Duration(seconds: 2));
    postTo(ready.active);
    postTo(ready.waiting);
    postTo(ready.installing);
  } catch (_) {
    // ignore
  }
}
