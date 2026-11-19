import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/tutor_models.dart';
import 'app_storage.dart';
import 'gemini_service.dart';

class DetectedGoogleAccount {
  final String email;
  final String displayName;
  final String? photoUrl;
  final String source; // 'saved', 'chrome', 'edge', 'brave', 'android'

  const DetectedGoogleAccount({
    required this.email,
    required this.displayName,
    this.photoUrl,
    this.source = 'saved',
  });

  String get sourceLabel {
    switch (source) {
      case 'chrome':
        return 'Chrome';
      case 'edge':
        return 'Edge';
      case 'brave':
        return 'Brave';
      case 'android':
        return 'Android';
      default:
        return 'محفوظ';
    }
  }

  Map<String, dynamic> toJson() => {
        'email': email,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'source': source,
      };

  factory DetectedGoogleAccount.fromJson(Map<String, dynamic> json) {
    final email = (json['email'] ?? '').toString().trim();
    final name = (json['displayName'] ?? '').toString().trim();
    return DetectedGoogleAccount(
      email: email,
      displayName: name.isNotEmpty ? name : email.split('@').first,
      photoUrl: json['photoUrl']?.toString(),
      source: (json['source'] ?? 'saved').toString(),
    );
  }
}

class GoogleAuthService {
  static const MethodChannel _platformChannel =
      MethodChannel('com.kidstutor/tts_audio');

  final Directory? overrideStorageDir;

  GoogleAuthService({this.overrideStorageDir});

  File _getStorageFile() {
    final dir = AppStorage.getRootDir(overrideDir: overrideStorageDir);
    return File('${dir.path}${Platform.pathSeparator}session.json');
  }

  Future<Map<String, dynamic>> _readStore() async {
    try {
      final file = _getStorageFile();
      if (!file.existsSync()) return {};
      final content = file.readAsStringSync();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeStore(Map<String, dynamic> data) async {
    try {
      final file = _getStorageFile();
      file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  Future<UserSession?> loadSavedSession() async {
    final store = await _readStore();
    final email = store['user_email']?.toString();
    if (email == null || email.trim().isEmpty) {
      return null;
    }
    return UserSession(
      email: email,
      displayName:
          store['user_name']?.toString() ?? email.split('@').first,
      photoUrl: store['user_photo']?.toString(),
      apiKey: GeminiService.defaultTestApiKey,
      googleAccessToken: store['google_access_token']?.toString(),
      useOAuthTokenForGemini: store['use_oauth_for_gemini'] == true,
    );
  }

  Future<String?> loadSavedClientId() async {
    final store = await _readStore();
    return store['google_oauth_client_id']?.toString();
  }

  Future<void> saveClientId(String clientId) async {
    final store = await _readStore();
    store['google_oauth_client_id'] = clientId.trim();
    await _writeStore(store);
  }

  Future<void> saveSession(UserSession session) async {
    final store = await _readStore();
    store['user_email'] = session.email;
    store['user_name'] = session.displayName;
    store['user_photo'] = session.photoUrl;
    store.remove('gemini_api_key');
    store['google_access_token'] = session.googleAccessToken;
    store['use_oauth_for_gemini'] = session.useOAuthTokenForGemini;

    final rawKnown = (store['known_accounts'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DetectedGoogleAccount.fromJson)
        .toList();
    final normEmail = session.email.trim().toLowerCase();
    final updatedKnown = <DetectedGoogleAccount>[
      DetectedGoogleAccount(
        email: session.email.trim(),
        displayName: session.displayName.trim().isNotEmpty
            ? session.displayName.trim()
            : session.email.split('@').first,
        photoUrl: session.photoUrl,
        source: 'saved',
      ),
      ...rawKnown.where((a) => a.email.trim().toLowerCase() != normEmail),
    ];
    store['known_accounts'] = updatedKnown.map((a) => a.toJson()).toList();

    await _writeStore(store);
  }

  /// Detects Google/Gmail accounts stored in the app or signed into local browsers (Chrome/Edge/Brave) on Windows.
  Future<List<DetectedGoogleAccount>> detectDeviceGoogleAccounts({
    bool includeWindowsBrowsers = true,
  }) async {
    final byEmail = <String, DetectedGoogleAccount>{};

    // 1. Saved accounts from previous logins
    final store = await _readStore();
    final rawKnown = store['known_accounts'] as List<dynamic>? ?? const [];
    for (final item in rawKnown) {
      if (item is Map<String, dynamic>) {
        final acct = DetectedGoogleAccount.fromJson(item);
        if (acct.email.contains('@')) {
          byEmail[acct.email.toLowerCase()] = acct;
        }
      }
    }

    // 2. Local Chrome / Edge / Brave profiles on Windows Desktop
    if (includeWindowsBrowsers && Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      if (localAppData.isNotEmpty) {
        final browsers = <String, String>{
          'chrome':
              '$localAppData${Platform.pathSeparator}Google${Platform.pathSeparator}Chrome${Platform.pathSeparator}User Data',
          'edge':
              '$localAppData${Platform.pathSeparator}Microsoft${Platform.pathSeparator}Edge${Platform.pathSeparator}User Data',
          'brave':
              '$localAppData${Platform.pathSeparator}BraveSoftware${Platform.pathSeparator}Brave-Browser${Platform.pathSeparator}User Data',
        };

        for (final entry in browsers.entries) {
          final source = entry.key;
          final userDataDir = entry.value;

          // Read "Local State" profile cache
          try {
            final localStateFile =
                File('$userDataDir${Platform.pathSeparator}Local State');
            if (localStateFile.existsSync()) {
              final decoded =
                  jsonDecode(localStateFile.readAsStringSync())
                      as Map<String, dynamic>;
              final profileMap = decoded['profile'] as Map<String, dynamic>?;
              final infoCache =
                  profileMap?['info_cache'] as Map<String, dynamic>?;
              if (infoCache != null) {
                for (final prof in infoCache.values) {
                  if (prof is Map<String, dynamic>) {
                    final email = (prof['user_name'] ?? '').toString().trim();
                    if (!email.contains('@')) continue;
                    final gaiaName =
                        (prof['gaia_name'] ?? prof['name'] ?? '')
                            .toString()
                            .trim();
                    final key = email.toLowerCase();
                    byEmail.putIfAbsent(
                      key,
                      () => DetectedGoogleAccount(
                        email: email,
                        displayName: gaiaName.isNotEmpty
                            ? gaiaName
                            : email.split('@').first,
                        source: source,
                      ),
                    );
                  }
                }
              }
            }
          } catch (_) {}

          // Enrich from Default and Profile 1 Preferences account_info
          for (final profileDir in const ['Default', 'Profile 1', 'Profile 2']) {
            try {
              final prefsFile = File(
                '$userDataDir${Platform.pathSeparator}$profileDir${Platform.pathSeparator}Preferences',
              );
              if (!prefsFile.existsSync()) continue;
              final decoded =
                  jsonDecode(prefsFile.readAsStringSync())
                      as Map<String, dynamic>;
              final accountInfo =
                  decoded['account_info'] as List<dynamic>? ?? const [];
              for (final acc in accountInfo) {
                if (acc is Map<String, dynamic>) {
                  final email = (acc['email'] ?? '').toString().trim();
                  if (!email.contains('@')) continue;
                  final fullName =
                      (acc['full_name'] ?? '').toString().trim();
                  final pictureUrl = acc['picture_url']?.toString();
                  final key = email.toLowerCase();
                  final existing = byEmail[key];
                  if (existing == null) {
                    byEmail[key] = DetectedGoogleAccount(
                      email: email,
                      displayName: fullName.isNotEmpty
                          ? fullName
                          : email.split('@').first,
                      photoUrl: pictureUrl,
                      source: source,
                    );
                  } else if (existing.photoUrl == null && pictureUrl != null) {
                    byEmail[key] = DetectedGoogleAccount(
                      email: existing.email,
                      displayName: fullName.isNotEmpty
                          ? fullName
                          : existing.displayName,
                      photoUrl: pictureUrl,
                      source: existing.source,
                    );
                  }
                }
              }
            } catch (_) {}
          }
        }
      }
    }

    return byEmail.values.toList();
  }

  /// Launches Android's native system Google account picker (`AccountManager`).
  Future<DetectedGoogleAccount?> pickAndroidSystemGoogleAccount() async {
    if (!Platform.isAndroid) return null;
    try {
      final email =
          await _platformChannel.invokeMethod<String>('pickGoogleAccount');
      if (email != null && email.trim().contains('@')) {
        final cleanEmail = email.trim();
        return DetectedGoogleAccount(
          email: cleanEmail,
          displayName: cleanEmail.split('@').first,
          source: 'android',
        );
      }
    } catch (_) {}
    return null;
  }

  Future<void> signOut() async {
    final store = await _readStore();
    store.remove('user_email');
    store.remove('user_name');
    store.remove('user_photo');
    store.remove('google_access_token');
    store.remove('use_oauth_for_gemini');
    await _writeStore(store);
  }

  /// Opens a URL in the system default browser without requiring native symlink plugins.
  Future<bool> openUrlInSystemBrowser(String url) async {
    try {
      if (Platform.isWindows) {
        final escaped = url.replaceAll('&', '^&');
        await Process.run('cmd', ['/c', 'start', '', escaped]);
        return true;
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
        return true;
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Fetches Google UserInfo (`email`, `name`, `picture`) using an OAuth 2.0 Access Token.
  Future<Map<String, dynamic>> fetchGoogleUserProfile(String accessToken) async {
    final res = await http
        .get(
          Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
          headers: {'Authorization': 'Bearer ${accessToken.trim()}'},
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('فشل التحقق من رمز جوجل (${res.statusCode})');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Launches a browser-based Google OAuth 2.0 Loopback flow on Desktop
  /// when a Google Cloud OAuth Client ID is provided.
  Future<UserSession> signInWithGoogleOAuthBrowser({
    required String googleClientId,
    required String fallbackApiKey,
    bool useOAuthTokenForGemini = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://localhost:${server.port}';
    final completer = Completer<String>();

    server.listen((HttpRequest request) async {
      final path = request.uri.path;
      if (path == '/token') {
        final token = request.uri.queryParameters['access_token'];
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
<!DOCTYPE html>
<html dir="rtl" lang="ar">
<head><meta charset="utf-8"><title>تم تسجيل الدخول</title></head>
<body style="font-family: sans-serif; text-align: center; padding-top: 60px; background: #f0fdf4;">
  <h2 style="color: #166534;">تم تسجيل الدخول بحساب جوجل بنجاح!</h2>
  <p>يمكنك الآن إغلاق هذه النافذة والعودة إلى تطبيق المعلم الذكي.</p>
</body>
</html>
''');
        await request.response.close();
        if (!completer.isCompleted) {
          if (token != null && token.isNotEmpty) {
            completer.complete(token);
          } else {
            completer.completeError(
              Exception('لم يتم استلام رمز الدخول من جوجل.'),
            );
          }
        }
        await server.close();
      } else {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>جاري تسجيل الدخول...</title></head>
<body>
<script>
  const hash = window.location.hash.substring(1);
  const params = new URLSearchParams(hash);
  const token = params.get('access_token');
  if (token) {
    window.location.replace('/token?access_token=' + encodeURIComponent(token));
  } else {
    document.body.innerHTML = '<h3>تعذر قراءة رمز الدخول من جوجل.</h3>';
  }
</script>
</body></html>
''');
        await request.response.close();
      }
    });

    final scopes = [
      'openid',
      'email',
      'profile',
      'https://www.googleapis.com/auth/drive.file',
      if (useOAuthTokenForGemini)
        'https://www.googleapis.com/auth/generative-language.retriever',
    ].join(' ');

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': googleClientId.trim(),
      'redirect_uri': redirectUri,
      'response_type': 'token',
      'scope': scopes,
      'prompt': 'select_account',
    });

    final launched = await openUrlInSystemBrowser(authUrl.toString());
    if (!launched) {
      await server.close(force: true);
      throw Exception('تعذر فتح المتصفح لتسجيل الدخول بحساب جوجل.');
    }

    final accessToken = await completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        server.close(force: true);
        throw Exception('انتهت مهلة تسجيل الدخول بحساب جوجل.');
      },
    );

    final profile = await fetchGoogleUserProfile(accessToken);
    final session = UserSession(
      email: (profile['email'] ?? 'user@gmail.com').toString(),
      displayName: (profile['name'] ?? 'طالب ذكي').toString(),
      photoUrl: profile['picture']?.toString(),
      apiKey: fallbackApiKey.trim().isNotEmpty
          ? fallbackApiKey.trim()
          : GeminiService.defaultTestApiKey,
      googleAccessToken: accessToken,
      useOAuthTokenForGemini: useOAuthTokenForGemini,
    );
    await saveSession(session);
    return session;
  }

  /// Best-effort backup of an uploaded PDF to the signed-in user's Google Drive (`drive.file` scope).
  Future<String?> backupPdfToGoogleDrive({
    required String accessToken,
    required String filename,
    required List<int> bytes,
  }) async {
    try {
      final boundary =
          'kids_ai_tutor_boundary_${DateTime.now().millisecondsSinceEpoch}';
      final metadataJson = jsonEncode({
        'name': filename,
        'mimeType': 'application/pdf',
      });

      final bodyBuilder = BytesBuilder();
      bodyBuilder.add(
        utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadataJson\r\n'
          '--$boundary\r\nContent-Type: application/pdf\r\n\r\n',
        ),
      );
      bodyBuilder.add(bytes);
      bodyBuilder.add(utf8.encode('\r\n--$boundary--\r\n'));

      final res = await http
          .post(
            Uri.parse(
              'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
            ),
            headers: {
              'Authorization': 'Bearer ${accessToken.trim()}',
              'Content-Type': 'multipart/related; boundary=$boundary',
            },
            body: bodyBuilder.toBytes(),
          )
          .timeout(const Duration(minutes: 2));

      if (res.statusCode == 200) {
        final jsonMap =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        return jsonMap['id']?.toString();
      }
    } catch (_) {}
    return null;
  }
}
