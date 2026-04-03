// ignore_for_file: deprecated_member_use

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;

Future<void> primeWebImageCache(List<String> urls) async {
  if (urls.isEmpty) return;
  final sw = html.window.navigator.serviceWorker;
  if (sw == null) return;

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
  try {
    final registration = await sw.ready;
    postTo(registration.active);
    postTo(registration.waiting);
    postTo(registration.installing);
  } catch (_) {
    // ignore
  }
}
