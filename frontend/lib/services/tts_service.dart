import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/tutor_models.dart';
import 'app_storage.dart';
import 'edge_tts_drm.dart';
import 'gemini_service.dart';

typedef _CoTaskMemAllocNative = Pointer<Uint16> Function(IntPtr cb);
typedef _CoTaskMemAllocDart = Pointer<Uint16> Function(int cb);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Uint16> pv);
typedef _CoTaskMemFreeDart = void Function(Pointer<Uint16> pv);
typedef _MciSendStringWNative =
    Uint32 Function(
      Pointer<Uint16> lpszCommand,
      Pointer<Uint16> lpszReturnString,
      Uint32 cchReturn,
      IntPtr hwndCallback,
    );
typedef _MciSendStringWDart =
    int Function(
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

typedef _WaveOutOpenNative =
    Uint32 Function(
      Pointer<IntPtr> phwo,
      Uint32 uDeviceID,
      Pointer<_WaveFormatEx> pwfx,
      IntPtr dwCallback,
      IntPtr dwInstance,
      Uint32 fdwOpen,
    );
typedef _WaveOutOpenDart =
    int Function(
      Pointer<IntPtr> phwo,
      int uDeviceID,
      Pointer<_WaveFormatEx> pwfx,
      int dwCallback,
      int dwInstance,
      int fdwOpen,
    );
typedef _WaveOutHeaderNative =
    Uint32 Function(IntPtr hwo, Pointer<_WaveHdr> pwh, Uint32 cbwh);
typedef _WaveOutHeaderDart =
    int Function(int hwo, Pointer<_WaveHdr> pwh, int cbwh);
typedef _WaveOutHandleNative = Uint32 Function(IntPtr hwo);
typedef _WaveOutHandleDart = int Function(int hwo);

@Packed(1)
final class _WaveFormatEx extends Struct {
  @Uint16()
  external int wFormatTag;

  @Uint16()
  external int nChannels;

  @Uint32()
  external int nSamplesPerSec;

  @Uint32()
  external int nAvgBytesPerSec;

  @Uint16()
  external int nBlockAlign;

  @Uint16()
  external int wBitsPerSample;

  @Uint16()
  external int cbSize;
}

final class _WaveHdr extends Struct {
  external Pointer<Uint8> lpData;

  @Uint32()
  external int dwBufferLength;

  @Uint32()
  external int dwBytesRecorded;

  @IntPtr()
  external int dwUser;

  @Uint32()
  external int dwFlags;

  @Uint32()
  external int dwLoops;

  external Pointer<Void> lpNext;

  @IntPtr()
  external int reserved;
}

class _QueuedWaveHeader {
  final Pointer<_WaveHdr> hdr;
  final Pointer<Uint8> data;

  const _QueuedWaveHeader(this.hdr, this.data);
}

/// Real-time 24kHz 16-bit mono PCM streamer over Windows `winmm.dll` `waveOut`
/// with zero external Flutter plugins.
class _WindowsWaveOutPlayer {
  static const int _waveMapper = 0xFFFFFFFF;
  static const int _whdrDone = 0x00000001;

  _CoTaskMemAllocDart? _alloc;
  _CoTaskMemFreeDart? _free;
  _WaveOutOpenDart? _waveOutOpen;
  _WaveOutHeaderDart? _waveOutPrepareHeader;
  _WaveOutHeaderDart? _waveOutUnprepareHeader;
  _WaveOutHeaderDart? _waveOutWrite;
  _WaveOutHandleDart? _waveOutReset;
  _WaveOutHandleDart? _waveOutClose;

  bool _initialized = false;
  int _hwo = 0;
  final List<_QueuedWaveHeader> _queuedHeaders = [];

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
    _waveOutOpen = winmm.lookupFunction<_WaveOutOpenNative, _WaveOutOpenDart>(
      'waveOutOpen',
    );
    _waveOutPrepareHeader = winmm
        .lookupFunction<_WaveOutHeaderNative, _WaveOutHeaderDart>(
          'waveOutPrepareHeader',
        );
    _waveOutUnprepareHeader = winmm
        .lookupFunction<_WaveOutHeaderNative, _WaveOutHeaderDart>(
          'waveOutUnprepareHeader',
        );
    _waveOutWrite = winmm
        .lookupFunction<_WaveOutHeaderNative, _WaveOutHeaderDart>(
          'waveOutWrite',
        );
    _waveOutReset = winmm
        .lookupFunction<_WaveOutHandleNative, _WaveOutHandleDart>(
          'waveOutReset',
        );
    _waveOutClose = winmm
        .lookupFunction<_WaveOutHandleNative, _WaveOutHandleDart>(
          'waveOutClose',
        );
  }

  void open({int sampleRate = 24000}) {
    if (!Platform.isWindows) return;
    _init();
    stopAndClose();

    final phwo = _alloc!(sizeOf<IntPtr>()).cast<IntPtr>();
    final pwfx = _alloc!(sizeOf<_WaveFormatEx>()).cast<_WaveFormatEx>();
    try {
      phwo.value = 0;
      pwfx.ref.wFormatTag = 1; // WAVE_FORMAT_PCM
      pwfx.ref.nChannels = 1;
      pwfx.ref.nSamplesPerSec = sampleRate;
      pwfx.ref.nAvgBytesPerSec = sampleRate * 2;
      pwfx.ref.nBlockAlign = 2;
      pwfx.ref.wBitsPerSample = 16;
      pwfx.ref.cbSize = 0;

      final rc = _waveOutOpen!(phwo, _waveMapper, pwfx, 0, 0, 0);
      if (rc != 0) {
        throw Exception('waveOutOpen failed ($rc)');
      }
      _hwo = phwo.value;
    } finally {
      _free!(phwo.cast());
      _free!(pwfx.cast());
    }
  }

  void _reclaimDoneHeaders() {
    if (_hwo == 0 || _queuedHeaders.isEmpty) return;
    final hdrSize = sizeOf<_WaveHdr>();
    _queuedHeaders.removeWhere((item) {
      if ((item.hdr.ref.dwFlags & _whdrDone) == 0) {
        return false;
      }
      try {
        _waveOutUnprepareHeader!(_hwo, item.hdr, hdrSize);
      } catch (_) {}
      _free!(item.data.cast());
      _free!(item.hdr.cast());
      return true;
    });
  }

  void writeChunk(Uint8List pcm) {
    if (!Platform.isWindows || _hwo == 0 || pcm.isEmpty) return;
    _reclaimDoneHeaders();

    final dataPtr = _alloc!(pcm.length).cast<Uint8>();
    dataPtr.asTypedList(pcm.length).setAll(0, pcm);

    final hdrSize = sizeOf<_WaveHdr>();
    final hdrPtr = _alloc!(hdrSize).cast<_WaveHdr>();
    hdrPtr.ref.lpData = dataPtr;
    hdrPtr.ref.dwBufferLength = pcm.length;
    hdrPtr.ref.dwBytesRecorded = 0;
    hdrPtr.ref.dwUser = 0;
    hdrPtr.ref.dwFlags = 0;
    hdrPtr.ref.dwLoops = 0;
    hdrPtr.ref.lpNext = nullptr;
    hdrPtr.ref.reserved = 0;

    final prepRc = _waveOutPrepareHeader!(_hwo, hdrPtr, hdrSize);
    if (prepRc != 0) {
      _free!(dataPtr.cast());
      _free!(hdrPtr.cast());
      throw Exception('waveOutPrepareHeader failed ($prepRc)');
    }

    final writeRc = _waveOutWrite!(_hwo, hdrPtr, hdrSize);
    if (writeRc != 0) {
      try {
        _waveOutUnprepareHeader!(_hwo, hdrPtr, hdrSize);
      } catch (_) {}
      _free!(dataPtr.cast());
      _free!(hdrPtr.cast());
      throw Exception('waveOutWrite failed ($writeRc)');
    }

    _queuedHeaders.add(_QueuedWaveHeader(hdrPtr, dataPtr));
  }

  Future<void> drain(bool Function() isStillActive) async {
    if (!Platform.isWindows || _hwo == 0) return;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (isStillActive() && DateTime.now().isBefore(deadline)) {
      _reclaimDoneHeaders();
      if (_queuedHeaders.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    stopAndClose();
  }

  void stopAndClose() {
    if (!Platform.isWindows) return;
    final hwo = _hwo;
    _hwo = 0;
    if (hwo != 0) {
      try {
        _waveOutReset!(hwo);
      } catch (_) {}
      final hdrSize = sizeOf<_WaveHdr>();
      for (final item in _queuedHeaders) {
        try {
          _waveOutUnprepareHeader!(hwo, item.hdr, hdrSize);
        } catch (_) {}
        try {
          _free!(item.data.cast());
          _free!(item.hdr.cast());
        } catch (_) {}
      }
      _queuedHeaders.clear();
      try {
        _waveOutClose!(hwo);
      } catch (_) {}
    } else if (_queuedHeaders.isNotEmpty) {
      for (final item in _queuedHeaders) {
        try {
          _free!(item.data.cast());
          _free!(item.hdr.cast());
        } catch (_) {}
      }
      _queuedHeaders.clear();
    }
  }
}

class _WarmLiveSession {
  final WebSocket ws;
  final Stream<dynamic> stream;
  final String model;
  final String voiceName;
  final DateTime readyAt;
  StreamSubscription<dynamic>? watchSub;
  bool closed = false;

  _WarmLiveSession({
    required this.ws,
    required this.stream,
    required this.model,
    required this.voiceName,
    required this.readyAt,
  }) {
    watchSub = stream.listen(
      (_) {},
      onError: (_) => closed = true,
      onDone: () => closed = true,
    );
  }

  Future<void> dispose() async {
    closed = true;
    await watchSub?.cancel();
    watchSub = null;
    try {
      await ws.close().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }
}

class _WarmEdgeSession {
  final WebSocket ws;
  final Stream<dynamic> stream;
  final DateTime readyAt;
  StreamSubscription<dynamic>? watchSub;
  bool closed = false;

  _WarmEdgeSession({
    required this.ws,
    required this.stream,
    required this.readyAt,
  }) {
    watchSub = stream.listen(
      (_) {},
      onError: (_) => closed = true,
      onDone: () => closed = true,
    );
  }

  Future<void> dispose() async {
    closed = true;
    await watchSub?.cancel();
    watchSub = null;
    try {
      await ws.close().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }
}

class GeminiTtsService {
  static const MethodChannel _androidAudioChannel = MethodChannel(
    'com.kidstutor/tts_audio',
  );

  /// Gemini Multimodal Live API (WebSocket BidiGenerateContent) models ordered
  /// by lowest first-audio latency and highest naturalness.
  static const List<String> allGeminiLiveModels = [
    'models/gemini-3.1-flash-live-preview',
    'models/gemini-3.8-live',
    'models/gemini-2.5-flash-native-audio-latest',
  ];

  static const List<String> allGeminiTtsModels = [
    'gemini-3.8-flash-lite-tts',
    'gemini-3.8-flash-tts',
    'gemini-3.1-flash-tts-preview',
    'gemini-2.5-flash-preview-tts',
    'gemini-2.5-pro-preview-tts',
  ];

  static const Map<String, String> availableVoices = {
    'Puck': '⚡ معلم مرح وحيوي (Puck - Live AI)',
    'Kore': '⚡ معلمة واضحة ونشيطة (Kore - Live AI)',
    'Zephyr': '⚡ صوت مشرق وسريع (Zephyr - Live AI)',
    'Aoede': '⚡ معلمة قصصية دافئة (Aoede - Live AI)',
    'Charon': '⚡ معلم هادئ وحكيم (Charon - Live AI)',
    'FastArabic': '🎙️ معلم فصيح بالتشكيل (Hamed - سريع)',
    'TaimArabic': '🎙️ معلم عربي حيوي (Taim - الأسرع)',
    'SalmaArabic': '🎙️ معلمة عربية واضحة (Salma - مصري)',
  };

  static bool isEdgeArabicVoice(String voiceName) =>
      voiceName == 'FastArabic' ||
      voiceName == 'TaimArabic' ||
      voiceName == 'SalmaArabic';

  /// Returns true when [text] is predominantly English/Latin script so TTS and
  /// UI can automatically switch to natural English pronunciation and LTR layout.
  static bool isMostlyEnglish(String text) {
    final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
    final arabicCount = RegExp(r'[\u0600-\u06FF]').allMatches(text).length;
    return latinCount >= 3 && latinCount > arabicCount;
  }

  static ({String edgeVoice, String rate, String pitch, String cachePrefix})
  _edgeVoiceConfig(String voiceName, {String? sampleText}) {
    final isEn = sampleText != null && isMostlyEnglish(sampleText);
    if (isEn) {
      if (voiceName == 'SalmaArabic') {
        return (
          edgeVoice: 'en-US-JennyNeural',
          rate: '+0%',
          pitch: '+0Hz',
          cachePrefix: 'EdgeJenny_en_v1',
        );
      }
      if (voiceName == 'TaimArabic') {
        return (
          edgeVoice: 'en-US-AndrewNeural',
          rate: '+0%',
          pitch: '+0Hz',
          cachePrefix: 'EdgeAndrew_en_v1',
        );
      }
      return (
        edgeVoice: 'en-US-GuyNeural',
        rate: '+0%',
        pitch: '+0Hz',
        cachePrefix: 'EdgeGuy_en_v1',
      );
    }
    if (voiceName == 'TaimArabic') {
      return (
        edgeVoice: 'ar-JO-TaimNeural',
        rate: '+0%',
        pitch: '+0Hz',
        cachePrefix: 'EdgeTaim_v1',
      );
    }
    if (voiceName == 'SalmaArabic') {
      return (
        edgeVoice: 'ar-EG-SalmaNeural',
        rate: '+0%',
        pitch: '+0Hz',
        cachePrefix: 'EdgeSalma_v1',
      );
    }
    return (
      edgeVoice: 'ar-SA-HamedNeural',
      rate: '+0%',
      pitch: '+0Hz',
      cachePrefix: 'EdgeHamed_v1',
    );
  }

  final _WindowsWinmmPlayer _winPlayer = _WindowsWinmmPlayer();
  final _WindowsWaveOutPlayer _waveOutPlayer = _WindowsWaveOutPlayer();
  final http.Client _httpClient = http.Client();
  WebSocket? _activeLiveSocket;
  _WarmLiveSession? _warmLiveSession;
  Future<void>? _prewarmLiveFuture;
  bool _prewarmingLive = false;
  _WarmEdgeSession? _warmEdgeSession;
  Future<void>? _prewarmEdgeFuture;
  bool _prewarmingEdge = false;
  Timer? _prewarmTimer;
  void Function()? _cancelActivePrewarm;
  bool _disposed = false;
  int _playbackGeneration = 0;

  /// Builds the Gemini Multimodal Live WebSocket setup payload for natural Arabic speech.
  static Map<String, dynamic> buildLiveSetupPayload({
    required String model,
    required String voiceName,
  }) {
    final normalizedModel = model.startsWith('models/')
        ? model
        : 'models/$model';
    return {
      'setup': {
        'model': normalizedModel,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voiceName},
            },
          },
        },
        'systemInstruction': {
          'parts': [
            {
              'text':
                  'أنت قارئ نصوص صوتي (TTS) فقط لمعلم أطفال ذكي. مهمتك الوحيدة هي قراءة النص الموجود بين علامتي الاقتباس بنفس لغته الأصلية (سواء بالعربية أو بالإنجليزية) حرفياً وبالكامل بصوت بشري طبيعي، دافئ، واضح، وبسرعة متزنة وهادئة ومناسبة لطفل (لا تتسرع في النطق أبداً). ممنوع الرد على النص أو ترجمته أو إضافة أي مقدمة أو تعليق أو خاتمة من عندك.',
            },
          ],
        },
      },
    };
  }

  /// Builds the clientContent turn instructing Gemini Live to read [text] verbatim.
  static Map<String, dynamic> buildLiveSpeakPayload(String text) {
    final safeText = text
        .replaceAll('"', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final prompt = isMostlyEnglish(safeText)
        ? 'Read only this exact text verbatim in clear, warm, calm, child-friendly English: "$safeText"'
        : 'اقرأ هذا النص فقط حرفياً بوضوح وسرعة متزنة وهادئة ومحببة للأطفال: "$safeText"';
    return {
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'turnComplete': true,
      },
    };
  }

  /// Tracks models that returned 429 so we skip them in 0ms for 10 minutes.
  final Map<String, DateTime> _rateLimitedUntil = {};

  Directory _getPersistentTtsDir() {
    return AppStorage.getRootDir(subDir: 'tts_cache');
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
      return {'Authorization': 'Bearer ${session.googleAccessToken!.trim()}'};
    }
    final key = session.apiKey.trim().isNotEmpty
        ? session.apiKey.trim()
        : GeminiService.defaultTestApiKey;
    return {'x-goog-api-key': key};
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

  static ({String first, String second}) _splitLongClause(
    String clause, {
    int targetLen = 42,
  }) {
    final maxCap = (targetLen + 8).clamp(18, 55);
    final limit = clause.length < maxCap ? clause.length : maxCap;
    final minComma = (limit * 0.45).round().clamp(8, limit - 1);
    int splitAt = -1;

    // Prefer splitting at an Arabic or ASCII comma near targetLen.
    for (int i = limit - 1; i >= minComma; i--) {
      final ch = clause[i];
      if (ch == '،' || ch == ',') {
        splitAt = i + 1;
        break;
      }
    }
    if (splitAt < 0) {
      final start = targetLen.clamp(minComma, limit - 1);
      for (int i = start; i >= minComma; i--) {
        if (clause[i] == ' ') {
          splitAt = i + 1;
          break;
        }
      }
    }
    if (splitAt < 0) {
      final nextSpace = clause.indexOf(' ', targetLen.clamp(0, clause.length));
      splitAt = nextSpace > 0 ? nextSpace + 1 : clause.length;
    }

    final first = clause.substring(0, splitAt).trim();
    final second = clause.substring(splitAt).trim();
    return (first: first, second: second);
  }

  static List<String> _splitBalancedChunks(String text, {int maxLen = 75}) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return const [];
    if (cleaned.length <= maxLen) return [cleaned];

    final parts = cleaned
        .split(RegExp(r'(?<=[.!؟،])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final chunks = <String>[];
    var buf = StringBuffer();
    for (final part in parts) {
      if (part.length > maxLen) {
        if (buf.isNotEmpty) {
          chunks.add(buf.toString().trim());
          buf = StringBuffer();
        }
        final words = part.split(' ');
        for (final w in words) {
          if (buf.length + w.length + 1 > maxLen && buf.isNotEmpty) {
            chunks.add(buf.toString().trim());
            buf = StringBuffer(w);
          } else {
            if (buf.isNotEmpty) buf.write(' ');
            buf.write(w);
          }
        }
        continue;
      }
      if (buf.length + part.length + 1 > maxLen && buf.isNotEmpty) {
        chunks.add(buf.toString().trim());
        buf = StringBuffer(part);
      } else {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(part);
      }
    }
    if (buf.isNotEmpty) {
      chunks.add(buf.toString().trim());
    }
    return chunks;
  }

  /// Splits backup Arabic text into a fast-start [leadIn] (~150-245 chars)
  /// plus larger [restChunks] (<=360 chars each) for very long texts;
  /// standard explanations (<=450 chars) run as one seamless request.
  static ({String leadIn, List<String> restChunks})
  splitForContinuousBackupSpeech(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 450) {
      return (leadIn: cleaned, restChunks: const []);
    }

    final rawSentences = cleaned
        .split(RegExp(r'(?<=[.!؟])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final leadParts = <String>[];
    var leadLen = 0;
    var idx = 0;

    while (idx < rawSentences.length) {
      final s = rawSentences[idx];
      final nextLen = leadLen + (leadLen == 0 ? 0 : 1) + s.length;
      if (nextLen > 245) {
        if (leadLen >= 120) {
          break;
        }
        final budget = (235 - leadLen).clamp(100, 210);
        final cut = _splitLongClause(s, targetLen: budget);
        leadParts.add(cut.first);
        if (cut.second.isNotEmpty) {
          rawSentences[idx] = cut.second;
        } else {
          idx++;
        }
        break;
      }
      leadParts.add(s);
      leadLen = nextLen;
      idx++;
      if (leadLen >= 150) break;
    }

    final leadIn = leadParts.join(' ').trim();
    final restText = rawSentences.sublist(idx).join(' ').trim();
    if (restText.isEmpty) {
      return (leadIn: leadIn, restChunks: const []);
    }

    final restChunks = _splitBalancedChunks(restText, maxLen: 360);
    return (leadIn: leadIn, restChunks: restChunks);
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

  /// Escapes XML special chars and builds Edge Neural SSML for the target voice.
  static String buildEdgeSsml(
    String text, {
    String voice = 'ar-SA-HamedNeural',
    String rate = '+0%',
    String pitch = '+0Hz',
  }) {
    final parts = voice.split('-');
    final lang = parts.length >= 2 ? '${parts[0]}-${parts[1]}' : 'ar-SA';
    final cleaned = text
        .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ')
        .replaceAll(
          RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final escaped = cleaned
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$lang'>"
        "<voice name='$voice'>"
        "<prosody pitch='$pitch' rate='$rate'>$escaped</prosody>"
        '</voice>'
        '</speak>';
  }

  Future<Uint8List> _synthesizeEdgeArabicBytesOnSocket(
    WebSocket ws,
    Stream<dynamic> stream,
    String cleanText, {
    required String voice,
    required String rate,
    required String pitch,
    required bool sendSpeechConfig,
  }) async {
    final audioBuilder = BytesBuilder(copy: false);
    final done = Completer<void>();
    StreamSubscription<dynamic>? sub;

    try {
      sub = stream.listen(
        (frame) {
          if (frame is String) {
            if (frame.contains('Path:turn.end')) {
              if (!done.isCompleted) done.complete();
              try {
                ws.close();
              } catch (_) {}
            }
          } else if (frame is List<int>) {
            if (frame.length > 2) {
              final hdrLen = ((frame[0] & 0xFF) << 8) | (frame[1] & 0xFF);
              final audioStart = 2 + hdrLen;
              if (audioStart < frame.length) {
                audioBuilder.add(frame.sublist(audioStart));
              }
            }
          }
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );

      if (sendSpeechConfig) {
        final cfgTs = DateTime.now().toUtc().toIso8601String();
        ws.add(
          'X-Timestamp:$cfgTs\r\n'
          'Content-Type:application/json; charset=utf-8\r\n'
          'Path:speech.config\r\n\r\n'
          '{"context":{"synthesis":{"audio":{"metadataoptions":'
          '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
          '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
        );
      }

      final reqId = EdgeTtsDrm.generateRandomHex(16);
      final reqTs = DateTime.now().toUtc().toIso8601String();
      final ssml = buildEdgeSsml(
        cleanText,
        voice: voice,
        rate: rate,
        pitch: pitch,
      );
      ws.add(
        'X-RequestId:$reqId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:$reqTs\r\n'
        'Path:ssml\r\n\r\n'
        '$ssml',
      );

      await done.future.timeout(const Duration(seconds: 7));
    } finally {
      await sub?.cancel();
      try {
        await ws.close().timeout(const Duration(milliseconds: 500));
      } catch (_) {}
    }

    final bytes = audioBuilder.takeBytes();
    if (bytes.length <= 100) {
      throw Exception('Edge TTS returned empty audio');
    }
    return bytes;
  }

  Future<Uint8List> _synthesizeEdgeArabicBytes(
    String cleanText, {
    String voice = 'ar-SA-HamedNeural',
    String rate = '+0%',
    String pitch = '+0Hz',
    bool allowWarmSocket = false,
  }) async {
    if (allowWarmSocket) {
      if (_warmEdgeSession == null && _prewarmEdgeFuture != null) {
        try {
          await Future.any<void>([
            _prewarmEdgeFuture!,
            Future<void>.delayed(const Duration(milliseconds: 1200)),
          ]);
        } catch (_) {}
      }
      final warm = _warmEdgeSession;
      if (warm != null &&
          !warm.closed &&
          DateTime.now().difference(warm.readyAt) <
              const Duration(seconds: 25)) {
        _warmEdgeSession = null;
        await warm.watchSub?.cancel();
        warm.watchSub = null;
        _scheduleEdgePrewarm();
        try {
          return await _synthesizeEdgeArabicBytesOnSocket(
            warm.ws,
            warm.stream,
            cleanText,
            voice: voice,
            rate: rate,
            pitch: pitch,
            sendSpeechConfig: false,
          );
        } catch (_) {
          // Warm socket went stale; fall through seamlessly to fresh connection.
        }
      }
    }

    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      try {
        final ws = await EdgeTtsDrm.connectWebSocket();
        return await _synthesizeEdgeArabicBytesOnSocket(
          ws,
          ws,
          cleanText,
          voice: voice,
          rate: rate,
          pitch: pitch,
          sendSpeechConfig: true,
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  Future<String> _synthesizeEdgeArabicMp3(
    String cleanText, {
    String voiceName = 'FastArabic',
  }) async {
    final cfg = _edgeVoiceConfig(voiceName, sampleText: cleanText);
    final ttsDir = _getPersistentTtsDir();
    final fileHash = _deterministicFileHash(cfg.cachePrefix, cleanText);
    final cachedFile = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$fileHash.mp3',
    );
    if (cachedFile.existsSync() && cachedFile.lengthSync() > 100) {
      return cachedFile.path;
    }

    final bytes = await _synthesizeEdgeArabicBytes(
      cleanText,
      voice: cfg.edgeVoice,
      rate: cfg.rate,
      pitch: cfg.pitch,
      allowWarmSocket: true,
    );
    await cachedFile.writeAsBytes(bytes, flush: true);
    return cachedFile.path;
  }

  Future<String> _synthesizeFastArabicMp3(String cleanText) async {
    final ttsDir = _getPersistentTtsDir();
    final langCode = isMostlyEnglish(cleanText) ? 'en' : 'ar';
    final fileHash = _deterministicFileHash('FastArabic_$langCode', cleanText);
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
          'tl': langCode,
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
            final content =
                (candidates.first as Map<String, dynamic>)['content']
                    as Map<String, dynamic>?;
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
    if (isEdgeArabicVoice(voiceName)) {
      try {
        return await _synthesizeEdgeArabicMp3(cleanText, voiceName: voiceName);
      } catch (_) {
        return _synthesizeFastArabicMp3(cleanText);
      }
    }
    return _synthesizeSingleGeminiSegment(
      session: session,
      cleanText: cleanText,
      voiceName: voiceName,
    );
  }

  Future<T?> _awaitWithPrewarmTimer<T>(
    Future<T> future,
    Duration timeout,
  ) async {
    if (_disposed) return null;
    final completer = Completer<T?>();
    _prewarmTimer?.cancel();
    void abort() {
      _prewarmTimer?.cancel();
      _prewarmTimer = null;
      _cancelActivePrewarm = null;
      if (!completer.isCompleted) completer.complete(null);
    }

    _cancelActivePrewarm = abort;
    _prewarmTimer = Timer(timeout, abort);
    future.then(
      (val) {
        _prewarmTimer?.cancel();
        _prewarmTimer = null;
        if (_cancelActivePrewarm == abort) _cancelActivePrewarm = null;
        if (!completer.isCompleted) completer.complete(val);
      },
      onError: (_) {
        abort();
      },
    );
    return completer.future;
  }

  void _scheduleEdgePrewarm() {
    if (_disposed || _prewarmingEdge) return;
    Future<void>.delayed(Duration.zero, () {
      if (!_disposed) {
        _prewarmEdgeSocket();
      }
    });
  }

  Future<void> _prewarmEdgeSocket() async {
    if (_disposed) return;
    final existing = _warmEdgeSession;
    if (existing != null &&
        !existing.closed &&
        DateTime.now().difference(existing.readyAt) <
            const Duration(seconds: 25)) {
      return;
    }
    if (_prewarmingEdge) return;
    _prewarmingEdge = true;
    final done = Completer<void>();
    _prewarmEdgeFuture = done.future;
    try {
      if (existing != null) {
        _warmEdgeSession = null;
        await existing.dispose();
      }
      if (_disposed) return;
      final ws = await _awaitWithPrewarmTimer(
        EdgeTtsDrm.connectWebSocket().catchError(
          (_) => EdgeTtsDrm.connectWebSocket(),
        ),
        const Duration(seconds: 8),
      );
      if (ws == null || _disposed) {
        try {
          await ws?.close();
        } catch (_) {}
        return;
      }
      final broadcast = ws.asBroadcastStream();
      final cfgTs = DateTime.now().toUtc().toIso8601String();
      ws.add(
        'X-Timestamp:$cfgTs\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
      );
      _warmEdgeSession = _WarmEdgeSession(
        ws: ws,
        stream: broadcast,
        readyAt: DateTime.now(),
      );
    } catch (_) {
    } finally {
      _prewarmingEdge = false;
      _prewarmEdgeFuture = null;
      if (!done.isCompleted) done.complete();
    }
  }

  /// Pre-warms TLS + WebSocket handshake in the background (0 tokens consumed!)
  /// so speaking starts almost instantaneously after the tutor finishes thinking.
  Future<void> prewarmConnection({
    required UserSession session,
    required String voiceName,
  }) async {
    if (_disposed) return;
    if (isEdgeArabicVoice(voiceName)) {
      final staleLive = _warmLiveSession;
      _warmLiveSession = null;
      if (staleLive != null) {
        staleLive.dispose();
      }
      await _prewarmEdgeSocket();
      return;
    }

    final staleEdge = _warmEdgeSession;
    _warmEdgeSession = null;
    if (staleEdge != null) {
      staleEdge.dispose();
    }

    final useOAuth =
        session.useOAuthTokenForGemini &&
        session.googleAccessToken != null &&
        session.googleAccessToken!.trim().isNotEmpty;
    final rawKey = session.apiKey.trim().isNotEmpty
        ? session.apiKey.trim()
        : GeminiService.defaultTestApiKey;
    if (!useOAuth && rawKey.isEmpty) return;

    final now = DateTime.now();
    final targetModel = allGeminiLiveModels.firstWhere((m) {
      final until = _rateLimitedUntil[m];
      return until == null || now.isAfter(until);
    }, orElse: () => allGeminiLiveModels.first);

    final existingLive = _warmLiveSession;
    if (existingLive != null &&
        !existingLive.closed &&
        existingLive.voiceName == voiceName &&
        existingLive.model == targetModel &&
        now.difference(existingLive.readyAt) < const Duration(seconds: 40)) {
      return;
    }
    if (_prewarmingLive) return;
    _prewarmingLive = true;
    final livePrewarmDone = Completer<void>();
    _prewarmLiveFuture = livePrewarmDone.future;

    try {
      if (existingLive != null) {
        _warmLiveSession = null;
        await existingLive.dispose();
      }
      if (_disposed) return;
      final wsUrl = useOAuth
          ? 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
          : 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${Uri.encodeQueryComponent(rawKey)}';
      final headers = useOAuth
          ? <String, dynamic>{
              'Authorization': 'Bearer ${session.googleAccessToken!.trim()}',
            }
          : null;

      final ws = await _awaitWithPrewarmTimer(
        WebSocket.connect(wsUrl, headers: headers),
        const Duration(seconds: 8),
      );
      if (ws == null || _disposed) {
        try {
          await ws?.close();
        } catch (_) {}
        return;
      }

      final broadcast = ws.asBroadcastStream();
      final setupDone = Completer<bool>();
      late final StreamSubscription<dynamic> sub;
      sub = broadcast.listen(
        (frame) {
          try {
            final jsonStr = frame is String
                ? frame
                : utf8.decode(frame as List<int>);
            final msg = jsonDecode(jsonStr) as Map<String, dynamic>;
            if (msg.containsKey('setupComplete') && !setupDone.isCompleted) {
              setupDone.complete(true);
            } else if (msg['error'] != null && !setupDone.isCompleted) {
              setupDone.complete(false);
            }
          } catch (_) {}
        },
        onError: (_) {
          if (!setupDone.isCompleted) setupDone.complete(false);
        },
        onDone: () {
          if (!setupDone.isCompleted) setupDone.complete(false);
        },
        cancelOnError: true,
      );

      ws.add(
        jsonEncode(
          buildLiveSetupPayload(model: targetModel, voiceName: voiceName),
        ),
      );
      final ok =
          await _awaitWithPrewarmTimer(
            setupDone.future,
            const Duration(seconds: 6),
          ) ??
          false;
      await sub.cancel();

      if (ok && !_disposed) {
        _warmLiveSession = _WarmLiveSession(
          ws: ws,
          stream: broadcast,
          model: targetModel,
          voiceName: voiceName,
          readyAt: DateTime.now(),
        );
      } else {
        try {
          await ws.close();
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      _prewarmingLive = false;
      _prewarmLiveFuture = null;
      if (!livePrewarmDone.isCompleted) livePrewarmDone.complete();
    }
  }

  /// Pre-warms only Edge Neural first segment (0 Gemini quota).
  Future<void> prewarmFirstSentence({
    required UserSession session,
    required String text,
    String voiceName = 'Puck',
  }) async {
    if (!isEdgeArabicVoice(voiceName)) return;
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;
    final cfg = _edgeVoiceConfig(voiceName, sampleText: cleanText);
    final split = splitForContinuousBackupSpeech(cleanText);
    if (split.leadIn.isEmpty) return;
    final ttsDir = _getPersistentTtsDir();
    final leadHash = _deterministicFileHash(cfg.cachePrefix, split.leadIn);
    final leadFile = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$leadHash.mp3',
    );
    if (leadFile.existsSync() && leadFile.lengthSync() > 100) return;
    try {
      final bytes = await _synthesizeEdgeArabicBytes(
        split.leadIn,
        voice: cfg.edgeVoice,
        rate: cfg.rate,
        pitch: cfg.pitch,
        allowWarmSocket: true,
      );
      await leadFile.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  Future<void> _startPcmStream({
    required int sampleRate,
    required int generation,
  }) async {
    if (generation != _playbackGeneration) return;
    if (Platform.isWindows) {
      _winPlayer.stopAndClose();
      _waveOutPlayer.open(sampleRate: sampleRate);
    } else if (Platform.isAndroid) {
      await _androidAudioChannel.invokeMethod('startPcmStream', {
        'sampleRate': sampleRate,
      });
    }
  }

  Future<void> _writePcmChunk(
    Uint8List chunk, {
    required int generation,
  }) async {
    if (generation != _playbackGeneration || chunk.isEmpty) return;
    if (Platform.isWindows) {
      _waveOutPlayer.writeChunk(chunk);
    } else if (Platform.isAndroid) {
      await _androidAudioChannel.invokeMethod('writePcmChunk', {
        'bytes': chunk,
      });
    }
  }

  Future<void> _finishPcmStream({required int generation}) async {
    if (Platform.isWindows) {
      await _waveOutPlayer.drain(() => generation == _playbackGeneration);
    } else if (Platform.isAndroid) {
      if (generation == _playbackGeneration) {
        await _androidAudioChannel.invokeMethod('finishPcmStream');
      }
    }
  }

  Future<bool> _speakViaLiveWebSocket({
    required UserSession session,
    required String cleanText,
    required String voiceName,
    required int generation,
    required File cacheFile,
    VoidCallback? onPlaybackStarted,
  }) async {
    final useOAuth =
        session.useOAuthTokenForGemini &&
        session.googleAccessToken != null &&
        session.googleAccessToken!.trim().isNotEmpty;
    final rawKey = session.apiKey.trim().isNotEmpty
        ? session.apiKey.trim()
        : GeminiService.defaultTestApiKey;

    if (!useOAuth && rawKey.isEmpty) return false;

    final now = DateTime.now();
    final orderedModels = [
      ...allGeminiLiveModels.where((m) {
        final until = _rateLimitedUntil[m];
        return until == null || now.isAfter(until);
      }),
      ...allGeminiLiveModels.where((m) {
        final until = _rateLimitedUntil[m];
        return until != null && now.isBefore(until);
      }),
    ];

    for (final model in orderedModels) {
      if (generation != _playbackGeneration) return true;

      WebSocket? ws;
      StreamSubscription<dynamic>? frameSub;
      var streamOpened = false;
      var sawTurnComplete = false;
      var rateLimited = false;
      var liveSampleRate = 24000;
      final allPcm = BytesBuilder(copy: false);
      final pendingBuf = BytesBuilder(copy: false);
      Future<void> pcmQueue = Future<void>.value();
      final done = Completer<void>();

      try {
        Stream<dynamic> frameStream;
        if (_warmLiveSession == null && _prewarmLiveFuture != null) {
          try {
            await Future.any<void>([
              _prewarmLiveFuture!,
              Future<void>.delayed(const Duration(milliseconds: 1200)),
            ]);
          } catch (_) {}
        }
        final warm = _warmLiveSession;
        final canUseWarm =
            warm != null &&
            !warm.closed &&
            warm.model == model &&
            warm.voiceName == voiceName &&
            DateTime.now().difference(warm.readyAt) <
                const Duration(seconds: 40);

        if (canUseWarm) {
          _warmLiveSession = null;
          await warm.watchSub?.cancel();
          warm.watchSub = null;
          ws = warm.ws;
          frameStream = warm.stream;
        } else {
          final wsUrl = useOAuth
              ? 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
              : 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${Uri.encodeQueryComponent(rawKey)}';
          final headers = useOAuth
              ? <String, dynamic>{
                  'Authorization':
                      'Bearer ${session.googleAccessToken!.trim()}',
                }
              : null;

          ws = await WebSocket.connect(
            wsUrl,
            headers: headers,
          ).timeout(const Duration(seconds: 8));
          frameStream = ws;
        }

        if (generation != _playbackGeneration) {
          try {
            await ws.close();
          } catch (_) {}
          return true;
        }
        _activeLiveSocket = ws;

        frameSub = frameStream.listen(
          (frame) {
            if (generation != _playbackGeneration) {
              if (!done.isCompleted) done.complete();
              try {
                ws?.close();
              } catch (_) {}
              return;
            }
            try {
              final jsonStr = frame is String
                  ? frame
                  : utf8.decode(frame as List<int>);
              final msg = jsonDecode(jsonStr) as Map<String, dynamic>;

              if (msg.containsKey('setupComplete')) {
                ws?.add(jsonEncode(buildLiveSpeakPayload(cleanText)));
                return;
              }

              final errorObj = msg['error'];
              if (errorObj != null) {
                final errText = errorObj.toString();
                if (errText.contains('429') ||
                    errText.contains('RESOURCE_EXHAUSTED')) {
                  rateLimited = true;
                }
                if (!done.isCompleted) done.complete();
                try {
                  ws?.close();
                } catch (_) {}
                return;
              }

              final serverContent =
                  msg['serverContent'] as Map<String, dynamic>?;
              if (serverContent != null) {
                final modelTurn =
                    serverContent['modelTurn'] as Map<String, dynamic>?;
                final parts = modelTurn?['parts'] as List<dynamic>? ?? const [];
                for (final p in parts) {
                  if (p is Map<String, dynamic>) {
                    final inlineData = p['inlineData'] as Map<String, dynamic>?;
                    final mimeType = inlineData?['mimeType']?.toString();
                    if (!streamOpened && mimeType != null) {
                      final m = RegExp(r'rate=(\d+)').firstMatch(mimeType);
                      if (m != null) {
                        liveSampleRate =
                            int.tryParse(m.group(1) ?? '') ?? liveSampleRate;
                      }
                    }
                    final b64 = inlineData?['data']?.toString();
                    if (b64 != null && b64.isNotEmpty) {
                      final decoded = base64Decode(b64);
                      allPcm.add(decoded);
                      pendingBuf.add(decoded);
                    }
                  }
                }

                // 50ms pre-buffer (at liveSampleRate 16-bit mono) for instant mobile/desktop start
                if (!streamOpened && pendingBuf.length >= 2400) {
                  final firstChunk = pendingBuf.takeBytes();
                  final streamRate = liveSampleRate;
                  streamOpened = true;
                  pcmQueue = pcmQueue.then((_) async {
                    if (generation != _playbackGeneration) return;
                    await _startPcmStream(
                      sampleRate: streamRate,
                      generation: generation,
                    );
                    if (generation != _playbackGeneration) return;
                    onPlaybackStarted?.call();
                    await _writePcmChunk(firstChunk, generation: generation);
                  });
                } else if (streamOpened && pendingBuf.length >= 2400) {
                  final chunk = pendingBuf.takeBytes();
                  pcmQueue = pcmQueue.then(
                    (_) => _writePcmChunk(chunk, generation: generation),
                  );
                }

                if (serverContent['turnComplete'] == true) {
                  final leftover = pendingBuf.takeBytes();
                  if (leftover.isNotEmpty) {
                    if (!streamOpened) {
                      final streamRate = liveSampleRate;
                      streamOpened = true;
                      pcmQueue = pcmQueue.then((_) async {
                        if (generation != _playbackGeneration) return;
                        await _startPcmStream(
                          sampleRate: streamRate,
                          generation: generation,
                        );
                        if (generation != _playbackGeneration) return;
                        onPlaybackStarted?.call();
                        await _writePcmChunk(leftover, generation: generation);
                      });
                    } else {
                      pcmQueue = pcmQueue.then(
                        (_) => _writePcmChunk(leftover, generation: generation),
                      );
                    }
                  }
                  sawTurnComplete = true;
                  if (!done.isCompleted) done.complete();
                  try {
                    ws?.close();
                  } catch (_) {}
                }
              }
            } catch (_) {}
          },
          onError: (Object err) {
            final errStr = err.toString();
            if (errStr.contains('429') ||
                errStr.contains('RESOURCE_EXHAUSTED')) {
              rateLimited = true;
            }
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            final reason = ws?.closeReason ?? '';
            if (reason.contains('429') ||
                reason.contains('RESOURCE_EXHAUSTED') ||
                reason.contains('quota')) {
              rateLimited = true;
            }
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );

        if (canUseWarm) {
          ws.add(jsonEncode(buildLiveSpeakPayload(cleanText)));
        } else {
          ws.add(
            jsonEncode(
              buildLiveSetupPayload(model: model, voiceName: voiceName),
            ),
          );
        }

        await done.future.timeout(
          const Duration(seconds: 45),
          onTimeout: () {
            try {
              ws?.close();
            } catch (_) {}
          },
        );
        await frameSub.cancel();
        frameSub = null;

        await pcmQueue;

        if (_activeLiveSocket == ws) {
          _activeLiveSocket = null;
        }

        if (generation != _playbackGeneration) return true;

        final totalPcmBytes = allPcm.length;
        if (sawTurnComplete && totalPcmBytes > 0 && streamOpened) {
          _rateLimitedUntil.remove(model);
          final wavBytes = _ensureWavHeader(
            allPcm.takeBytes(),
            sampleRate: liveSampleRate,
          );
          try {
            await cacheFile.writeAsBytes(wavBytes, flush: true);
          } catch (_) {}
          await _finishPcmStream(generation: generation);
          return true;
        }

        if (streamOpened) {
          if (Platform.isWindows) {
            _waveOutPlayer.stopAndClose();
          } else if (Platform.isAndroid) {
            try {
              await _androidAudioChannel.invokeMethod('stop');
            } catch (_) {}
          }
          // Already started speaking partial audio; avoid confusing duplicate fallback.
          if (totalPcmBytes > 0) return true;
        }

        if (rateLimited) {
          _rateLimitedUntil[model] = DateTime.now().add(
            const Duration(minutes: 10),
          );
        }
      } catch (e) {
        await frameSub?.cancel();
        if (_activeLiveSocket == ws) {
          _activeLiveSocket = null;
        }
        try {
          await ws?.close();
        } catch (_) {}
        if (generation != _playbackGeneration) return true;

        final errStr = e.toString();
        if (errStr.contains('429') || errStr.contains('RESOURCE_EXHAUSTED')) {
          _rateLimitedUntil[model] = DateTime.now().add(
            const Duration(minutes: 10),
          );
        }
        if (streamOpened) {
          if (Platform.isWindows) {
            _waveOutPlayer.stopAndClose();
          } else if (Platform.isAndroid) {
            try {
              await _androidAudioChannel.invokeMethod('stop');
            } catch (_) {}
          }
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _speakViaRestTts({
    required UserSession session,
    required String cleanText,
    required String voiceName,
    required int generation,
    required File cacheFile,
    VoidCallback? onPlaybackStarted,
  }) async {
    if (cleanText.length <= 320) {
      final path = await _synthesizeSingleGeminiSegment(
        session: session,
        cleanText: cleanText,
        voiceName: voiceName,
      );
      if (generation != _playbackGeneration) return;
      try {
        if (path != cacheFile.path) {
          await File(path).copy(cacheFile.path);
        }
      } catch (_) {}
      onPlaybackStarted?.call();
      await _playAudioFileInternal(path, generation: generation);
      return;
    }

    final sentences = splitIntoPlayableSentences(cleanText);
    Future<String>? nextFuture = _synthesizeSingleGeminiSegment(
      session: session,
      cleanText: sentences.first,
      voiceName: voiceName,
    );

    bool notifiedStart = false;
    for (int i = 0; i < sentences.length; i++) {
      if (generation != _playbackGeneration) return;
      final audioPath = await nextFuture!;
      if (generation != _playbackGeneration) return;

      if (i + 1 < sentences.length) {
        nextFuture = _synthesizeSingleGeminiSegment(
          session: session,
          cleanText: sentences[i + 1],
          voiceName: voiceName,
        );
      } else {
        nextFuture = null;
      }

      if (!notifiedStart) {
        notifiedStart = true;
        onPlaybackStarted?.call();
      }
      await _playAudioFileInternal(audioPath, generation: generation);
    }
  }

  Future<void> _speakGoogleTranslateFallback({
    required String cleanText,
    required int generation,
    double speed = 1.0,
    double pitch = 1.0,
    bool alreadyStarted = false,
    VoidCallback? onPlaybackStarted,
  }) async {
    final sentences = splitIntoPlayableSentences(cleanText);
    var nextFuture = _synthesizeFastArabicMp3(sentences.first);
    var notifiedStart = alreadyStarted;

    for (int i = 0; i < sentences.length; i++) {
      if (generation != _playbackGeneration) return;
      final path = await nextFuture;
      if (generation != _playbackGeneration) return;

      if (i + 1 < sentences.length) {
        nextFuture = _synthesizeFastArabicMp3(sentences[i + 1]);
      }

      if (!notifiedStart) {
        notifiedStart = true;
        onPlaybackStarted?.call();
      }
      await _playAudioFileInternal(
        path,
        generation: generation,
        speed: speed,
        pitch: pitch,
      );
    }
  }

  /// Streams Edge Neural MP3 packets directly to Android MediaCodec -> AudioTrack
  /// so playback starts in <1s on the very first 720-byte audio packet without
  /// waiting for the full MP3 download or splitting text across voices.
  Future<bool> _speakEdgeStreamingOnAndroid({
    required String cleanText,
    required String voiceName,
    required int generation,
    required File cacheFile,
    VoidCallback? onPlaybackStarted,
  }) async {
    final cfg = _edgeVoiceConfig(voiceName, sampleText: cleanText);

    for (var attempt = 0; attempt < 2; attempt++) {
      if (generation != _playbackGeneration) return true;

      WebSocket? ws;
      StreamSubscription<dynamic>? frameSub;
      Timer? firstAudioWatchdog;
      var streamOpened = false;
      var sawTurnComplete = false;
      final allMp3 = BytesBuilder(copy: false);
      final pendingMp3 = BytesBuilder(copy: false);
      Future<void> mp3Queue = Future<void>.value();
      final done = Completer<void>();

      try {
        Stream<dynamic> frameStream;
        var usedWarmSocket = false;

        if (attempt == 0) {
          if (_warmEdgeSession == null && _prewarmEdgeFuture != null) {
            try {
              await Future.any<void>([
                _prewarmEdgeFuture!,
                Future<void>.delayed(const Duration(milliseconds: 1200)),
              ]);
            } catch (_) {}
          }
          final warm = _warmEdgeSession;
          if (warm != null &&
              !warm.closed &&
              DateTime.now().difference(warm.readyAt) <
                  const Duration(seconds: 25)) {
            _warmEdgeSession = null;
            await warm.watchSub?.cancel();
            warm.watchSub = null;
            ws = warm.ws;
            frameStream = warm.stream;
            usedWarmSocket = true;
            _scheduleEdgePrewarm();
          } else {
            final freshWs = await EdgeTtsDrm.connectWebSocket();
            ws = freshWs;
            frameStream = freshWs;
            _scheduleEdgePrewarm();
          }
        } else {
          final freshWs = await EdgeTtsDrm.connectWebSocket();
          ws = freshWs;
          frameStream = freshWs;
          _scheduleEdgePrewarm();
        }

        if (generation != _playbackGeneration) {
          try {
            await ws.close();
          } catch (_) {}
          return true;
        }
        _activeLiveSocket = ws;

        firstAudioWatchdog = Timer(const Duration(seconds: 5), () {
          if (!streamOpened) {
            if (!done.isCompleted) done.complete();
            try {
              ws?.close();
            } catch (_) {}
          }
        });

        frameSub = frameStream.listen(
          (frame) {
            if (generation != _playbackGeneration) {
              if (!done.isCompleted) done.complete();
              try {
                ws?.close();
              } catch (_) {}
              return;
            }
            if (frame is String) {
              if (frame.contains('Path:turn.end')) {
                final leftover = pendingMp3.takeBytes();
                if (leftover.isNotEmpty) {
                  if (!streamOpened) {
                    streamOpened = true;
                    firstAudioWatchdog?.cancel();
                    mp3Queue = mp3Queue.then((_) async {
                      if (generation != _playbackGeneration) return;
                      await _androidAudioChannel.invokeMethod('startMp3Stream', {
                        'sampleRate': 24000,
                        'channelCount': 1,
                      });
                      if (generation != _playbackGeneration) return;
                      onPlaybackStarted?.call();
                      await _androidAudioChannel.invokeMethod('writeMp3Chunk', {
                        'bytes': leftover,
                      });
                    });
                  } else {
                    mp3Queue = mp3Queue.then((_) async {
                      if (generation != _playbackGeneration) return;
                      await _androidAudioChannel.invokeMethod('writeMp3Chunk', {
                        'bytes': leftover,
                      });
                    });
                  }
                }
                sawTurnComplete = true;
                if (!done.isCompleted) done.complete();
                try {
                  ws?.close();
                } catch (_) {}
              }
            } else if (frame is List<int> && frame.length > 2) {
              final hdrLen = ((frame[0] & 0xFF) << 8) | (frame[1] & 0xFF);
              final audioStart = 2 + hdrLen;
              if (audioStart < frame.length) {
                final mp3Slice = frame.sublist(audioStart);
                allMp3.add(mp3Slice);
                pendingMp3.add(mp3Slice);

                if (!streamOpened && pendingMp3.length >= 720) {
                  final firstChunk = pendingMp3.takeBytes();
                  streamOpened = true;
                  firstAudioWatchdog?.cancel();
                  mp3Queue = mp3Queue.then((_) async {
                    if (generation != _playbackGeneration) return;
                    await _androidAudioChannel.invokeMethod('startMp3Stream', {
                      'sampleRate': 24000,
                      'channelCount': 1,
                    });
                    if (generation != _playbackGeneration) return;
                    onPlaybackStarted?.call();
                    await _androidAudioChannel.invokeMethod('writeMp3Chunk', {
                      'bytes': firstChunk,
                    });
                  });
                } else if (streamOpened && pendingMp3.length >= 720) {
                  final chunk = pendingMp3.takeBytes();
                  mp3Queue = mp3Queue.then((_) async {
                    if (generation != _playbackGeneration) return;
                    await _androidAudioChannel.invokeMethod('writeMp3Chunk', {
                      'bytes': chunk,
                    });
                  });
                }
              }
            }
          },
          onError: (_) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );

        if (!usedWarmSocket) {
          final cfgTs = DateTime.now().toUtc().toIso8601String();
          ws.add(
            'X-Timestamp:$cfgTs\r\n'
            'Content-Type:application/json; charset=utf-8\r\n'
            'Path:speech.config\r\n\r\n'
            '{"context":{"synthesis":{"audio":{"metadataoptions":'
            '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
            '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
          );
        }

        final reqId = EdgeTtsDrm.generateRandomHex(16);
        final reqTs = DateTime.now().toUtc().toIso8601String();
        final ssml = buildEdgeSsml(
          cleanText,
          voice: cfg.edgeVoice,
          rate: cfg.rate,
          pitch: cfg.pitch,
        );
        ws.add(
          'X-RequestId:$reqId\r\n'
          'Content-Type:application/ssml+xml\r\n'
          'X-Timestamp:$reqTs\r\n'
          'Path:ssml\r\n\r\n'
          '$ssml',
        );

        await done.future.timeout(
          const Duration(seconds: 40),
          onTimeout: () {
            try {
              ws?.close();
            } catch (_) {}
          },
        );
        firstAudioWatchdog.cancel();
        await frameSub.cancel();
        frameSub = null;
        await mp3Queue;

        if (_activeLiveSocket == ws) {
          _activeLiveSocket = null;
        }
        try {
          await ws.close().timeout(const Duration(milliseconds: 300));
        } catch (_) {}

        if (generation != _playbackGeneration) return true;

        if (sawTurnComplete && allMp3.length > 100 && streamOpened) {
          try {
            await cacheFile.writeAsBytes(allMp3.takeBytes(), flush: true);
          } catch (_) {}
          if (generation == _playbackGeneration) {
            await _androidAudioChannel.invokeMethod('finishMp3Stream');
          }
          return true;
        }

        if (streamOpened) {
          try {
            await _androidAudioChannel.invokeMethod('stop');
          } catch (_) {}
          // Audio already started in this voice; never switch mid-message.
          return true;
        }
      } catch (_) {
        firstAudioWatchdog?.cancel();
        await frameSub?.cancel();
        if (_activeLiveSocket == ws) {
          _activeLiveSocket = null;
        }
        try {
          await ws?.close().timeout(const Duration(milliseconds: 300));
        } catch (_) {}
        if (generation != _playbackGeneration) return true;
        if (streamOpened) {
          try {
            await _androidAudioChannel.invokeMethod('stop');
          } catch (_) {}
          return true;
        }
      }
    }

    return false;
  }

  Future<void> _speakFastArabicPipelined({
    required String cleanText,
    required int generation,
    String voiceName = 'FastArabic',
    double fallbackSpeed = 1.0,
    double fallbackPitch = 1.0,
    VoidCallback? onPlaybackStarted,
  }) async {
    final cfg = _edgeVoiceConfig(voiceName, sampleText: cleanText);
    final ttsDir = _getPersistentTtsDir();
    final edgeHash = _deterministicFileHash(cfg.cachePrefix, cleanText);
    final edgeCached = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$edgeHash.mp3',
    );
    if (edgeCached.existsSync() && edgeCached.lengthSync() > 100) {
      if (generation != _playbackGeneration) return;
      onPlaybackStarted?.call();
      await _playAudioFileInternal(edgeCached.path, generation: generation);
      return;
    }

    if (Platform.isAndroid) {
      final streamed = await _speakEdgeStreamingOnAndroid(
        cleanText: cleanText,
        voiceName: voiceName,
        generation: generation,
        cacheFile: edgeCached,
        onPlaybackStarted: onPlaybackStarted,
      );
      if (streamed || generation != _playbackGeneration) return;
      await _speakGoogleTranslateFallback(
        cleanText: cleanText,
        generation: generation,
        speed: fallbackSpeed,
        pitch: fallbackPitch,
        onPlaybackStarted: onPlaybackStarted,
      );
      return;
    }

    final split = splitForContinuousBackupSpeech(cleanText);
    if (split.restChunks.isEmpty) {
      try {
        final edgePath = await _synthesizeEdgeArabicMp3(
          split.leadIn,
          voiceName: voiceName,
        );
        if (generation != _playbackGeneration) return;
        onPlaybackStarted?.call();
        await _playAudioFileInternal(edgePath, generation: generation);
        return;
      } catch (_) {
        if (generation != _playbackGeneration) return;
        await _speakGoogleTranslateFallback(
          cleanText: cleanText,
          generation: generation,
          speed: fallbackSpeed,
          pitch: fallbackPitch,
          onPlaybackStarted: onPlaybackStarted,
        );
        return;
      }
    }

    // For very long texts (> 450 chars), play leadIn first using the warm socket
    // and prefetch remaining chunks sequentially one WebSocket at a time so
    // Edge never throttles parallel sockets and the voice never changes mid-message.
    final leadHash = _deterministicFileHash(cfg.cachePrefix, split.leadIn);
    final leadCached = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$leadHash.mp3',
    );
    Uint8List leadInBytes;
    try {
      if (leadCached.existsSync() && leadCached.lengthSync() > 100) {
        leadInBytes = await leadCached.readAsBytes();
      } else {
        leadInBytes = await _synthesizeEdgeArabicBytes(
          split.leadIn,
          voice: cfg.edgeVoice,
          rate: cfg.rate,
          pitch: cfg.pitch,
          allowWarmSocket: true,
        );
        if (generation != _playbackGeneration) return;
        try {
          await leadCached.writeAsBytes(leadInBytes, flush: true);
        } catch (_) {}
      }
    } catch (_) {
      if (generation != _playbackGeneration) return;
      await _speakGoogleTranslateFallback(
        cleanText: cleanText,
        generation: generation,
        speed: fallbackSpeed,
        pitch: fallbackPitch,
        onPlaybackStarted: onPlaybackStarted,
      );
      return;
    }

    if (generation != _playbackGeneration) return;

    final chunkCompleters =
        List<Completer<({String path, Uint8List bytes})?>>.generate(
          split.restChunks.length,
          (_) => Completer<({String path, Uint8List bytes})?>(),
        );

    // Sequential background worker (1 WebSocket at a time, same Edge voice only).
    () async {
      for (var i = 0; i < split.restChunks.length; i++) {
        if (generation != _playbackGeneration || _disposed) {
          chunkCompleters[i].complete(null);
          continue;
        }
        final chunkText = split.restChunks[i];
        final cHash = _deterministicFileHash(cfg.cachePrefix, chunkText);
        final cFile = File(
          '${ttsDir.path}${Platform.pathSeparator}tts_$cHash.mp3',
        );
        try {
          Uint8List bytes;
          if (cFile.existsSync() && cFile.lengthSync() > 100) {
            bytes = await cFile.readAsBytes();
          } else {
            bytes = await _synthesizeEdgeArabicBytes(
              chunkText,
              voice: cfg.edgeVoice,
              rate: cfg.rate,
              pitch: cfg.pitch,
              allowWarmSocket: false,
            );
            await cFile.writeAsBytes(bytes, flush: true);
          }
          chunkCompleters[i].complete((path: cFile.path, bytes: bytes));
        } catch (_) {
          chunkCompleters[i].complete(null);
        }
      }
    }();

    onPlaybackStarted?.call();
    await _playAudioFileInternal(leadCached.path, generation: generation);
    if (generation != _playbackGeneration) return;

    final combinedEdge = BytesBuilder(copy: false)..add(leadInBytes);
    var allSucceeded = true;

    for (var i = 0; i < chunkCompleters.length; i++) {
      if (generation != _playbackGeneration) return;
      final part = await chunkCompleters[i].future;
      if (generation != _playbackGeneration) return;
      if (part == null) {
        // Stop cleanly rather than switching to a different voice mid-message.
        allSucceeded = false;
        break;
      }
      combinedEdge.add(part.bytes);
      await _playAudioFileInternal(part.path, generation: generation);
    }

    // Cache full seamless audio once every Edge chunk succeeds so replays take 0.00s.
    if (allSucceeded && generation == _playbackGeneration) {
      try {
        await edgeCached.writeAsBytes(combinedEdge.takeBytes(), flush: true);
      } catch (_) {}
    }
  }

  /// Speaks [text] using real-time Gemini Multimodal Live streaming (~460ms first audio),
  /// with disk WAV cache (0.00s replay) and automatic fallback to REST TTS / Edge Neural.
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

    if (isEdgeArabicVoice(voiceName)) {
      await _speakFastArabicPipelined(
        cleanText: cleanText,
        generation: gen,
        voiceName: voiceName,
        onPlaybackStarted: onPlaybackStarted,
      );
      return;
    }

    final ttsDir = _getPersistentTtsDir();
    final liveHash = _deterministicFileHash('live_v2_$voiceName', cleanText);
    final liveCached = File(
      '${ttsDir.path}${Platform.pathSeparator}tts_$liveHash.wav',
    );

    if (liveCached.existsSync() && liveCached.lengthSync() > 44) {
      if (gen != _playbackGeneration) return;
      onPlaybackStarted?.call();
      await _playAudioFileInternal(liveCached.path, generation: gen);
      return;
    }

    // Tier 1: Gemini Multimodal Live API (WebSocket real-time PCM 24kHz)
    final livePlayed = await _speakViaLiveWebSocket(
      session: session,
      cleanText: cleanText,
      voiceName: voiceName,
      generation: gen,
      cacheFile: liveCached,
      onPlaybackStarted: onPlaybackStarted,
    );
    if (livePlayed || gen != _playbackGeneration) return;

    // Tier 2: Gemini REST TTS
    try {
      await _speakViaRestTts(
        session: session,
        cleanText: cleanText,
        voiceName: voiceName,
        generation: gen,
        cacheFile: liveCached,
        onPlaybackStarted: onPlaybackStarted,
      );
      return;
    } catch (_) {
      if (gen != _playbackGeneration) return;
    }

    // Tier 3: Edge Neural Hamed (natural MSA with accurate tashkeel) / Google fallback
    await _speakFastArabicPipelined(
      cleanText: cleanText,
      generation: gen,
      voiceName: 'FastArabic',
      onPlaybackStarted: onPlaybackStarted,
    );
  }

  Future<void> playAudioFile(String audioPath) async {
    await stopPlayback();
    await _playAudioFileInternal(audioPath, generation: _playbackGeneration);
  }

  Future<void> _playAudioFileInternal(
    String audioPath, {
    required int generation,
    double speed = 1.0,
    double pitch = 1.0,
  }) async {
    if (generation != _playbackGeneration) return;

    if (Platform.isWindows) {
      _winPlayer.stopAndClose();
      final (openRc, _) = _winPlayer.send('open "$audioPath" alias kids_tts');
      if (openRc != 0) {
        throw Exception('تعذر فتح ملف الصوت (MCI $openRc)');
      }
      if (speed != 1.0) {
        _winPlayer.send('set kids_tts speed ${(speed * 1000).round()}');
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
      await _androidAudioChannel.invokeMethod('playWav', {
        'path': audioPath,
        'speed': speed,
        'pitch': pitch,
      });
    }
  }

  /// Immediately stops any ongoing speech playback (WebSocket stream, waveOut, AudioTrack, MCI).
  Future<void> stopPlayback() async {
    _playbackGeneration++;
    final sock = _activeLiveSocket;
    _activeLiveSocket = null;
    if (sock != null) {
      try {
        await sock.close();
      } catch (_) {}
    }
    if (Platform.isWindows) {
      _waveOutPlayer.stopAndClose();
      _winPlayer.stopAndClose();
    }
    if (Platform.isAndroid) {
      try {
        await _androidAudioChannel.invokeMethod('stop');
      } catch (_) {}
    }
  }

  /// Releases pre-warmed sockets, players, and HTTP client resources.
  Future<void> dispose() async {
    _disposed = true;
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _cancelActivePrewarm?.call();
    _cancelActivePrewarm = null;
    await stopPlayback();
    final warmLive = _warmLiveSession;
    _warmLiveSession = null;
    if (warmLive != null) {
      await warmLive.dispose();
    }
    final warmEdge = _warmEdgeSession;
    _warmEdgeSession = null;
    if (warmEdge != null) {
      await warmEdge.dispose();
    }
    _httpClient.close();
  }
}
