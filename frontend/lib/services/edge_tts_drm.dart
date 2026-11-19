import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Pure-Dart implementation of Microsoft Edge Read-Aloud v2 Sec-MS-GEC token
/// generation (CS64 + SHA-256), with zero external crypto dependencies.
class EdgeTtsDrm {
  static const String trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String chromiumFullVersion = '143.0.3650.75';
  static const String secMsGecVersion = '2-$chromiumFullVersion';
  static const String origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';

  static const int _winEpochSeconds = 11644473600;
  static const int _u32Mask = 0xFFFFFFFF;

  static const List<int> _sha256Initial = [
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19,
  ];

  static const List<int> _sha256State = [
    0xFD9FBEA2,
    0x91243CE7,
    0xBE499094,
    0xCD2E1E0A,
    0x6C006F49,
    0x04BD35AB,
    0xFEB0A7E4,
    0x03EFFBD2,
  ];

  static const List<int> _sha256Schedule = [
    0xEB24BF9E,
    0x1558691F,
    0xA0C09EE2,
    0x0CFA32BA,
    0xA622EE8C,
    0xD1DD9491,
    0xC0DD25A0,
    0xF9E70AB6,
    0xF0C31573,
    0x7058CE4E,
    0x7188E606,
    0x00E5AB33,
    0xD258B060,
    0x72766564,
  ];

  static const List<int> _sha256RoundConstants = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
  ];

  static const int _sha256Adjustment = 0xC9DC06A7;
  static const int _sha256Sigma0Adjustment = 0x059C0B80;
  static const int _sha256Sigma1Adjustment = 0x000B92C0;

  static final List<int> _sha256BlockConstants = [
    ..._sha256RoundConstants.sublist(0, 14),
    _sha256Adjustment,
    ..._sha256RoundConstants.sublist(15),
  ];

  static const List<List<int>> _cs64Coefficients = [
    [0xE82E91B1, 0xB32700D0],
    [0x44DE24C6, 0x88DFF51D],
    [0x3BEB65BC, 0x29514038],
    [0xC89C5933, 0xB328CBDF],
    [0x8D1EC211, 0xD405B4D5],
    [0x314EF5D5, 0x26E55F3C],
    [0xE92491B1, 0x607801C6],
    [0xF0A5B9D5, 0x82B2C1FB],
    [0x06064CF3, 0xFA51A3DA],
    [0xDA79FA60, 0x207CC464],
    [0xBED20560, 0x3C3C74F3],
    [0x89F9C9F8, 0xD2D14B61],
    [0x35FA38C6, 0xBB04A2C1],
    [0xCB49E3C6, 0xC5626167],
  ];

  static const int _cs64Factor = 0x82893933;
  static const int _cs64Adjustment0 = 0xF2F90B1A;
  static const int _cs64Adjustment1 = 0x0B1A0000;

  static double clockSkewSeconds = 0.0;
  static final Random _rng = Random.secure();

  static int _rotr32(int value, int shift) {
    final v = value & _u32Mask;
    return ((v >>> shift) | (v << (32 - shift))) & _u32Mask;
  }

  static int _rol16(int value) {
    final v = value & _u32Mask;
    return ((v << 16) | (v >>> 16)) & _u32Mask;
  }

  static int _sigma0(int value) {
    return (_rotr32(value, 7) ^ _rotr32(value, 18) ^ ((value & _u32Mask) >>> 3)) &
        _u32Mask;
  }

  static int _sigma1(int value) {
    return (_rotr32(value, 17) ^
            _rotr32(value, 19) ^
            ((value & _u32Mask) >>> 10)) &
        _u32Mask;
  }

  static int _bigSigma0(int value) {
    return (_rotr32(value, 2) ^ _rotr32(value, 13) ^ _rotr32(value, 22)) &
        _u32Mask;
  }

  static int _bigSigma1(int value) {
    return (_rotr32(value, 6) ^ _rotr32(value, 11) ^ _rotr32(value, 25)) &
        _u32Mask;
  }

  static List<int> _sha256Rounds(
    List<int> state,
    List<int> words, [
    int firstRound = 0,
  ]) {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];
    final constants =
        firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;

    for (var i = firstRound; i < 64; i++) {
      final t1 = (h +
              _bigSigma1(e) +
              (g ^ (e & (f ^ g))) +
              constants[i] +
              words[i]) &
          _u32Mask;
      final t2 = (_bigSigma0(a) + ((a & b) | (c & (a | b)))) & _u32Mask;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _u32Mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _u32Mask;
    }
    return [a, b, c, d, e, f, g, h];
  }

  static void _expandSchedule(List<int> words, [int firstWord = 16]) {
    for (var i = firstWord; i < 64; i++) {
      final x = words[i - 2];
      final y = words[i - 15];
      words.add(
        (_sigma1(x) + words[i - 7] + _sigma0(y) + words[i - 16]) & _u32Mask,
      );
    }
  }

  static int _readUint32BE(Uint8List b, int offset) =>
      ((b[offset] & 0xFF) << 24) |
      ((b[offset + 1] & 0xFF) << 16) |
      ((b[offset + 2] & 0xFF) << 8) |
      (b[offset + 3] & 0xFF);

  static int _readUint32LE(Uint8List b, int offset) =>
      (b[offset] & 0xFF) |
      ((b[offset + 1] & 0xFF) << 8) |
      ((b[offset + 2] & 0xFF) << 16) |
      ((b[offset + 3] & 0xFF) << 24);

  static List<int> _sha256Init(Uint8List prefix7) {
    final words = List<int>.filled(14, 0, growable: true);
    words.add(((prefix7[0] << 16) | (prefix7[1] << 8) | prefix7[2]) & _u32Mask);
    words.add(_readUint32BE(prefix7, 3));

    for (var i = 16; i < 30; i++) {
      var v = _sha256Schedule[i - 16];
      if (i - 2 >= 14) {
        v += i == 16
            ? (_sigma1(words[i - 2]) ^ _sha256Sigma1Adjustment)
            : _sigma1(words[i - 2]);
      }
      if (i - 7 >= 14) {
        v += words[i - 7];
      }
      if (i - 15 >= 14) {
        v += i == 29
            ? (_sigma0(words[i - 15]) ^ _sha256Sigma0Adjustment)
            : _sigma0(words[i - 15]);
      }
      words.add(v & _u32Mask);
    }

    words.add(
      (_sigma1(words[28]) +
              words[23] +
              _sigma0(words[15]) +
              words[14] +
              _sha256Adjustment -
              _sha256RoundConstants[14]) &
          _u32Mask,
    );
    _expandSchedule(words, 31);
    final working = _sha256Rounds(_sha256State, words, 14);
    return List<int>.generate(
      8,
      (i) => (_sha256Initial[i] + working[i]) & _u32Mask,
    );
  }

  static Uint8List _sha256Digest(Uint8List data) {
    final lengthBytes = 57 + data.length;
    final tail = data.sublist(7);
    final padZeroLen = (55 - lengthBytes) % 64;
    final padLen = padZeroLen < 0 ? padZeroLen + 64 : padZeroLen;
    final totalBitLen = lengthBytes * 8;

    final padded = BytesBuilder(copy: false)
      ..add(tail)
      ..addByte(0x80)
      ..add(Uint8List(padLen))
      ..add([
        (totalBitLen >> 56) & 0xFF,
        (totalBitLen >> 48) & 0xFF,
        (totalBitLen >> 40) & 0xFF,
        (totalBitLen >> 32) & 0xFF,
        (totalBitLen >> 24) & 0xFF,
        (totalBitLen >> 16) & 0xFF,
        (totalBitLen >> 8) & 0xFF,
        totalBitLen & 0xFF,
      ]);
    final paddedBytes = padded.takeBytes();

    var state = _sha256Init(Uint8List.sublistView(data, 0, 7));
    for (var offset = 0; offset < paddedBytes.length; offset += 64) {
      final words = List<int>.generate(
        16,
        (i) => _readUint32BE(paddedBytes, offset + i * 4),
        growable: true,
      );
      _expandSchedule(words);
      final working = _sha256Rounds(state, words);
      for (var i = 0; i < 8; i++) {
        state[i] = (state[i] + working[i]) & _u32Mask;
      }
    }

    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      final w = state[i];
      out[i * 4] = (w >>> 24) & 0xFF;
      out[i * 4 + 1] = (w >>> 16) & 0xFF;
      out[i * 4 + 2] = (w >>> 8) & 0xFF;
      out[i * 4 + 3] = w & 0xFF;
    }
    return out;
  }

  static List<int> _wordsLe4Even(Uint8List data) {
    final rem = (-data.length) % 4;
    final padCount = rem < 0 ? rem + 4 : rem;
    final padded = Uint8List(data.length + padCount)..setRange(0, data.length, data);
    final words = <int>[
      for (var i = 0; i < padded.length; i += 4) _readUint32LE(padded, i),
    ];
    if (words.length.isOdd) {
      words.add(0);
    }
    return words;
  }

  static List<int> _cs64Digest(Uint8List data, Uint8List digest) {
    final keyA = _readUint32LE(digest, 0) | 1;
    final keyB = _readUint32LE(digest, 4) | 1;
    final factors = [
      (keyA * _cs64Factor) & _u32Mask,
      (keyB * _cs64Factor) & _u32Mask,
    ];
    final terms = <int>[
      for (var i = 0; i < _cs64Coefficients.length; i++)
        (_cs64Coefficients[i][0] * factors[i % 2]) & _u32Mask,
    ];
    final offsets = <int>[
      for (final c in _cs64Coefficients) c[1],
    ];

    final prefixed = Uint8List(data.length + 1)..setRange(1, data.length + 1, data);
    final words = _wordsLe4Even(prefixed);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      var term = (w * (i.isEven ? keyA : keyB)) & _u32Mask;
      var offset =
          (_rol16(w) * (i.isEven ? 0xEF0569FB : 0xC31713DB)) & _u32Mask;
      if (i == 0) {
        term = (term + _cs64Adjustment0 * factors[0]) & _u32Mask;
        offset = (offset + _cs64Adjustment1) & _u32Mask;
      }
      terms.add(term);
      offsets.add(offset);
    }

    var swapAcc = 0;
    var swapLast = 0;
    var state = 0;
    var acc = 0;
    for (var i = 0; i < terms.length; i += 2) {
      final x = terms[i];
      final y = terms[i + 1];

      var t = _rol16((offsets[i] + x) & _u32Mask);
      var q = (t * 0x76F50F34) & _u32Mask;
      swapAcc = (swapAcc + ((_rol16(q) * 0xC3EFEA97 + q) & _u32Mask)) & _u32Mask;

      t = _rol16((offsets[i + 1] + y) & _u32Mask);
      q = (t * 0x1881CE3C) & _u32Mask;
      swapLast = (_rol16(q) * 0x35BD1EC9 + q) & _u32Mask;
      swapAcc = (swapAcc + swapLast) & _u32Mask;

      state = (state * keyA + x) & _u32Mask;
      state = (_rol16(state) * 0xCF98B111) & _u32Mask;
      state = (_rol16(state) * 0x87085B9F) & _u32Mask;
      state = (_rol16(state) * 0x12CEB96D) & _u32Mask;
      state = (_rol16(state) * 0x257E1D83) & _u32Mask;
      acc = (acc + state) & _u32Mask;

      t = (state * keyB + y) & _u32Mask;
      t = (_rol16(t) * 0xA27416F5) & _u32Mask;
      t = (_rol16(t) * 0xD38396FF) & _u32Mask;
      state = (_rol16((_rol16(t) * 0x7C932B89) & _u32Mask) * 0xBFA49F69) &
          _u32Mask;
      acc = (acc + state) & _u32Mask;
    }
    return [(swapLast ^ state) & _u32Mask, (swapAcc ^ acc) & _u32Mask];
  }

  static String _toUpperHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }

  /// Generates a v2 Sec-MS-GEC token (`<16 hex CS64>-<64 hex SHA256>`).
  static String generateSecMsGecV2({double? unixTimestampSeconds}) {
    var ticks = unixTimestampSeconds ??
        (DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0 +
            clockSkewSeconds);
    ticks += _winEpochSeconds;
    ticks -= ticks % 300;
    final ticks100ns = (ticks * 10000000).round();
    final strToHash =
        Uint8List.fromList(ascii.encode('$ticks100ns$trustedClientToken'));

    final sha = _sha256Digest(strToHash);
    final csWords = _cs64Digest(strToHash, sha);
    final csBytes = Uint8List(8)
      ..[0] = csWords[0] & 0xFF
      ..[1] = (csWords[0] >>> 8) & 0xFF
      ..[2] = (csWords[0] >>> 16) & 0xFF
      ..[3] = (csWords[0] >>> 24) & 0xFF
      ..[4] = csWords[1] & 0xFF
      ..[5] = (csWords[1] >>> 8) & 0xFF
      ..[6] = (csWords[1] >>> 16) & 0xFF
      ..[7] = (csWords[1] >>> 24) & 0xFF;

    return '${_toUpperHex(csBytes)}-${_toUpperHex(sha)}';
  }

  static String generateRandomHex(int byteLength) {
    final sb = StringBuffer();
    for (var i = 0; i < byteLength; i++) {
      sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uri buildWssUri() {
    final gec = generateSecMsGecV2();
    final connId = generateRandomHex(16);
    return Uri.parse(
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
      '?TrustedClientToken=$trustedClientToken'
      '&Sec-MS-GEC=$gec'
      '&Sec-MS-GEC-Version=$secMsGecVersion'
      '&ConnectionId=$connId',
    );
  }

  static Map<String, dynamic> buildWssHeaders() {
    final muid = generateRandomHex(16).toUpperCase();
    return {
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
      'Origin': origin,
      'User-Agent': userAgent,
      'Cookie': 'muid=$muid;',
    };
  }

  /// Connects to the Edge Neural TTS WebSocket preserving Title-Case headers
  /// (required by Microsoft Edge endpoint) and adjusts [clockSkewSeconds] if needed.
  static Future<WebSocket> connectWebSocket({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final wssUri = buildWssUri();
      final httpsUri = wssUri.replace(scheme: 'https');
      final req = await client.openUrl('GET', httpsUri).timeout(timeout);

      final keyBytes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        keyBytes[i] = _rng.nextInt(256);
      }
      final wsKey = base64Encode(keyBytes);

      req.headers.set('Host', httpsUri.host, preserveHeaderCase: true);
      req.headers.set('Connection', 'Upgrade', preserveHeaderCase: true);
      req.headers.set('Upgrade', 'websocket', preserveHeaderCase: true);
      req.headers.set('Sec-WebSocket-Key', wsKey, preserveHeaderCase: true);
      req.headers.set('Sec-WebSocket-Version', '13', preserveHeaderCase: true);
      req.headers.set('Pragma', 'no-cache', preserveHeaderCase: true);
      req.headers.set('Cache-Control', 'no-cache', preserveHeaderCase: true);
      req.headers.set('Origin', origin, preserveHeaderCase: true);
      req.headers.set('User-Agent', userAgent, preserveHeaderCase: true);
      req.headers.set(
        'Cookie',
        'muid=${generateRandomHex(16).toUpperCase()};',
        preserveHeaderCase: true,
      );

      final res = await req.close().timeout(timeout);
      if (res.statusCode != 101) {
        final serverDate = res.headers.value('date');
        if (serverDate != null) {
          try {
            final serverSec =
                HttpDate.parse(serverDate).toUtc().millisecondsSinceEpoch /
                    1000.0;
            final localSec =
                DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0;
            clockSkewSeconds = serverSec - localSec;
          } catch (_) {}
        }
        throw WebSocketException(
          'Edge TTS handshake failed with HTTP ${res.statusCode} ${res.reasonPhrase}',
        );
      }

      final socket = await res.detachSocket();
      return WebSocket.fromUpgradedSocket(socket, serverSide: false);
    } finally {
      client.close(force: false);
    }
  }
}
