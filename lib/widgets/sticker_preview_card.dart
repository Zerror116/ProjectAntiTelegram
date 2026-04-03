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
    final kindLabel = (job.kindLabel ?? '').trim();
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
            padding: const EdgeInsets.fromLTRB(3, 8, 8, 6),
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
                          style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.visible,
                          style: const TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                            color: Colors.black,
                          ),
                        ),
                      ];
                      if (kindLabel.isNotEmpty) {
                        lines.addAll([
                          const SizedBox(height: 8),
                          Text(
                            kindLabel,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                              color: Colors.black,
                            ),
                          ),
                        ]);
                      }
                      if (title.isNotEmpty) {
                        lines.addAll([
                          const SizedBox(height: 6),
                          Text(
                            title,
                            maxLines: 3,
                            overflow: TextOverflow.visible,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              height: 1.08,
                              color: Colors.black,
                            ),
                          ),
                        ]);
                      }
                      if (price.isNotEmpty) {
                        lines.addAll([
                          const SizedBox(height: 6),
                          Text(
                            price,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Colors.black,
                            ),
                          ),
                        ]);
                      }

                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
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
