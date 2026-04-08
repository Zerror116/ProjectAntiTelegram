// ignore_for_file: deprecated_member_use

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

const _rootWorkerUrl = '/flutter_service_worker.js';
const _maxRememberedPrimedUrls = 240;
const _maxBatchSize = 12;
const _flushDelay = Duration(milliseconds: 140);

final Set<String> _queuedImageUrls = <String>{};
final Set<String> _rememberedPrimedUrls = <String>{};
final List<String> _rememberedPrimedOrder = <String>[];
Timer? _flushTimer;
bool _flushInFlight = false;

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

void _rememberPrimedBatch(Iterable<String> urls) {
  for (final url in urls) {
    if (_rememberedPrimedUrls.add(url)) {
      _rememberedPrimedOrder.add(url);
    }
  }
  while (_rememberedPrimedOrder.length > _maxRememberedPrimedUrls) {
    final oldest = _rememberedPrimedOrder.removeAt(0);
    _rememberedPrimedUrls.remove(oldest);
  }
}

Future<void> _flushQueuedImageUrls() async {
  if (_flushInFlight) return;
  if (_queuedImageUrls.isEmpty) return;
  _flushInFlight = true;
  try {
    final sw = html.window.navigator.serviceWorker;
    if (sw == null) return;
    final registration = await _ensureImageWorkerRegistration();
    if (registration == null) return;

    void postBatch(List<String> batch) {
      if (batch.isEmpty) return;

      void postTo(dynamic worker) {
        if (worker == null) return;
        try {
          worker.postMessage(<String, dynamic>{
            'type': 'precache-images',
            'urls': batch,
          });
        } catch (_) {
          // ignore
        }
      }

      postTo(sw.controller);
      postTo(registration.active);
      postTo(registration.waiting);
      postTo(registration.installing);
    }

    while (_queuedImageUrls.isNotEmpty) {
      final batch = _queuedImageUrls.take(_maxBatchSize).toList(growable: false);
      for (final url in batch) {
        _queuedImageUrls.remove(url);
      }
      postBatch(batch);
      _rememberPrimedBatch(batch);
      try {
        final ready = await sw.ready.timeout(const Duration(seconds: 2));
        if (batch.isNotEmpty) {
          try {
            ready.active?.postMessage(<String, dynamic>{
              'type': 'precache-images',
              'urls': batch,
            });
          } catch (_) {
            // ignore
          }
        }
      } catch (_) {
        // ignore
      }
      if (_queuedImageUrls.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  } finally {
    _flushInFlight = false;
    if (_queuedImageUrls.isNotEmpty) {
      _flushTimer?.cancel();
      _flushTimer = Timer(_flushDelay, () {
        unawaited(_flushQueuedImageUrls());
      });
    }
  }
}

Future<void> primeWebImageCache(List<String> urls) async {
  if (urls.isEmpty) return;
  final cleanedUrls = urls
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .where((value) {
        final uri = Uri.tryParse(value);
        if (uri == null) return false;
        if (!uri.hasScheme) return true;
        return uri.scheme == 'http' || uri.scheme == 'https';
      })
      .toSet()
      .toList(growable: false);
  if (cleanedUrls.isEmpty) return;

  var changed = false;
  for (final url in cleanedUrls) {
    if (_rememberedPrimedUrls.contains(url) || _queuedImageUrls.contains(url)) {
      continue;
    }
    _queuedImageUrls.add(url);
    changed = true;
  }
  if (!changed) return;

  _flushTimer?.cancel();
  _flushTimer = Timer(_flushDelay, () {
    unawaited(_flushQueuedImageUrls());
  });
  if (_queuedImageUrls.length >= _maxBatchSize && !_flushInFlight) {
    _flushTimer?.cancel();
    await _flushQueuedImageUrls();
  }
}
