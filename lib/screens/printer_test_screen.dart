import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_thermal_printer/flutter_thermal_printer.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';

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
  final FlutterThermalPrinter _printerPlugin = FlutterThermalPrinter.instance;

  StreamSubscription<List<Printer>>? _devicesSubscription;

  bool _scanBluetooth = true;
  bool _scanUsb = true;
  bool _loading = true;
  bool _scanning = false;
  bool _connecting = false;
  bool _printing = false;
  String _statusText = 'Подготавливаем поиск термопринтера...';
  String? _activePrinterId;
  List<Printer> _printers = const [];

  bool get _supported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get _supportsUsb {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  String _printerId(Printer printer) {
    return [
      printer.connectionType?.name ?? '',
      printer.vendorId ?? '',
      printer.productId ?? '',
      printer.address ?? '',
      printer.name ?? '',
    ].join('|');
  }

  @override
  void initState() {
    super.initState();
    if (_supported) {
      _printerPlugin.bleConfig = const BleConfig(
        connectionStabilizationDelay: Duration(seconds: 2),
      );
      _devicesSubscription = _printerPlugin.devicesStream.listen((items) {
        if (!mounted) return;
        final next = List<Printer>.from(items);
        next.sort((a, b) {
          final typeCmp = (a.connectionType?.name ?? '').compareTo(
            b.connectionType?.name ?? '',
          );
          if (typeCmp != 0) return typeCmp;
          return (a.name ?? '').toLowerCase().compareTo(
            (b.name ?? '').toLowerCase(),
          );
        });
        setState(() {
          _printers = next;
          _loading = false;
          _scanning = next.isNotEmpty;
          if (next.isEmpty) {
            _statusText =
                'Принтеров пока не найдено. Нажмите «Найти принтеры».';
          }
        });
      });
      unawaited(_refreshPrinters());
    }
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    unawaited(_printerPlugin.stopScan());
    _phoneController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  List<ConnectionType> _selectedConnectionTypes() {
    final types = <ConnectionType>[];
    if (_scanBluetooth) {
      types.add(ConnectionType.BLE);
    }
    if (_scanUsb && _supportsUsb) {
      types.add(ConnectionType.USB);
    }
    return types;
  }

  Future<void> _refreshPrinters() async {
    if (!_supported) return;
    final types = _selectedConnectionTypes();
    if (types.isEmpty) {
      setState(() {
        _statusText = 'Выберите хотя бы один способ подключения: Bluetooth или USB.';
        _printers = const [];
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _scanning = true;
      _statusText = _supportsUsb
          ? 'Ищем USB и Bluetooth-принтеры...'
          : 'Ищем Bluetooth-принтеры...';
    });

    try {
      await _printerPlugin.stopScan();
      await _printerPlugin.getPrinters(
        connectionTypes: types,
        refreshDuration: const Duration(seconds: 2),
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusText =
            'Выберите принтер из списка ниже и подключитесь для тестовой печати.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _scanning = false;
        _statusText = 'Не удалось получить список принтеров: $e';
      });
      showAppNotice(
        context,
        'Ошибка поиска принтеров: $e',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _stopScan() async {
    try {
      await _printerPlugin.stopScan();
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _statusText = 'Поиск остановлен. Можно снова запустить сканирование.';
      });
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось остановить поиск: $e',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _toggleConnection(Printer printer) async {
    if (_connecting) return;
    final id = _printerId(printer);
    setState(() {
      _connecting = true;
      _activePrinterId = id;
      _statusText = (printer.isConnected ?? false)
          ? 'Отключаем принтер ${printer.name ?? printer.address ?? ''}...'
          : 'Подключаем принтер ${printer.name ?? printer.address ?? ''}...';
    });

    try {
      if (printer.isConnected ?? false) {
        await _printerPlugin.disconnect(printer);
      } else {
        final connected = await _printerPlugin.connect(printer);
        if (!connected) {
          throw StateError('Принтер не подтвердил подключение');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _refreshPrinters();
      if (!mounted) return;
      showAppNotice(
        context,
        (printer.isConnected ?? false)
            ? 'Принтер отключён'
            : 'Принтер подключён',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Ошибка подключения: $e';
      });
      showAppNotice(
        context,
        'Ошибка подключения к принтеру: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _activePrinterId = null;
        });
      }
    }
  }

  Future<void> _printTestLabel(Printer printer) async {
    if (_printing) return;
    final phone = _phoneController.text.trim();
    final name = _nameController.text.trim();
    if (phone.isEmpty || name.isEmpty) {
      showAppNotice(
        context,
        'Заполните телефон и имя для тестовой наклейки',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _printing = true;
      _activePrinterId = _printerId(printer);
      _statusText = 'Печатаем тестовую наклейку...';
    });
    try {
      await _printerPlugin.printWidget(
        context,
        printer: printer,
        paperSize: PaperSize.mm80,
        cutAfterPrinted: true,
        widget: _buildStickerPreview(
          phone: phone,
          name: name,
          printer: printer,
        ),
      );
      if (!mounted) return;
      setState(() {
        _statusText =
            'Тестовая наклейка отправлена. Проверьте печать на принтере.';
      });
      showAppNotice(
        context,
        'Тестовая наклейка отправлена на принтер',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Ошибка печати: $e';
      });
      showAppNotice(
        context,
        'Ошибка печати: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _printing = false;
          _activePrinterId = null;
        });
      }
    }
  }

  Widget _buildStickerPreview({
    required String phone,
    required String name,
    required Printer printer,
  }) {
    final now = DateTime.now();
    final stamp =
        '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 720,
          child: AspectRatio(
            aspectRatio: 120 / 75,
            child: Material(
              color: Colors.white,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black, width: 3),
                ),
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ФЕНИКС',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.8,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      phone,
                      style: const TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.4,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Тестовая наклейка',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade800,
                            ),
                          ),
                        ),
                        Text(
                          printer.connectionTypeString,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stamp,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _platformHelpText() {
    if (kIsWeb) {
      return 'Веб-версия не умеет печатать на термопринтер напрямую.';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'Android: можно искать Bluetooth- и USB-принтеры. Для USB обычно нужен OTG-кабель и разрешение Android на доступ к USB-устройству.';
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return 'Windows: можно искать USB-принтеры и совместимые Bluetooth-устройства. Для USB убедитесь, что драйвер принтера установлен.';
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return 'macOS: можно искать USB- и Bluetooth-принтеры. Проверьте, что принтер виден в системе.';
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'iPhone/iPad: доступен только Bluetooth-поиск совместимых принтеров.';
    }
    return 'Подключите принтер и выполните тестовую печать.';
  }

  Widget _buildConnectionFilters() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilterChip(
          selected: _scanBluetooth,
          onSelected: (value) {
            setState(() => _scanBluetooth = value);
          },
          label: const Text('Bluetooth'),
          avatar: const Icon(Icons.bluetooth_rounded, size: 18),
        ),
        if (_supportsUsb)
          FilterChip(
            selected: _scanUsb,
            onSelected: (value) {
              setState(() => _scanUsb = value);
            },
            label: const Text('USB'),
            avatar: const Icon(Icons.usb_rounded, size: 18),
          ),
      ],
    );
  }

  Widget _buildPrinterTile(Printer printer) {
    final id = _printerId(printer);
    final busy = _activePrinterId == id && (_connecting || _printing);
    final connected = printer.isConnected ?? false;
    final connectionType = printer.connectionTypeString;
    final subtitleParts = <String>[
      if ((printer.address ?? '').trim().isNotEmpty) printer.address!.trim(),
      if ((printer.vendorId ?? '').trim().isNotEmpty)
        'VID: ${printer.vendorId!.trim()}',
      if ((printer.productId ?? '').trim().isNotEmpty)
        'PID: ${printer.productId!.trim()}',
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                child: Icon(
                  printer.connectionType == ConnectionType.USB
                      ? Icons.usb_rounded
                      : Icons.bluetooth_rounded,
                ),
              ),
              title: Text(
                (printer.name ?? '').trim().isEmpty
                    ? 'Безымянный принтер'
                    : printer.name!.trim(),
              ),
              subtitle: Text(
                [
                  connectionType,
                  ...subtitleParts,
                ].join(' • '),
              ),
              trailing: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : Icon(
                      connected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: connected
                          ? Colors.green
                          : Theme.of(context).colorScheme.outline,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : () => _toggleConnection(printer),
                      icon: Icon(
                        connected
                            ? Icons.link_off_rounded
                            : Icons.link_rounded,
                      ),
                      label: Text(connected ? 'Отключить' : 'Подключить'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy || !connected
                          ? null
                          : () => _printTestLabel(printer),
                      icon: const Icon(Icons.print_rounded),
                      label: const Text('Тест печати'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Термопринтер')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Сейчас тест термопринтера доступен только в приложении на поддерживаемых устройствах.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      );
    }

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
                      'Тест подключения и печати',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _platformHelpText(),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 14),
                    _buildConnectionFilters(),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _loading ? null : _refreshPrinters,
                            icon: const Icon(Icons.search_rounded),
                            label: Text(
                              _loading ? 'Ищем...' : 'Найти принтеры',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _scanning ? _stopScan : null,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('Остановить'),
                          ),
                        ),
                      ],
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
                      decoration: const InputDecoration(
                        labelText: 'Телефон на наклейке',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Имя на наклейке',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_printers.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'После поиска здесь появятся найденные Bluetooth- и USB-принтеры.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              )
            else
              ..._printers.map(_buildPrinterTile),
          ],
        ),
      ),
    );
  }
}
