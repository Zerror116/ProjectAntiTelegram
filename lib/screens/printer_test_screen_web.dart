// ignore_for_file: avoid_web_libraries_in_flutter

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/sticker_print_service.dart';
import '../widgets/sticker_preview_card.dart';

class PrinterTestScreen extends StatefulWidget {
  const PrinterTestScreen({super.key});

  @override
  State<PrinterTestScreen> createState() => _PrinterTestScreenState();
}

class _PrinterTestScreenState extends State<PrinterTestScreen> {
  final TextEditingController _regularPhoneController = TextEditingController(
    text: '89999999999',
  );
  final TextEditingController _regularNameController = TextEditingController(
    text: 'Имя',
  );
  final TextEditingController _oversizePhoneController = TextEditingController(
    text: '89999999999',
  );
  final TextEditingController _oversizeNameController = TextEditingController(
    text: 'Имя',
  );
  final TextEditingController _oversizeTitleController = TextEditingController(
    text: 'Комод белый',
  );
  final TextEditingController _oversizePriceController = TextEditingController(
    text: '3 500 ₽',
  );

  bool _printingRegular = false;
  bool _printingOversize = false;
  String _statusText =
      'Печать откроется в этой же вкладке. В системном диалоге браузера можно выбрать принтер, настройки и формат бумаги.';

  @override
  void dispose() {
    _regularPhoneController.dispose();
    _regularNameController.dispose();
    _oversizePhoneController.dispose();
    _oversizeNameController.dispose();
    _oversizeTitleController.dispose();
    _oversizePriceController.dispose();
    super.dispose();
  }

  StickerPrintJob _regularJob() {
    return StickerPrintJob(
      phone: _regularPhoneController.text.trim(),
      name: _regularNameController.text.trim(),
      showFooter: true,
      footerText: 'Феникс',
    );
  }

  StickerPrintJob _oversizeJob() {
    return StickerPrintJob(
      phone: _oversizePhoneController.text.trim(),
      name: _oversizeNameController.text.trim(),
      productTitle: _oversizeTitleController.text.trim(),
      priceLabel: _oversizePriceController.text.trim(),
      kindLabel: 'Габарит',
      showFooter: true,
      footerText: 'Феникс',
    );
  }

  Future<void> _printRegularSticker() async {
    final phone = _regularPhoneController.text.trim();
    final name = _regularNameController.text.trim();
    if (phone.isEmpty || name.isEmpty) {
      showAppNotice(
        context,
        'Для обычной наклейки заполните номер и имя',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _printingRegular = true;
      _statusText =
          'Открываем меню обычной печати в этой вкладке. Выберите принтер и нужные настройки.';
    });

    try {
      await printStickerJob(_regularJob());
      if (!mounted) return;
      setState(() {
        _statusText =
            'Обычная печать открыта. В системном диалоге выберите принтер и подтвердите печать.';
      });
      showAppNotice(
        context,
        'Меню обычной печати открыто',
        tone: AppNoticeTone.info,
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = 'Не удалось открыть печать: $e');
      showAppNotice(
        context,
        'Не удалось открыть печать: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _printingRegular = false);
      }
    }
  }

  Future<void> _printOversizeSticker() async {
    final phone = _oversizePhoneController.text.trim();
    final name = _oversizeNameController.text.trim();
    final title = _oversizeTitleController.text.trim();
    if (phone.isEmpty || name.isEmpty || title.isEmpty) {
      showAppNotice(
        context,
        'Для габаритной наклейки заполните номер, имя и что это за габарит',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _printingOversize = true;
      _statusText =
          'Открываем меню габаритной печати в этой вкладке. Выберите принтер и нужные настройки.';
    });

    try {
      await printStickerJob(_oversizeJob());
      if (!mounted) return;
      setState(() {
        _statusText =
            'Габаритная печать открыта. В системном диалоге выберите принтер и подтвердите печать.';
      });
      showAppNotice(
        context,
        'Меню габаритной печати открыто',
        tone: AppNoticeTone.info,
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = 'Не удалось открыть печать: $e');
      showAppNotice(
        context,
        'Не удалось открыть печать: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _printingOversize = false);
      }
    }
  }

  Widget _buildInfoCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Печать с десктоп-сайта',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Печать работает только на десктоп-версии сайта. Принтер должен быть уже подключён к компьютеру по USB или Bluetooth.',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
            const SizedBox(height: 10),
            Text(
              'Меню печати открывается прямо в этой вкладке. В стандартном системном диалоге браузера можно выбрать принтер, настройки качества, размер бумаги и остальные параметры.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegularPrintCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Тест обычной печати',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Печатает обычный клиентский стикер: номер и имя.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _regularPhoneController,
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Номер на наклейке'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _regularNameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Имя на наклейке'),
            ),
            const SizedBox(height: 16),
            StickerPreviewCard(job: _regularJob()),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _printingRegular ? null : _printRegularSticker,
                icon: const Icon(Icons.print_rounded),
                label: Text(
                  _printingRegular
                      ? 'Открываем печать...'
                      : 'Печать обычной наклейки',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOversizePrintCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Тест габаритной печати',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Печатает номер, имя, пометку Габарит, цену и то, что именно относится к габариту.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _oversizePhoneController,
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Номер на наклейке'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _oversizeNameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Имя на наклейке'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _oversizeTitleController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Что это за габарит',
                hintText: 'Например: Комод белый',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _oversizePriceController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Цена габарита',
                hintText: 'Например: 3 500 ₽',
              ),
            ),
            const SizedBox(height: 16),
            StickerPreviewCard(job: _oversizeJob()),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _printingOversize ? null : _printOversizeSticker,
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text(
                  _printingOversize
                      ? 'Открываем печать...'
                      : 'Печать габаритной наклейки',
                ),
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
            _buildInfoCard(context),
            const SizedBox(height: 12),
            _buildRegularPrintCard(context),
            const SizedBox(height: 12),
            _buildOversizePrintCard(context),
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
    );
  }
}
