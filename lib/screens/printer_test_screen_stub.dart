import 'package:flutter/material.dart';

class PrinterTestScreen extends StatelessWidget {
  const PrinterTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Термопринтер')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Тест термопринтера доступен только на десктоп-версии сайта.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}
