import 'package:flutter/widgets.dart';

bool isSupported() => false;

Future<void> start() async {
  throw UnsupportedError('Web video note capture is not available');
}

Future<Map<String, dynamic>> stop() async {
  throw UnsupportedError('Web video note capture is not available');
}

Future<void> cancel() async {}

Widget previewWidget({Key? key}) => SizedBox(key: key);
