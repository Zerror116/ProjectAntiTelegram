import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

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

  bool _statusLoading = true;
  bool _pairedLoading = false;
  bool _connecting = false;
  bool _printing = false;
  bool _permissionGranted = false;
  bool _bluetoothEnabled = false;
  bool _connected = false;
  String _statusText = 'Проверяем Bluetooth...';
  String? _connectedMac;
  List<BluetoothInfo> _pairedPrinters = const [];

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_supported) {
      _refreshStatus();
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    if (!_supported) return;
    if (mounted) {
      setState(() => _statusLoading = true);
    }
    try {
      final permissionGranted =
          await PrintBluetoothThermal.isPermissionBluetoothGranted;
      final bluetoothEnabled = await PrintBluetoothThermal.bluetoothEnabled;
      final connected = await PrintBluetoothThermal.connectionStatus;
      if (!mounted) return;
      setState(() {
        _permissionGranted = permissionGranted;
        _bluetoothEnabled = bluetoothEnabled;
        _connected = connected;
        _statusText = !permissionGranted
            ? 'Android пока не дал доступ к Bluetooth. Разрешите Bluetooth/Nearby devices для Феникс в системных настройках и вернитесь сюда.'
            : !bluetoothEnabled
            ? 'Bluetooth на телефоне выключен. Включите его перед поиском принтера.'
            : connected
            ? 'Принтер подключён${_connectedMac == null ? '' : ' ($_connectedMac)'}.'
            : 'Bluetooth включён. Теперь можно искать сопряжённые принтеры.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Не удалось проверить Bluetooth: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _statusLoading = false);
      }
    }
  }

  Future<void> _loadPairedPrinters() async {
    if (!_supported || _pairedLoading) return;
    setState(() => _pairedLoading = true);
    try {
      final items = await PrintBluetoothThermal.pairedBluetooths;
      if (!mounted) return;
      setState(() {
        _pairedPrinters = items;
        if (items.isEmpty) {
          _statusText = 'Сопряжённых принтеров не найдено. Сначала свяжите принтер с телефоном в настройках Bluetooth.';
        } else {
          _statusText = 'Нажмите на принтер ниже, чтобы подключиться и распечатать тест.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Не удалось получить список принтеров: $e';
      });
      showAppNotice(
        context,
        'Ошибка поиска принтера: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _pairedLoading = false);
      }
    }
  }

  Future<void> _connectPrinter(BluetoothInfo printer) async {
    if (_connecting) return;
    final mac = printer.macAdress.trim();
    if (mac.isEmpty) {
      showAppNotice(
        context,
        'У этого принтера нет MAC-адреса для подключения',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() {
      _connecting = true;
      _statusText = 'Подключаемся к ${printer.name}...';
    });
    try {
      final connected = await PrintBluetoothThermal.connect(
        macPrinterAddress: mac,
      );
      if (!mounted) return;
      setState(() {
        _connected = connected;
        _connectedMac = connected ? mac : null;
        _statusText = connected
            ? 'Подключено к ${printer.name}. Можно печатать тестовую наклейку.'
            : 'Подключение к ${printer.name} не удалось.';
      });
      showAppNotice(
        context,
        connected
            ? 'Принтер подключён'
            : 'Не удалось подключиться к принтеру',
        tone: connected ? AppNoticeTone.success : AppNoticeTone.error,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Ошибка подключения: $e';
      });
      showAppNotice(
        context,
        'Ошибка подключения: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  Future<void> _disconnectPrinter() async {
    try {
      await PrintBluetoothThermal.disconnect;
      if (!mounted) return;
      setState(() {
        _connected = false;
        _connectedMac = null;
        _statusText = 'Принтер отключён.';
      });
      showAppNotice(
        context,
        'Принтер отключён',
        tone: AppNoticeTone.info,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Не удалось отключить принтер: $e',
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _printTestSticker() async {
    if (_printing) return;
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

    final connected = await PrintBluetoothThermal.connectionStatus;
    if (!connected) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _statusText = 'Сначала подключите Bluetooth-принтер.';
      });
      showAppNotice(
        context,
        'Сначала подключите принтер',
        tone: AppNoticeTone.warning,
      );
      return;
    }

    setState(() => _printing = true);
    try {
      final now = DateTime.now();
      final stamp =
          '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      await PrintBluetoothThermal.writeBytes('\n'.codeUnits);
      await PrintBluetoothThermal.writeString(
        printText: PrintTextSize(size: 1, text: 'ФЕНИКС\n'),
      );
      await PrintBluetoothThermal.writeString(
        printText: PrintTextSize(size: 4, text: '$phone\n'),
      );
      await PrintBluetoothThermal.writeString(
        printText: PrintTextSize(size: 3, text: '$name\n'),
      );
      await PrintBluetoothThermal.writeString(
        printText: PrintTextSize(
          size: 1,
          text: 'Тестовая наклейка 120x75\n$stamp\n\n',
        ),
      );
      await PrintBluetoothThermal.writeBytes('\n\n'.codeUnits);
      if (!mounted) return;
      showAppNotice(
        context,
        'Тестовая наклейка отправлена на принтер',
        tone: AppNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotice(
        context,
        'Ошибка печати: $e',
        tone: AppNoticeTone.error,
      );
    } finally {
      if (mounted) {
        setState(() => _printing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_supported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Термопринтер')),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Сейчас тест Bluetooth-термопринтера доступен только в Android-приложении.',
                textAlign: TextAlign.center,
              ),
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
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Тестовая наклейка',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Это первый этап: подключение к ESC/POS Bluetooth-принтеру и пробная печать наклейки в духе образца. Точную финальную вёрстку под реальные стикеры можно будет отдельно довести после теста на железе.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_statusLoading)
                    const LinearProgressIndicator()
                  else
                    Text(_statusText),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _statusLoading ? null : _refreshStatus,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Обновить статус'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            _pairedLoading ||
                                !_permissionGranted ||
                                !_bluetoothEnabled
                            ? null
                            : _loadPairedPrinters,
                        icon: _pairedLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.bluetooth_searching_rounded),
                        label: const Text('Сопряжённые принтеры'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _connected ? _disconnectPrinter : null,
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('Отключить'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(
                labelText: 'Телефон для тестовой наклейки',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Имя/подпись на наклейке',
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed:
                  _printing || !_permissionGranted || !_bluetoothEnabled
                  ? null
                  : _printTestSticker,
              icon: _printing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_rounded),
              label: Text(
                _printing ? 'Печатаем...' : 'Печать пробной наклейки',
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Сопряжённые принтеры',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            if (_pairedPrinters.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  'Пока список пуст. Включите Bluetooth, свяжите принтер с телефоном в системных настройках и нажмите «Сопряжённые принтеры».',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ..._pairedPrinters.map(
                (printer) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      leading: const Icon(Icons.print_rounded),
                      title: Text(
                        printer.name.trim().isEmpty
                            ? 'Без названия'
                            : printer.name,
                      ),
                      subtitle: Text(printer.macAdress),
                      trailing: _connecting && _connectedMac == printer.macAdress
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _connected && _connectedMac == printer.macAdress
                                  ? Icons.check_circle_rounded
                                  : Icons.chevron_right_rounded,
                            ),
                      onTap: _connecting ? null : () => _connectPrinter(printer),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
