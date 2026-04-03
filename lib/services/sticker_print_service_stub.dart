import 'package:flutter/foundation.dart';

@immutable
class StickerPrintJob {
  const StickerPrintJob({
    required this.phone,
    required this.name,
    this.productTitle,
    this.priceLabel,
    this.kindLabel,
    this.footerText,
    this.showFooter = false,
  });

  final String phone;
  final String name;
  final String? productTitle;
  final String? priceLabel;
  final String? kindLabel;
  final String? footerText;
  final bool showFooter;

  bool get hasExtendedDetails {
    return (productTitle ?? '').trim().isNotEmpty ||
        (priceLabel ?? '').trim().isNotEmpty ||
        (kindLabel ?? '').trim().isNotEmpty;
  }
}

bool get isStickerPrintSupported => false;

Future<void> printStickerJob(StickerPrintJob job) async {
  throw UnsupportedError('Печать стикеров доступна только на десктоп-сайте');
}
