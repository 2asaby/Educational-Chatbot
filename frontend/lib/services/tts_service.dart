import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/tutor_models.dart';
import 'gemini_service.dart';

typedef _CoTaskMemAllocNative = Pointer<Uint16> Function(IntPtr cb);
typedef _CoTaskMemAllocDart = Pointer<Uint16> Function(int cb);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Uint16> pv);
typedef _CoTaskMemFreeDart = void Function(Pointer<Uint16> pv);
typedef _MciSendStringWNative = Uint32 Function(
  Pointer<Uint16> lpszCommand,
  Pointer<Uint16> lpszReturnString,
  Uint32 cchReturn,
  IntPtr hwndCallback,
);
typedef _MciSendStringWDart = int Function(
  Pointer<Uint16> lpszCommand,
  Pointer<Uint16> lpszReturnString,
  int cchReturn,
  int hwndCallback,
);

class _WindowsWinmmPlayer {
  _CoTaskMemAllocDart? _alloc;
  _CoTaskMemFreeDart? _free;
  _MciSendStringWDart? _mci;
  bool _initialized = false;

  void _init() {
    if (_initialized) return;
    _initialized = true;
    final ole32 = DynamicLibrary.open('ole32.dll');
    _alloc = ole32.lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAllocDart>(
      'CoTaskMemAlloc',
    );
    _free = ole32.lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
      'CoTaskMemFree',
    );
    final winmm = DynamicLibrary.open('winmm.dll');
    _mci = winmm.lookupFunction<_MciSendStringWNative, _MciSendStringWDart>(
      'mciSendStringW',
    );
  }

  Pointer<Uint16> _toUtf16(String s) {
    final units = s.codeUnits;
    final ptr = _alloc!((units.length + 1) * 2);
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  (int, String) send(String command) {
    _init();
    final cmdPtr = _toUtf16(command);
    final retPtr = _alloc!(256 * 2);
    retPtr[0] = 0;
    final rc = _mci!(cmdPtr, retPtr, 256, 0);
    _free!(cmdPtr);

    final sb = StringBuffer();
    for (var i = 0; i < 256; i++) {
      final ch = retPtr[i];
      if (ch == 0) break;
      sb.writeCharCode(ch);
    }
    _free!(retPtr);
    return (rc, sb.toString());
  }

  void stopAndClose() {
    if (!Platform.isWindows) return;
    try {
      send('stop kids_tts');
      send('close kids_tts');
    } catch (_) {}
  }
}

class GeminiTtsService {
  static const MethodChannel _androidAudioChannel =
      MethodChannel('com.kidstutor/tts_audio');

  static const List<String> allGeminiTtsModels = [
    'gemini-3.1-flash-tts-preview',
    'gemini-2.5-flash-preview-tts',
    'gemini-3.8-flash-lite-tts',
    'gemini-3.8-flash-tts',
  ];

  static const Map<String, String> availableVoices = {
    'Puck': '🤖 معلم مرح (Puck - Gemini AI)',
    'Kore': '🤖 معلمة لطيفة (Kore - Gemini AI)',
    'Aoede': '🤖 معلمة قصصية (Aoede - Gemini AI)',
    'Charon': '🤖 معلم حكيم (Charon - Gemini AI)',
    'FastArabic': '⚡ صوت عربي فوري (< 1 ثانية)',
  };

  final _WindowsWinmmPlayer _winPlayer = _WindowsWinmmPlayer();
  final http.Client _httpClient = http.Client();
  int _playbackGeneration = 0;

  /// Tracks models that returned 429 so we skip them in 0ms for 10 minutes.
  final Map<String, DateTime> _rateLimitedUntil = {};

  Directory _getPersistentTtsDir() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    final dir = Directory(
      '$home${Platform.pathSeparator}.kids_ai_tutor${Platform.pathSeparator}tts_cache',
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Deterministic FNV-1a 64-bit hash so audio files persist across app restarts.
  String _deterministicFileHash(String voiceName, String text) {
    final bytes = utf8.encode('$voiceName::${text.trim()}');
    int hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return '${voiceName}_${hash.toRadixString(16)}';
  }

  Map<String, String> _buildAuthHeaders(UserSession session) {
    if (session.useOAuthTokenForGemini &&
        session.googleAccessToken != null &&
        session.googleAccessToken!.trim().isNotEmpty) {
      return {
        'Authorization': 'Bearer ${session.googleAccessToken!.trim()}',
      };
    }
    final key = session.apiKey.trim().isNotEmpty
        ? session.apiKey.trim()
        : GeminiService.defaultTestApiKey;
    return {
      'x-goog-api-key': key,
    };
  }

  /// Splits Arabic explanation into natural short sentences so Sentence 1
  /// synthesizes and starts playing quickly while Sentence 2+ load in parallel!
  List<String> splitIntoPlayableSentences(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 85) return [cleaned];

    final rawParts = cleaned
        .split(RegExp(r'(?<=[.!؟])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final chunks = <String>[];
    for (final part in rawParts) {
      if (part.length <= 100) {
        chunks.add(part);
      } else {
        final subParts = part
            .split(RegExp(r'(?<=،)\s+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);
        var buf = StringBuffer();
        for (final sub in subParts) {
          if (buf.length + sub.length + 1 > 90 && buf.isNotEmpty) {
            chunks.add(buf.toString().trim());
            buf = StringBuffer(sub);
          } else {
            if (buf.isNotEmpty) buf.write(' ');
            buf.write(sub);
          }
        }
        if (buf.isNotEmpty) {
          chunks.add(buf.toString().trim());
        }
      }
    }

    final merged = <String>[];
    for (final c in chunks) {
      if (merged.isNotEmpty && c.length < 25) {
        merged[merged.length - 1] = '${merged.last} $c';
      } else {
        merged.add(c);
      }
    }
    return merged.isEmpty ? [cleaned] : merged;
  }

  /// Ensures raw PCM bytes (24kHz, 16-bit, mono) have a valid 44-byte RIFF WAV header.
  Uint8List _ensureWavHeader(Uint8List audioBytes, {int sampleRate = 24000}) {
    if (audioBytes.length >= 4 &&
        audioBytes[0] == 0x52 &&
        audioBytes[1] == 0x49 &&
        audioBytes[2] == 0x46 &&
        audioBytes[3] == 0x46) {
      return audioBytes;
    }

    const int numChannels = 1;
    const int bitsPerSample = 16;
    final int byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    const int blockAlign = numChannels * (bitsPerSample ~/ 8);
    final int dataSize = audioBytes.length;
    final int chunkSize = 36 + dataSize;

    final header = ByteData(44);
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, chunkSize, Endian.little);
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);

    final wavBytes = Uint8List(44 + dataSize);
    wavBytes.setRange(0, 44, header.buffer.asUint8List());
    wavBytes.setRange(44, 44 + dataSize, audioBytes);
    return wavBytes;
  }

  List<String> _splitFastTextChunks(String text, {int maxLen = 175}) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= maxLen) return [cleaned];

    final chunks = <String>[];
    final words = cleaned.split(' ');
    var current = StringBuffer();

    for (final w in words) {
      if (current.length + w.length + 1 > maxLen && current.isNotEmpty) {
        chunks.add(current.toString().trim());
        current = StringBuffer(w);
      } else {
        if (current.isNotEmpty) current.write(' ');
        current.write(w);
      }
    }
    if (current.isNotEmpty) {
      chunks.add(current.toString().trim());
    }
    return chunks;
  }

  Future<String> _synthesizeFastArabicMp3(String cleanText) async {
    final ttsDir = _getPersistentTtsDir();
    final fileHash = _deterministicFileHash('FastArabic', cleanText);
    final cachedFile = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$fileHash.mp3',
    );
    if (cachedFile.existsSync() && cachedFile.lengthSync() > 100) {
      return cachedFile.path;
    }

    final chunks = _splitFastTextChunks(cleanText);
    final responses = await Future.wait(
      chunks.map((chunk) {
        final uri = Uri.https('translate.googleapis.com', '/translate_tts', {
          'ie': 'UTF-8',
          'client': 'gtx',
          'tl': 'ar',
          'q': chunk,
        });
        return _httpClient
            .get(uri, headers: const {'User-Agent': 'Mozilla/5.0'})
            .timeout(const Duration(seconds: 8));
      }),
    );

    final allBytes = BytesBuilder();
    for (final res in responses) {
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw Exception('Fast TTS error ${res.statusCode}');
      }
      allBytes.add(res.bodyBytes);
    }

    await cachedFile.writeAsBytes(allBytes.toBytes(), flush: true);
    return cachedFile.path;
  }

  /// Synthesizes a single text segment via Gemini TTS using SSE streaming
  /// (`streamGenerateContent?alt=sse`, ~2.6s total).
  Future<String> _synthesizeSingleGeminiSegment({
    required UserSession session,
    required String cleanText,
    required String voiceName,
  }) async {
    final ttsDir = _getPersistentTtsDir();
    final fileHash = _deterministicFileHash(voiceName, cleanText);
    final cachedWav = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$fileHash.wav',
    );
    if (cachedWav.existsSync() && cachedWav.lengthSync() > 44) {
      return cachedWav.path;
    }

    final payload = {
      'contents': [
        {
          'parts': [
            {'text': cleanText},
          ],
        },
      ],
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': voiceName},
          },
        },
      },
    };
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final now = DateTime.now();

    final orderedModels = [
      ...allGeminiTtsModels.where((m) {
        final until = _rateLimitedUntil[m];
        return until == null || now.isAfter(until);
      }),
      ...allGeminiTtsModels.where((m) {
        final until = _rateLimitedUntil[m];
        return until != null && now.isBefore(until);
      }),
    ];

    for (final model in orderedModels) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse',
      );
      try {
        final response = await _httpClient
            .post(
              uri,
              headers: {
                ..._buildAuthHeaders(session),
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: payloadBytes,
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          _rateLimitedUntil.remove(model);
          final responseText = utf8.decode(response.bodyBytes);
          final pcmBuilder = BytesBuilder();

          for (final line in const LineSplitter().convert(responseText)) {
            if (!line.startsWith('data:')) continue;
            final jsonPart = line.substring(5).trim();
            if (jsonPart.isEmpty) continue;
            final bodyMap = jsonDecode(jsonPart) as Map<String, dynamic>;
            final candidates =
                bodyMap['candidates'] as List<dynamic>? ?? const [];
            if (candidates.isEmpty) continue;
            final content = (candidates.first
                as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
            final parts = content?['parts'] as List<dynamic>? ?? const [];
            for (final p in parts) {
              if (p is Map<String, dynamic>) {
                final inlineData = p['inlineData'] as Map<String, dynamic>?;
                final b64Data = inlineData?['data']?.toString();
                if (b64Data != null && b64Data.isNotEmpty) {
                  pcmBuilder.add(base64Decode(b64Data));
                }
              }
            }
          }

          final collected = pcmBuilder.toBytes();
          if (collected.isNotEmpty) {
            final wavBytes = _ensureWavHeader(collected);
            await cachedWav.writeAsBytes(wavBytes, flush: true);
            return cachedWav.path;
          }
        }

        if (response.statusCode == 429) {
          _rateLimitedUntil[model] = DateTime.now().add(
            const Duration(minutes: 10),
          );
          continue;
        }
      } catch (_) {
        continue;
      }
    }

    throw Exception(
      'تعذر توليد صوت Gemini حالياً (تم تجاوز حد الطلبات المؤقت). جرب اختيار "صوت عربي فوري" أو أعد المحاولة بعد قليل.',
    );
  }

  /// Generates speech audio (.wav or .mp3) for a single text block using the selected voice.
  Future<String> synthesizeSpeechToFile({
    required UserSession session,
    required String text,
    String voiceName = 'Puck',
  }) async {
    final cleanText = text.trim();
    if (voiceName == 'FastArabic') {
      return _synthesizeFastArabicMp3(cleanText);
    }
    return _synthesizeSingleGeminiSegment(
      session: session,
      cleanText: cleanText,
      voiceName: voiceName,
    );
  }

  /// Pre-warms the first sentence of a reply silently in the background
  /// so clicking "استمع للشرح" starts playing immediately in 0.00s!
  Future<void> prewarmFirstSentence({
    required UserSession session,
    required String text,
    String voiceName = 'Puck',
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;
    final sentences = splitIntoPlayableSentences(cleanText);
    if (sentences.isEmpty) return;
    try {
      await synthesizeSpeechToFile(
        session: session,
        text: sentences.first,
        voiceName: voiceName,
      );
    } catch (_) {}
  }

  /// Plays text sentence-by-sentence in a pipeline (both FastArabic and Gemini AI)
  /// over a warm Keep-Alive HTTP client so Sentence 1 starts playing in ~240ms!
  Future<void> speakTextPipelined({
    required UserSession session,
    required String text,
    required String voiceName,
    VoidCallback? onPlaybackStarted,
  }) async {
    await stopPlayback();
    final gen = _playbackGeneration;
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;

    final ttsDir = _getPersistentTtsDir();
    final fullHash = _deterministicFileHash(voiceName, cleanText);
    final ext = voiceName == 'FastArabic' ? 'mp3' : 'wav';
    final minSize = voiceName == 'FastArabic' ? 100 : 44;
    final fullCached = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$fullHash.$ext',
    );
    if (fullCached.existsSync() && fullCached.lengthSync() > minSize) {
      if (gen != _playbackGeneration) return;
      onPlaybackStarted?.call();
      await _playAudioFileInternal(fullCached.path, generation: gen);
      return;
    }

    final sentences = splitIntoPlayableSentences(cleanText);
    Future<String>? nextFuture = synthesizeSpeechToFile(
      session: session,
      text: sentences.first,
      voiceName: voiceName,
    );

    bool notifiedStart = false;

    for (int i = 0; i < sentences.length; i++) {
      if (gen != _playbackGeneration) return;
      final audioPath = await nextFuture!;
      if (gen != _playbackGeneration) return;

      // Start synthesizing sentence i+1 in parallel BEFORE playing sentence i!
      if (i + 1 < sentences.length) {
        nextFuture = synthesizeSpeechToFile(
          session: session,
          text: sentences[i + 1],
          voiceName: voiceName,
        );
      } else {
        nextFuture = null;
      }

      if (!notifiedStart) {
        notifiedStart = true;
        onPlaybackStarted?.call();
      }
      await _playAudioFileInternal(audioPath, generation: gen);
    }
  }

  Future<void> playAudioFile(String audioPath) async {
    await stopPlayback();
    await _playAudioFileInternal(audioPath, generation: _playbackGeneration);
  }

  Future<void> _playAudioFileInternal(
    String audioPath, {
    required int generation,
  }) async {
    if (generation != _playbackGeneration) return;

    if (Platform.isWindows) {
      _winPlayer.stopAndClose();
      final (openRc, _) = _winPlayer.send('open "$audioPath" alias kids_tts');
      if (openRc != 0) {
        throw Exception('تعذر فتح ملف الصوت (MCI $openRc)');
      }
      final (playRc, _) = _winPlayer.send('play kids_tts');
      if (playRc != 0) {
        _winPlayer.stopAndClose();
        throw Exception('تعذر تشغيل ملف الصوت (MCI $playRc)');
      }

      // Poll status asynchronously on the UI thread (non-blocking, <1% CPU, 0ms stop)
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (generation == _playbackGeneration &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        if (generation != _playbackGeneration) break;
        final (rc, mode) = _winPlayer.send('status kids_tts mode');
        if (rc != 0 || mode != 'playing') {
          break;
        }
      }
      if (generation == _playbackGeneration) {
        _winPlayer.stopAndClose();
      }
    } else if (Platform.isAndroid) {
      await _androidAudioChannel.invokeMethod('playWav', {'path': audioPath});
    }
  }

  /// Immediately stops any ongoing speech playback.
  Future<void> stopPlayback() async {
    _playbackGeneration++;
    if (Platform.isWindows) {
      _winPlayer.stopAndClose();
    }
    if (Platform.isAndroid) {
      try {
        await _androidAudioChannel.invokeMethod('stop');
      } catch (_) {}
    }
  }
}
