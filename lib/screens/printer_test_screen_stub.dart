import 'package:flutter/material.dart';

import '../widgets/phoenix_micro_interactions.dart';

class PrinterTestScreen extends StatelessWidget {
  const PrinterTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Термопринтер')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhoenixProgressRingIcon(
                icon: Icons.print_disabled_outlined,
                progress: 1,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                'Тест термопринтера доступен только на десктоп-версии сайта.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
