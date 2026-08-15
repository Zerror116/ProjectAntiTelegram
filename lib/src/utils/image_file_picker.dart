import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

Future<PlatformFile?> pickSingleImageFile() async {
  // FilePicker.pickFile() forces withData=false. On Safari that can leave the
  // app with an unreadable blob after the picker closes, so keep bytes on web.
  // ignore: deprecated_member_use
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    // ignore: deprecated_member_use
    allowMultiple: false,
    // ignore: deprecated_member_use
    withData: kIsWeb,
  );
  final files = result?.files ?? const <PlatformFile>[];
  return files.isEmpty ? null : files.first;
}

Future<List<PlatformFile>> pickImageFiles() async {
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    // ignore: deprecated_member_use
    allowMultiple: true,
    // ignore: deprecated_member_use
    withData: kIsWeb,
  );
  return result?.files ?? const <PlatformFile>[];
}
