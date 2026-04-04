import 'package:flutter/material.dart';

import '../services/sticker_print_service.dart';

class StickerPreviewCard extends StatelessWidget {
  const StickerPreviewCard({
    super.key,
    required this.job,
    this.showShadow = true,
  });

  final StickerPrintJob job;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    final phone = job.phone.trim().isEmpty ? '89277613521' : job.phone.trim();
    final name = job.name.trim().isEmpty ? 'Василя' : job.name.trim();
    final title = (job.productTitle ?? '').trim();
    final price = (job.priceLabel ?? '').trim();
    final footer = (job.footerText ?? 'Феникс').trim();

    return AspectRatio(
      aspectRatio: 115 / 70,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: showShadow
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(5, 5, 8, 8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black, width: 1.4),
            ),
            padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final lines = <Widget>[
                        Text(
                          phone,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 104,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.08,
                            color: Colors.black,
                            height: 0.95,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.visible,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 90,
                            fontWeight: FontWeight.w800,
                            height: 0.98,
                            color: Colors.black,
                          ),
                        ),
                      ];
                      if (title.isNotEmpty) {
                        lines.addAll([
                          const SizedBox(height: 5),
                          Text(
                            title,
                            maxLines: 3,
                            overflow: TextOverflow.visible,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 42,
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                              color: Colors.black,
                            ),
                          ),
                        ]);
                      }
                      if (price.isNotEmpty) {
                        lines.addAll([
                          const SizedBox(height: 3),
                          Text(
                            price,
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.w900,
                              color: Colors.black,
                              height: 0.98,
                            ),
                          ),
                        ]);
                      }

                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: lines,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (job.showFooter)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      footer,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF222222),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
