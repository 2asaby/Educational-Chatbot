import 'dart:io';
import 'package:flutter/services.dart';

/// Shared persistent app-data directory helper across Windows, macOS, Linux,
/// and Android (`Context.filesDir` via platform channel).
class AppStorage {
  static const MethodChannel _channel = MethodChannel('com.kidstutor/tts_audio');
  static String? androidAppDataDir;

  /// Initializes the platform persistent directory before `runApp`.
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      final path = await _channel.invokeMethod<String>('getAppDataDir');
      if (path != null && path.trim().isNotEmpty) {
        androidAppDataDir = path.trim();
      }
    } catch (_) {
      // Fallback to environment / system temp in headless tests.
    }
  }

  /// Returns the persistent `.kids_ai_tutor` directory (or an optional child
  /// folder) and ensures it exists on disk.
  static Directory getRootDir({Directory? overrideDir, String? subDir}) {
    final Directory baseDir;
    if (overrideDir != null) {
      baseDir = overrideDir;
    } else {
      final baseHome =
          (androidAppDataDir != null && androidAppDataDir!.trim().isNotEmpty)
              ? androidAppDataDir!.trim()
              : (Platform.environment['USERPROFILE'] ??
                    Platform.environment['HOME'] ??
                    Directory.systemTemp.path);
      baseDir = Directory('$baseHome${Platform.pathSeparator}.kids_ai_tutor');
    }
    final targetDir = (subDir == null || subDir.isEmpty)
        ? baseDir
        : Directory('${baseDir.path}${Platform.pathSeparator}$subDir');
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }
    return targetDir;
  }
}
