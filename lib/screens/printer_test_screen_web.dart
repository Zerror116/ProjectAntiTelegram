// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;

import 'package:flutter/material.dart';

import '../main.dart';

class PrinterTestScreen extends StatefulWidget {
  const PrinterTestScreen({super.key});

  @override
  State<PrinterTestScreen> createState() => _PrinterTestScreenState();
}

class _PrinterTestScreenState extends State<PrinterTestScreen> {
  final TextEditingController _phoneController = TextEditingController(
    text: '89277613521',
  );
  final TextEditingController _nameController = TextEditingController(
    text: 'Василя',
  );

  bool _printing = false;
  String _statusText =
      'Подключите термопринтер к компьютеру по USB или Bluetooth и выберите его в системном окне печати браузера.';

  @override
  void dispose() {
    _phoneController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  String _escapeHtml(String raw) {
    return raw
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  String _buildPrintMarkup({
    required String phone,
    required String name,
  }) {
    final safePhone = _escapeHtml(phone);
    final safeName = _escapeHtml(name);
    return '''
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="utf-8">
    <title>Наклейка Феникс</title>
    <style>
      @page {
        size: 120mm 75mm;
        margin: 0;
      }

      html, body {
        margin: 0;
        padding: 0;
        width: 120mm;
        height: 75mm;
        background: #fff;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif;
      }

      body {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
      }

      .sheet {
        width: 120mm;
        height: 75mm;
        box-sizing: border-box;
        border: 1.2mm solid #000;
        padding: 7mm 9mm;
        display: flex;
        flex-direction: column;
      }

      .phone {
        font-size: 18mm;
        line-height: 1;
        font-weight: 900;
        letter-spacing: 0.4mm;
      }

      .name {
        margin-top: 5mm;
        font-size: 14mm;
        line-height: 1.05;
        font-weight: 800;
        word-break: break-word;
      }

      .footer {
        margin-top: auto;
        font-size: 3.5mm;
        font-weight: 700;
        color: #555;
      }
    </style>
  </head>
  <body>
    <div class="sheet">
      <div class="phone">$safePhone</div>
      <div class="name">$safeName</div>
      <div class="footer">Феникс • тестовая наклейка • 120x75 мм</div>
    </div>
  </body>
</html>
''';
  }

  Future<void> _printTestSticker() async {
    final phone = _phoneController.text.trim();
    final name = _nameController.text.trim();
    if (phone.isEmpty || name.isEmpty) {
      showAppNotice(
        context,
        'Заполните телефон и имя для пробной наклейки',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _printing = true;
      _statusText =
          'Открываем системное окно печати. В нём выберите термопринтер, подключенный к компьютеру по USB или Bluetooth.';
    });

    String? blobUrl;
    js.JsObject? printWindow;
    try {
      final blob = html.Blob(
        [_buildPrintMarkup(phone: phone, name: name)],
        'text/html;charset=utf-8',
      );
      blobUrl = html.Url.createObjectUrlFromBlob(blob);
      final opened = js.context.callMethod('open', [blobUrl, '_blank']);
      printWindow = opened is js.JsObject
          ? opened
          : (opened == null ? null : js.JsObject.fromBrowserObject(opened));
      if (printWindow == null) {
        throw StateError('Браузер заблокировал окно печати');
      }
      final windowRef = printWindow;

      await Future<void>.delayed(const Duration(milliseconds: 650));
      windowRef.callMethod('focus');
      windowRef.callMethod('print');

      if (!mounted) return;
      setState(() {
        _statusText =
            'Окно печати открыто. Выберите термопринтер и подтвердите пробную печать.';
      });
      showAppNotice(
        context,
        'Окно печати открыто. Выберите USB/Bluetooth-принтер в системном диалоге.',
        tone: AppNoticeTone.info,
        duration: const Duration(seconds: 5),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Не удалось открыть печать: $e';
      });
      showAppNotice(
        context,
        'Не удалось открыть системную печать: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      Future<void>.delayed(const Duration(seconds: 15), () {
        final closeWindow = printWindow;
        if (closeWindow != null) {
          try {
            closeWindow.callMethod('close');
          } catch (_) {}
        }
        final closeBlobUrl = blobUrl;
        if (closeBlobUrl != null) {
          html.Url.revokeObjectUrl(closeBlobUrl);
        }
      });
      if (mounted) {
        setState(() => _printing = false);
      }
    }
  }

  Widget _buildPreviewCard(BuildContext context) {
    final phone = _phoneController.text.trim().isEmpty
        ? '89277613521'
        : _phoneController.text.trim();
    final name = _nameController.text.trim().isEmpty
        ? 'Василя'
        : _nameController.text.trim();

    return AspectRatio(
      aspectRatio: 120 / 75,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black, width: 1.8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 18,
              offset: Offset(0, 10),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    phone,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      height: 1.05,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
            const Text(
              'Феникс • тестовая наклейка • 120x75 мм',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF555555),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Термопринтер')),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Печать с десктоп-сайта',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Этот тест доступен только на десктоп-версии сайта. '
                      'Подключите термопринтер к компьютеру по USB или Bluetooth и выберите его в системном окне печати браузера.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Рекомендуется использовать Chrome или Edge на компьютере и заранее убедиться, что принтер уже виден в системе.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Пробная наклейка',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Телефон на наклейке',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Имя на наклейке',
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildPreviewCard(context),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _printing ? null : _printTestSticker,
                        icon: const Icon(Icons.print_rounded),
                        label: Text(
                          _printing
                              ? 'Открываем печать...'
                              : 'Печать тестовой наклейки',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _statusText,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
