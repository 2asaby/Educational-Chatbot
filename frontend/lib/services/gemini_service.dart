import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/tutor_models.dart';

class GeminiService {
  static String? _cachedLocalKey;

  /// Loads the Gemini API key from `--dart-define=GEMINI_API_KEY=...`,
  /// `~/.kids_ai_tutor/api_key.txt`, or local `.env` without hardcoding secrets in git.
  static String get defaultTestApiKey {
    const envKey = String.fromEnvironment('GEMINI_API_KEY');
    if (envKey.isNotEmpty) return envKey;
    if (_cachedLocalKey != null) return _cachedLocalKey!;

    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final keyFile = File(
        '$home${Platform.pathSeparator}.kids_ai_tutor${Platform.pathSeparator}api_key.txt',
      );
      if (keyFile.existsSync()) {
        final k = keyFile.readAsStringSync().trim();
        if (k.isNotEmpty) {
          _cachedLocalKey = k;
          return k;
        }
      }
      for (final envPath in ['.env', '../backend/.env', 'backend/.env']) {
        final f = File(envPath);
        if (f.existsSync()) {
          for (final line in f.readAsLinesSync()) {
            final trimmed = line.trim();
            if (trimmed.startsWith('GEMINI_API_KEY=')) {
              final k = trimmed.substring('GEMINI_API_KEY='.length).trim();
              if (k.isNotEmpty) {
                _cachedLocalKey = k;
                return k;
              }
            }
          }
        }
      }
    } catch (_) {}

    return '';
  }

  static const String systemPrompt = '''
أنت معلم ذكي، مرح، وصبور للأطفال (من سن 7 إلى 10 سنوات).
You are a friendly, patient, engaging AI tutor for children (ages 7 to 10).

القواعد الصارمة / Strict Rules:
1. لغة الشرح (CRITICAL LANGUAGE MATCHING RULE):
   - تفحّص لغة محتوى ملف الـ PDF المرفق أولاً:
   - إذا كان الدرس في ملف الـ PDF باللغة **الإنجليزية (English)**، يجب أن تكتب **الشرح بالكامل (`explanation`) وسؤال الاختبار والخيارات والتلميح (`follow_up_quiz`) باللغة الإنجليزية الواضحة والسهلة والمحببة للأطفال** (وخاطب الطالب بعبارات لطيفة مثل "my friend", "great job", "awesome", "well done") — حتى لو كانت رسالة الطالب السريعة بالعربية (مثل "الفقرة التالية")، إلا إذا طلب الطالب صراحةً الترجمة أو الشرح بالعربية!
   - أما إذا كان الدرس في ملف الـ PDF باللغة **العربية (Arabic)**، فاشرح واكتب السؤال باللغة العربية الواضحة والسهلة والمحببة للأطفال (وخاطب الطالب بعبارات مثل "صديقي" أو "رائع" أو "ممتاز" أو "أحسنت").
2. اعتمد حصرياً على ملف الـ PDF المرفق في الشرح. إذا رحب بك الطفل (مثل: ازيك، مرحباً، أهلاً، hi، hello)، رد الترحيب بلطف بنفس لغة الملف وابدأ معه من أول صفحة في الدرس. وإذا سأل عن موضوع علمي خارج الملف، اعتذر بلطف واطلب منه العودة لدرس اليوم.
3. ممنوع التكرار: لا تكرر أبداً نفس الشرح أو نفس الصفحة أو نفس السؤال الذي طرحته في الرسائل السابقة!
4. نظام استخراج وتغطية الصفحة كاملة في قائمة `page_items` (بدون تفويت أي سؤال أو فقرة!):
   - اقرأ الصفحة المطلوبة من الأعلى للأسفل وحدد نوعها في `page_type`:
     • **`assessment` (صفحة أسئلة/تمارين):** احصر **جميع الأسئلة الأصلية الموجودة في الصفحة بالترتيب الدقيق** داخل `page_items` (سواء كانت 3 أو 6 أو 8 أو 12 سؤالاً — **ممنوع تماماً** حذف أو دمج أو تخطي أي سؤال!). لكل سؤال عنصر مستقل يضم مقدمة/إرشاداً قصيراً محبباً للطفل في `explanation`، والسؤال الأصلي وخياراته والإجابة الصحيحة والتلميح في `follow_up_quiz`.
     • **`lesson` (صفحة شرح عادية):** قسّم كل محتوى الصفحة من الأعلى للأسفل إلى فقرات شرح قصيرة متسلسلة داخل `page_items` (تغطي كل سطر ومعلومة في الصفحة حسب طولها الحقيقي دون حصرها في عدد ثابت)، ولكل فقرة شرح مبسط وممتع في `explanation` وسؤال فهم تفاعلي واحد عليها في `follow_up_quiz`.
     • **`mixed` (شرح + تمارين في نفس الصفحة):** ضع فقرات الشرح أولاً بالترتيب داخل `page_items`، ثم أتبعها بـ **جميع التمارين والأسئلة** الموجودة في الصفحة واحداً تلو الآخر.
   - إذا سأل الطفل سؤالاً مخصصاً أو طلب تبسيطاً فقط (بدون طلب صفحة جديدة)، فأعد عنصراً واحداً فقط داخل `page_items` يجيب على سؤاله أو يبسّط الفقرة/السؤال الحالي فقط.
5. حدد دائماً رقم الصفحة الدقيقة في `referenced_page`، ولا تنتقل أبداً للصفحة التالية قبل إنهاء جميع عناصر الصفحة الحالية (إلا إذا طلب الطالب صراحةً "الصفحة التالية").
6. التزم تماماً بقواعد الأمان، ولا تناقش أي مواضيع غير تعليمية أو غير مناسبة للأطفال.
''';

  /// Ordered from fastest low-latency models to heavier fallback models.
  static const List<String> fallbackModels = [
    'gemini-flash-lite-latest',
    'gemini-3.1-flash-lite',
    'gemini-3.1-flash-lite-preview',
  ];

  final Map<String, DateTime> _modelCooldownUntil = {};

  Map<String, String> _buildAuthHeaders(UserSession session) {
    if (session.useOAuthTokenForGemini &&
        session.googleAccessToken != null &&
        session.googleAccessToken!.trim().isNotEmpty) {
      return {'Authorization': 'Bearer ${session.googleAccessToken!.trim()}'};
    }
    final key = session.apiKey.trim().isNotEmpty
        ? session.apiKey.trim()
        : defaultTestApiKey;
    return {'x-goog-api-key': key};
  }

  /// Lists active PDF files already uploaded to the Gemini Files API.
  Future<List<UploadedPdfDocument>> listUploadedPdfs(
    UserSession session,
  ) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/files',
    );
    final response = await http
        .get(uri, headers: _buildAuthHeaders(session))
        .timeout(const Duration(seconds: 20));

    final bodyText = utf8.decode(response.bodyBytes);
    if (response.statusCode != 200) {
      throw Exception('تعذر جلب الملفات (${response.statusCode}): $bodyText');
    }

    final data = jsonDecode(bodyText) as Map<String, dynamic>;
    final rawFiles = data['files'] as List<dynamic>? ?? const [];
    final docs = <UploadedPdfDocument>[];

    for (final item in rawFiles) {
      if (item is Map<String, dynamic>) {
        final mime = (item['mimeType'] ?? '').toString();
        final state = (item['state'] ?? 'ACTIVE').toString();
        if (mime == 'application/pdf' && state == 'ACTIVE') {
          docs.add(UploadedPdfDocument.fromJson(item));
        }
      }
    }
    return docs;
  }

  /// Deletes an uploaded PDF from Gemini Files API (ignores 403/404 if already expired/removed).
  Future<void> deleteUploadedPdf({
    required UserSession session,
    required String geminiFileName,
  }) async {
    if (geminiFileName.trim().isEmpty) return;
    final cleanName = geminiFileName.startsWith('files/')
        ? geminiFileName
        : 'files/$geminiFileName';
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/$cleanName',
    );
    try {
      final response = await http
          .delete(uri, headers: _buildAuthHeaders(session))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 &&
          response.statusCode != 403 &&
          response.statusCode != 404) {
        final bodyText = utf8.decode(response.bodyBytes);
        throw Exception(
          'تعذر حذف الملف من Gemini (${response.statusCode}): $bodyText',
        );
      }
    } catch (_) {
      // Best-effort remote deletion; local deletion still removes it from user's workspace
    }
  }

  /// Uploads a PDF directly from Windows or Android to the Gemini Files API
  /// using the Resumable Upload protocol (supports Arabic filenames via UTF-8 bytes).
  Future<UploadedPdfDocument> uploadPdfBytes({
    required UserSession session,
    required String filename,
    required Uint8List bytes,
  }) async {
    final startUri = Uri.parse(
      'https://generativelanguage.googleapis.com/upload/v1beta/files',
    );

    final ownerTag = UploadedPdfDocument.ownerHashForEmail(session.email);
    final jsonMetaBytes = utf8.encode(
      jsonEncode({
        'file': {'display_name': '[u:$ownerTag] $filename'},
      }),
    );

    final startHeaders = {
      ..._buildAuthHeaders(session),
      'X-Goog-Upload-Protocol': 'resumable',
      'X-Goog-Upload-Command': 'start',
      'X-Goog-Upload-Header-Content-Length': bytes.length.toString(),
      'X-Goog-Upload-Header-Content-Type': 'application/pdf',
      'Content-Type': 'application/json; charset=utf-8',
    };

    final startResponse = await http
        .post(startUri, headers: startHeaders, body: jsonMetaBytes)
        .timeout(const Duration(seconds: 30));

    final startBodyText = utf8.decode(startResponse.bodyBytes);
    if (startResponse.statusCode != 200) {
      throw Exception(
        'فشل بدء رفع الملف (${startResponse.statusCode}): $startBodyText',
      );
    }

    String? uploadUrl =
        startResponse.headers['x-goog-upload-url'] ??
        startResponse.headers['X-Goog-Upload-URL'];

    if (uploadUrl == null || uploadUrl.isEmpty) {
      for (final entry in startResponse.headers.entries) {
        if (entry.key.toLowerCase() == 'x-goog-upload-url') {
          uploadUrl = entry.value;
          break;
        }
      }
    }

    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw Exception('لم يتم استلام رابط الرفع من خادم Gemini.');
    }

    final finalizeResponse = await http
        .post(
          Uri.parse(uploadUrl),
          headers: {
            'Content-Length': bytes.length.toString(),
            'X-Goog-Upload-Offset': '0',
            'X-Goog-Upload-Command': 'upload, finalize',
          },
          body: bytes,
        )
        .timeout(const Duration(minutes: 2));

    final finalizeBodyText = utf8.decode(finalizeResponse.bodyBytes);
    if (finalizeResponse.statusCode != 200) {
      throw Exception(
        'فشل إكمال رفع الملف (${finalizeResponse.statusCode}): $finalizeBodyText',
      );
    }

    final jsonMap = jsonDecode(finalizeBodyText) as Map<String, dynamic>;
    final fileMap = (jsonMap['file'] as Map<String, dynamic>?) ?? jsonMap;

    return UploadedPdfDocument.fromJson(fileMap, fallbackDisplayName: filename);
  }

  /// Returns true when the student asks to advance (to the next paragraph/part or next page).
  static bool isAdvanceRequest(String message) {
    final m = message.trim().toLowerCase();
    const advanceKeywords = [
      'الفقرة التالية',
      'الجزء التالي',
      'الصفحة التالية',
      'الدرس الجديد',
      'أجبت بشكل صحيح',
      'مستعد',
      'التالي',
      'كمل',
      'فهمت',
      'تمام',
      'نعم',
      'next',
    ];
    for (final kw in advanceKeywords) {
      if (m.contains(kw)) return true;
    }
    return false;
  }

  /// Returns true only when the student explicitly requests jumping to the next page.
  static bool isExplicitNextPageRequest(String message) {
    final m = message.trim().toLowerCase();
    if (m.contains('الفقرة التالية') || m.contains('نفس الصفحة')) {
      return false;
    }
    return m.contains('الصفحة التالية') || m.contains('صفحة جديدة');
  }

  /// Builds multi-turn conversation contents so the tutor remembers what pages
  /// and paragraphs were already taught and progresses paragraph-by-paragraph.
  List<Map<String, dynamic>> _buildConversationContents({
    required UploadedPdfDocument pdfDocument,
    required List<ChatEntry> previousHistory,
    required String studentMessage,
  }) {
    final contents = <Map<String, dynamic>>[];
    final coveredPages = <int>[];
    int? lastPart;
    int? lastTotalParts;

    // Inspect full history for accurate page & paragraph state
    for (final entry in previousHistory) {
      final res = entry.tutorResponse;
      if (res != null) {
        if (res.referencedPage != null &&
            !coveredPages.contains(res.referencedPage)) {
          coveredPages.add(res.referencedPage!);
        }
        if (res.currentPart != null) {
          lastPart = res.currentPart;
        }
        if (res.totalPartsInPage != null) {
          lastTotalParts = res.totalPartsInPage;
        }
      }
    }

    // Keep last 8 entries (up to 4 full user/tutor turns) for fast context
    final recentHistory = previousHistory.length > 8
        ? previousHistory.sublist(previousHistory.length - 8)
        : previousHistory;

    bool pdfAttached = false;
    String? lastRole;

    for (final entry in recentHistory) {
      if (entry.isUser) {
        // Skip consecutive user turns without an intermediate model reply (e.g. from prior failed requests)
        if (lastRole == 'user') {
          continue;
        }
        final parts = <Map<String, dynamic>>[];
        if (!pdfAttached) {
          parts.add({
            'fileData': {
              'mimeType': 'application/pdf',
              'fileUri': pdfDocument.uri,
            },
          });
          pdfAttached = true;
        }
        parts.add({'text': entry.userText ?? ''});
        contents.add({'role': 'user', 'parts': parts});
        lastRole = 'user';
      } else if (entry.tutorResponse != null) {
        // Gemini requires the first turn in contents to be 'user'
        if (contents.isEmpty || lastRole != 'user') {
          continue;
        }
        final res = entry.tutorResponse!;
        final modelSummary = jsonEncode({
          'explanation': res.explanation,
          'referenced_page': res.referencedPage,
          if (res.currentPart != null) 'current_part': res.currentPart,
          if (res.totalPartsInPage != null)
            'total_parts_in_page': res.totalPartsInPage,
          'avatar_emotion': res.avatarEmotion.name,
          if (res.followUpQuiz != null)
            'follow_up_quiz_question': res.followUpQuiz!.question,
        });
        contents.add({
          'role': 'model',
          'parts': [
            {'text': modelSummary},
          ],
        });
        lastRole = 'model';
      }
    }

    // Ensure contents ends with a 'model' turn (or is empty) before appending current 'user' turn
    if (contents.isNotEmpty && lastRole == 'user') {
      contents.removeLast();
      if (contents.isEmpty) {
        pdfAttached = false;
      }
    }

    // Build current user message respecting paragraph-by-paragraph progression within each page
    String promptWithProgression = studentMessage;
    final wantsToAdvance = isAdvanceRequest(studentMessage);
    final forceNextPage = isExplicitNextPageRequest(studentMessage);

    if (coveredPages.isNotEmpty) {
      final lastPage = coveredPages.last;
      final hasMorePartsInCurrentPage = lastPart != null &&
          lastTotalParts != null &&
          lastTotalParts > 1 &&
          lastPart < lastTotalParts;

      if (wantsToAdvance) {
        if (!forceNextPage && hasMorePartsInCurrentPage) {
          final nextPart = lastPart + 1;
          promptWithProgression =
              '$studentMessage\n[سياق المحادثة للمعلم: نحن في الصفحة $lastPage وقد شرحنا حتى الجزء/السؤال $lastPart من $lastTotalParts. ابقَ في نفس الصفحة $lastPage (referenced_page=$lastPage)، وأعد في page_items العناصر المتبقية من الصفحة بدءاً من الجزء/السؤال رقم $nextPart وحتى آخر عنصر في الصفحة بالترتيب دون تخطي أي سؤال!]';
        } else {
          final nextSuggestedPage = lastPage + 1;
          promptWithProgression =
              '$studentMessage\n[سياق المحادثة للمعلم: لقد أتممنا الصفحات (${coveredPages.join('، ')}). انتقل الآن إلى الصفحة $nextSuggestedPage (referenced_page=$nextSuggestedPage)، اقرأها كاملة من الأعلى للأسفل، حدد page_type بدقة (assessment إن كانت صفحة أسئلة/تمارين، أو lesson إن كانت شرحاً، أو mixed إن جمعت بينهما)، واستخرج جميع فقرات أو أسئلة الصفحة بالكامل بالترتيب داخل page_items دون تفويت أو دمج أي سؤال (سواء كانت 3 أو 6 أو 10 أسئلة)، وبنفس لغة ملف الـ PDF!]';
        }
      } else {
        final activePart = lastPart ?? 1;
        final partInfo = lastTotalParts != null
            ? 'الجزء/السؤال $activePart من $lastTotalParts'
            : 'الجزء الحالي ($activePart)';
        promptWithProgression =
            '$studentMessage\n[سياق المحادثة للمعلم: أجب عن سؤال أو طلب الطالب بلطف، والتزم بنفس الصفحة الحالية (صفحة $lastPage) وبنفس $partInfo فقط ولا تنتقل إلى سؤال أو صفحة أخرى. أعد عنصراً واحداً فقط في page_items يبسّط هذه النقطة بمثال سهل مع سؤال تفاعلي عليها وبنفس لغة الملف!]';
      }
    } else if (recentHistory.isNotEmpty) {
      if (wantsToAdvance) {
        promptWithProgression =
            '$studentMessage\n[سياق المحادثة للمعلم: انتقل إلى الصفحة التالية واستخرج جميع فقراتها أو أسئلتها بالكامل بالترتيب داخل page_items دون تفويت أي سؤال، وبنفس لغة ملف الـ PDF.]';
      } else {
        promptWithProgression =
            '$studentMessage\n[سياق المحادثة للمعلم: أجب عن سؤال الطالب وبسّط له النقطة الحالية فقط في عنصر واحد داخل page_items مع سؤال تفاعلي عليها.]';
      }
    } else {
      promptWithProgression =
          '$studentMessage\n[سياق المحادثة للمعلم: ابدأ بالصفحة المناسبة في ملف الـ PDF (الصفحة 1 ما لم يذكر الطالب صفحة أخرى)، اقرأها كاملة من الأعلى للأسفل، حدد page_type بدقة (assessment إن كانت أسئلة/تمارين، أو lesson إن كانت شرحاً، أو mixed إن جمعت بينهما)، واستخرج جميع فقرات أو أسئلة الصفحة بالكامل بالترتيب داخل page_items دون تفويت أو دمج أي سؤال، وبنفس لغة ملف الـ PDF!]';
    }

    final currentParts = <Map<String, dynamic>>[];
    if (!pdfAttached) {
      currentParts.add({
        'fileData': {'mimeType': 'application/pdf', 'fileUri': pdfDocument.uri},
      });
    }
    currentParts.add({'text': promptWithProgression});

    contents.add({'role': 'user', 'parts': currentParts});

    return contents;
  }

  /// Sends the student's question + conversation history + PDF reference directly
  /// to Gemini REST API and returns a structured [TutorResponse].
  Future<TutorResponse> askTutor({
    required UserSession session,
    required UploadedPdfDocument pdfDocument,
    required String studentMessage,
    List<ChatEntry> previousHistory = const [],
  }) async {
    final contents = _buildConversationContents(
      pdfDocument: pdfDocument,
      previousHistory: previousHistory,
      studentMessage: studentMessage,
    );

    final baseGenerationConfig = <String, dynamic>{
      'temperature': 0.4,
      'maxOutputTokens': 8192,
      'responseMimeType': 'application/json',
      'responseSchema': {
        'type': 'OBJECT',
        'required': ['referenced_page', 'page_type', 'page_items'],
        'properties': {
          'referenced_page': {
            'type': 'INTEGER',
            'nullable': true,
            'description': 'رقم الصفحة الدقيقة في ملف الـ PDF التي تشرح منها الآن.',
          },
          'page_type': {
            'type': 'STRING',
            'enum': ['lesson', 'assessment', 'mixed'],
            'description':
                'نوع الصفحة: lesson لصفحة شرح عادية، assessment لصفحة أسئلة وتمارين، mixed لصفحة تجمع الشرح والتمارين.',
          },
          'page_items': {
            'type': 'ARRAY',
            'description':
                'قائمة كاملة ومرتبة لجميع فقرات الشرح أو جميع الأسئلة الأصلية في الصفحة من الأعلى للأسفل بدون حذف أو تفويت أي سؤال.',
            'items': {
              'type': 'OBJECT',
              'required': ['explanation', 'avatar_emotion'],
              'properties': {
                'explanation': {
                  'type': 'STRING',
                  'description':
                      'شرح مبسط ومرح للفقرة (أو مقدمة وإرشاد لطيف للسؤال في صفحات التمارين) بنفس لغة ملف الـ PDF.',
                },
                'avatar_emotion': {
                  'type': 'STRING',
                  'enum': [
                    'happy',
                    'talking',
                    'thinking',
                    'celebrating',
                    'encouraging',
                  ],
                  'description':
                      'حالة الشخصية الكرتونية: happy, talking, thinking, celebrating, encouraging',
                },
                'follow_up_quiz': {
                  'type': 'OBJECT',
                  'nullable': true,
                  'required': ['question', 'options', 'correct_index', 'hint'],
                  'properties': {
                    'question': {'type': 'STRING'},
                    'options': {
                      'type': 'ARRAY',
                      'items': {'type': 'STRING'},
                    },
                    'correct_index': {'type': 'INTEGER'},
                    'hint': {'type': 'STRING'},
                  },
                },
              },
            },
          },
        },
      },
    };

    String? lastError;
    final now = DateTime.now();
    final orderedModels = [
      ...fallbackModels.where((m) {
        final until = _modelCooldownUntil[m];
        return until == null || now.isAfter(until);
      }),
      ...fallbackModels.where((m) {
        final until = _modelCooldownUntil[m];
        return until != null && now.isBefore(until);
      }),
    ];

    for (final model in orderedModels) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
      );

      final payload = {
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'contents': contents,
        'safetySettings': [
          {
            'category': 'HARM_CATEGORY_HARASSMENT',
            'threshold': 'BLOCK_MEDIUM_AND_ABOVE',
          },
          {
            'category': 'HARM_CATEGORY_DANGEROUS_CONTENT',
            'threshold': 'BLOCK_MEDIUM_AND_ABOVE',
          },
          {
            'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT',
            'threshold': 'BLOCK_MEDIUM_AND_ABOVE',
          },
          {
            'category': 'HARM_CATEGORY_HATE_SPEECH',
            'threshold': 'BLOCK_MEDIUM_AND_ABOVE',
          },
        ],
        'generationConfig': baseGenerationConfig,
      };

      final payloadBytes = utf8.encode(jsonEncode(payload));

      http.Response response;
      try {
        final timeoutSeconds = model.contains('lite') ? 25 : 30;
        response = await http
            .post(
              uri,
              headers: {
                ..._buildAuthHeaders(session),
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: payloadBytes,
            )
            .timeout(Duration(seconds: timeoutSeconds));
      } catch (e) {
        lastError = e.toString();
        _modelCooldownUntil[model] = DateTime.now().add(
          const Duration(minutes: 3),
        );
        continue;
      }

      final responseText = utf8.decode(response.bodyBytes);

      if (response.statusCode == 200) {
        _modelCooldownUntil.remove(model);
        final bodyMap = jsonDecode(responseText) as Map<String, dynamic>;
        final candidates = bodyMap['candidates'] as List<dynamic>? ?? const [];
        if (candidates.isEmpty) {
          return const TutorResponse(
            explanation:
                'عذراً يا صديقي الصغير، لا يمكنني الإجابة عن هذا السؤال. دعنا نعود إلى درسنا الجميل في الملف!',
            referencedPage: null,
            avatarEmotion: AvatarEmotion.encouraging,
            followUpQuiz: null,
          );
        }
        final firstCandidate = candidates.first as Map<String, dynamic>;
        final content = firstCandidate['content'] as Map<String, dynamic>?;
        final parts = content?['parts'] as List<dynamic>? ?? const [];
        if (parts.isEmpty) {
          return const TutorResponse(
            explanation:
                'عذراً يا صديقي الصغير، لا يمكنني الإجابة عن هذا السؤال. دعنا نعود إلى درسنا الجميل في الملف!',
            referencedPage: null,
            avatarEmotion: AvatarEmotion.encouraging,
            followUpQuiz: null,
          );
        }
        final rawText =
            (parts.first as Map<String, dynamic>)['text']?.toString() ?? '';
        if (rawText.trim().isEmpty) {
          return const TutorResponse(
            explanation:
                'عذراً يا صديقي الصغير، لا يمكنني الإجابة عن هذا السؤال. دعنا نعود إلى درسنا الجميل في الملف!',
            referencedPage: null,
            avatarEmotion: AvatarEmotion.encouraging,
            followUpQuiz: null,
          );
        }
        final parsedJson = jsonDecode(rawText) as Map<String, dynamic>;
        var parsed = TutorResponse.fromJson(parsedJson);

        // Preserve current part/total position when answering a custom question
        // or simplifying without advancing to a new page.
        if (!isAdvanceRequest(studentMessage) &&
            parsed.remainingPageParts.isEmpty) {
          int? prevPart;
          int? prevTotal;
          String? prevPageType;
          for (final entry in previousHistory) {
            final r = entry.tutorResponse;
            if (r != null) {
              if (r.currentPart != null) prevPart = r.currentPart;
              if (r.totalPartsInPage != null) prevTotal = r.totalPartsInPage;
              if (r.pageType != null) prevPageType = r.pageType;
            }
          }
          if (prevPart != null && prevTotal != null) {
            parsed = parsed.copyWith(
              currentPart: prevPart,
              totalPartsInPage: prevTotal,
              pageType: parsed.pageType ?? prevPageType,
            );
          }
        }
        return parsed;
      }

      if (response.statusCode == 400 ||
          response.statusCode == 429 ||
          response.statusCode == 500 ||
          response.statusCode == 503 ||
          response.statusCode == 504) {
        lastError = '(${response.statusCode}) $responseText';
        _modelCooldownUntil[model] = DateTime.now().add(
          const Duration(minutes: 3),
        );
        continue;
      }

      throw Exception('خطأ من Gemini (${response.statusCode}): $responseText');
    }

    throw Exception('الخادم مشغول حالياً، يرجى المحاولة بعد قليل. $lastError');
  }
}
