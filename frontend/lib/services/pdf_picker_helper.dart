import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class PickedPdfFile {
  final String filename;
  final String fullPath;
  final Uint8List bytes;

  const PickedPdfFile({
    required this.filename,
    required this.fullPath,
    required this.bytes,
  });
}

class PdfPickerHelper {
  static const MethodChannel _platformChannel =
      MethodChannel('com.kidstutor/tts_audio');

  /// Opens the native Windows File Open Dialog for PDFs on Windows Desktop.
  /// Uses Base64-encoded UTF-8 output so Arabic filenames and folders never get corrupted by Windows codepages.
  static Future<PickedPdfFile?> pickPdfOnWindows() async {
    if (!Platform.isWindows) return null;

    const psScript = r'''
Add-Type -AssemblyName System.Windows.Forms
$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = "Select PDF File"
$dlg.Filter = "PDF Files (*.pdf)|*.pdf"
$dlg.Multiselect = $false
if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($dlg.FileName)
    Write-Output ([Convert]::ToBase64String($bytes))
}
''';

    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-Sta', '-Command', psScript],
    );

    final b64 = result.stdout.toString().trim();
    if (b64.isEmpty) {
      return null;
    }

    final selectedPath = utf8.decode(base64Decode(b64)).trim();
    if (selectedPath.isEmpty) {
      return null;
    }
    return loadPdfFromPath(selectedPath);
  }

  /// Opens Android's native Storage Access Framework file picker (`ACTION_OPEN_DOCUMENT`)
  /// so users can select any PDF directly from phone storage, Downloads, or Google Drive.
  static Future<PickedPdfFile?> pickPdfOnAndroid() async {
    if (!Platform.isAndroid) return null;
    final res = await _platformChannel.invokeMapMethod<String, dynamic>('pickPdf');
    if (res == null) return null;

    final tempPath = (res['path'] ?? '').toString();
    final displayName = (res['name'] ?? 'lesson.pdf').toString();
    if (tempPath.isEmpty) return null;

    final file = File(tempPath);
    if (!await file.exists()) {
      throw Exception('تعذر قراءة ملف PDF المختار من الهاتف.');
    }
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {}

    return PickedPdfFile(
      filename: displayName,
      fullPath: tempPath,
      bytes: bytes,
    );
  }

  static Future<PickedPdfFile> loadPdfFromPath(String rawPath) async {
    final cleanPath = rawPath.trim().replaceAll('"', '');
    if (!cleanPath.toLowerCase().endsWith('.pdf')) {
      throw Exception('يرجى اختيار ملف بصيغة PDF فقط.');
    }
    final file = File(cleanPath);
    if (!await file.exists()) {
      throw Exception('الملف غير موجود في المسار المحدد: $cleanPath');
    }
    final bytes = await file.readAsBytes();
    final filename = cleanPath.split(RegExp(r'[\\/]')).last;
    return PickedPdfFile(
      filename: filename,
      fullPath: cleanPath,
      bytes: bytes,
    );
  }
}
