// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;

import 'package:flutter/foundation.dart';

import 'sticker_print_service_stub.dart';

bool get isStickerPrintSupported =>
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;

Future<void> _waitForPrintDocumentReady(html.Document document) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final readyState = (document.readyState ?? '').toLowerCase();
    if ((readyState == 'interactive' || readyState == 'complete') &&
        document.querySelector('body') != null &&
        document.getElementById('sticker-content') != null) {
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

String _stickerMarkup(StickerPrintJob job) {
  final safePhone = _escapeHtml(job.phone.trim());
  final safeName = _escapeHtml(job.name.trim());
  final safeTitle = _escapeHtml((job.productTitle ?? '').trim());
  final safePrice = _escapeHtml((job.priceLabel ?? '').trim());
  final safeKind = _escapeHtml((job.kindLabel ?? '').trim());
  final safeFooter = _escapeHtml((job.footerText ?? 'Феникс').trim());
  final hasKind = safeKind.isNotEmpty;
  final hasTitle = safeTitle.isNotEmpty;
  final hasPrice = safePrice.isNotEmpty;
  final hasFooter = job.showFooter;

  return '''
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="utf-8">
    <title>Наклейка Феникс</title>
    <style>
      @page {
        size: 115mm 70mm;
        margin: 0;
      }

      html, body {
        margin: 0;
        padding: 0;
        width: 115mm;
        height: 70mm;
        background: #fff;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif;
        overflow: hidden;
      }

      body {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
      }

      .page {
        width: 115mm;
        height: 70mm;
        overflow: hidden;
        position: relative;
      }

      .sheet {
        width: 108.5mm;
        height: 63.5mm;
        margin: 2.1mm 3.2mm 4.4mm 2.1mm;
        box-sizing: border-box;
        overflow: hidden;
        position: relative;
        display: flex;
        flex-direction: column;
        padding: 4.2mm 4.2mm 3.1mm 2mm;
      }

      .sheet::before {
        content: "";
        position: absolute;
        inset: 0;
        border: 0.7mm solid #000;
        box-sizing: border-box;
        pointer-events: none;
      }

      .content {
        flex: 1 1 auto;
        min-height: 0;
        display: flex;
        flex-direction: column;
        justify-content: center;
        position: relative;
        z-index: 1;
      }

      .phone {
        font-size: 21mm;
        line-height: 1;
        font-weight: 900;
        letter-spacing: 0.08mm;
        white-space: nowrap;
        overflow: hidden;
      }

      .name {
        margin-top: 2.6mm;
        font-size: 15.5mm;
        line-height: 1.05;
        font-weight: 800;
        word-break: break-word;
      }

      .kind {
        margin-top: 2.3mm;
        font-size: 4.2mm;
        line-height: 1.1;
        font-weight: 800;
        letter-spacing: 0.35mm;
        text-transform: uppercase;
      }

      .title {
        margin-top: 1.4mm;
        font-size: 4.9mm;
        line-height: 1.08;
        font-weight: 700;
        word-break: break-word;
      }

      .price {
        margin-top: 1.2mm;
        font-size: 5.4mm;
        line-height: 1.05;
        font-weight: 900;
        white-space: nowrap;
        overflow: hidden;
      }

      .footer {
        margin-top: auto;
        align-self: flex-end;
        text-align: right;
        font-size: 2.3mm;
        font-weight: 800;
        color: #222;
        position: relative;
        z-index: 1;
      }
    </style>
  </head>
  <body>
    <div class="page">
      <div class="sheet">
        <div class="content" id="sticker-content">
          <div class="phone" id="sticker-phone">$safePhone</div>
          <div class="name" id="sticker-name">$safeName</div>
          ${hasKind ? '<div class="kind" id="sticker-kind">$safeKind</div>' : ''}
          ${hasTitle ? '<div class="title" id="sticker-title">$safeTitle</div>' : ''}
          ${hasPrice ? '<div class="price" id="sticker-price">$safePrice</div>' : ''}
        </div>
        ${hasFooter ? '<div class="footer">$safeFooter</div>' : ''}
      </div>
    </div>
    <script>
      (function() {
        function fitElement(el, maxPx, minPx) {
          if (!el) return;
          let size = maxPx;
          el.style.fontSize = size + 'px';
          while (size > minPx && (el.scrollWidth > el.clientWidth || el.scrollHeight > el.clientHeight)) {
            size -= 1;
            el.style.fontSize = size + 'px';
          }
        }

        function fitSticker() {
          const content = document.getElementById('sticker-content');
          const phone = document.getElementById('sticker-phone');
          const name = document.getElementById('sticker-name');
          const kind = document.getElementById('sticker-kind');
          const title = document.getElementById('sticker-title');
          const price = document.getElementById('sticker-price');
          if (!content || !phone || !name) return;

          phone.style.fontSize = '';
          name.style.fontSize = '';
          if (kind) kind.style.fontSize = '';
          if (title) title.style.fontSize = '';
          if (price) price.style.fontSize = '';

          fitElement(phone, 100, 30);
          fitElement(name, 74, 22);
          fitElement(kind, 22, 12);
          fitElement(title, 28, 12);
          fitElement(price, 32, 14);

          let attempts = 0;
          while (attempts < 60 && content.scrollHeight > content.clientHeight) {
            const nodes = [phone, name, kind, title, price].filter(Boolean);
            for (const node of nodes) {
              const size = parseFloat(getComputedStyle(node).fontSize);
              const minimum = node === phone ? 30 : node === name ? 22 : node === price ? 14 : 12;
              node.style.fontSize = Math.max(minimum, size - 1) + 'px';
            }
            attempts += 1;
          }
        }

        window.addEventListener('load', fitSticker);
        window.addEventListener('resize', fitSticker);
        window.addEventListener('beforeprint', fitSticker);
        setTimeout(fitSticker, 50);
      })();
    </script>
  </body>
</html>
''';
}

Future<void> printStickerJob(StickerPrintJob job) async {
  if (!isStickerPrintSupported) {
    throw UnsupportedError('Печать стикеров доступна только на десктоп-сайте');
  }
  final body = html.document.body;
  if (body == null) {
    throw StateError('Не удалось получить документ для печати');
  }

  final markup = _stickerMarkup(job);
  final frame = html.IFrameElement()
    ..style.position = 'fixed'
    ..style.right = '0'
    ..style.bottom = '0'
    ..style.width = '0'
    ..style.height = '0'
    ..style.border = '0'
    ..style.opacity = '0'
    ..style.pointerEvents = 'none';

  body.append(frame);
  try {
    final frameWindow = frame.contentWindow;
    if (frameWindow == null) {
      throw StateError('Не удалось открыть встроенное окно печати');
    }
    final frameDocument = (frameWindow as html.Window).document;
    final documentRef = js.JsObject.fromBrowserObject(frameDocument);
    documentRef.callMethod('open');
    documentRef.callMethod('write', <Object>[markup]);
    documentRef.callMethod('close');
    await _waitForPrintDocumentReady(frameDocument);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final windowRef = js.JsObject.fromBrowserObject(frameWindow);
    windowRef.callMethod('focus');
    windowRef.callMethod('print');
  } finally {
    Future<void>.delayed(const Duration(seconds: 20), () {
      frame.remove();
    });
  }
}
