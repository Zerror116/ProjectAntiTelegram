// test_http.dart
import 'dart:io';
import 'dart:convert';

void main() async {
  stdout.writeln('=== Socket test to 127.0.0.1:3000 ===');
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      3000,
      timeout: Duration(seconds: 3),
    );
    stdout.writeln(
      'Socket connected to ${socket.remoteAddress.address}:${socket.remotePort}',
    );
    socket.destroy();
  } catch (e) {
    stdout.writeln('Socket connect failed: $e');
  }

  stdout.writeln('\n=== HTTP GET http://127.0.0.1:3000/ ===');
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:3000/'));
    final resp = await req.close();
    stdout.writeln('HTTP status: ${resp.statusCode}');
    final body = await resp.transform(utf8.decoder).join();
    stdout.writeln('Body: $body');
  } catch (e) {
    stdout.writeln('HTTP request failed: $e');
  }
}
