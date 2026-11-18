import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_ai_tutor/main.dart';
import 'package:kids_ai_tutor/models/tutor_models.dart';
import 'package:kids_ai_tutor/services/gemini_service.dart';
import 'package:kids_ai_tutor/services/google_auth_service.dart';
import 'package:kids_ai_tutor/services/lesson_cache_service.dart';
import 'package:kids_ai_tutor/services/tts_service.dart';

void main() {
  test('TutorResponse parses structured JSON properly', () {
    final json = {
      'explanation': 'شرح قصصي مبسط للأطفال',
      'referenced_page': 2,
      'avatar_emotion': 'celebrating',
      'follow_up_quiz': {
        'question': 'ما هو الجواب؟',
        'options': ['أ', 'ب', 'ج'],
        'correct_index': 1,
        'hint': 'فكر جيداً!',
      },
    };
    final parsed = TutorResponse.fromJson(json);
    expect(parsed.explanation, 'شرح قصصي مبسط للأطفال');
    expect(parsed.referencedPage, 2);
    expect(parsed.avatarEmotion, AvatarEmotion.celebrating);
    expect(parsed.followUpQuiz?.correctIndex, 1);
    expect(parsed.followUpQuiz?.options.length, 3);
  });

  testWidgets('App renders login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const KidsAiTutorApp());
    await tester.pumpAndSettle();
    expect(find.text('المعلم الذكي للأطفال'), findsOneWidget);
  });

  test('LessonCacheService isolates documents and histories per Gmail user', () async {
    final tempDir = Directory.systemTemp.createTempSync('kids_ai_tutor_test_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final cache = LessonCacheService(overrideRootDir: tempDir);

    const doc1 = UploadedPdfDocument(
      name: 'files/doc_user1',
      displayName: 'درس العلوم.pdf',
      uri: 'https://generativelanguage.googleapis.com/v1beta/files/doc_user1',
      ownerEmail: 'user1@gmail.com',
    );
    const doc2 = UploadedPdfDocument(
      name: 'files/doc_user2',
      displayName: 'درس الرياضيات.pdf',
      uri: 'https://generativelanguage.googleapis.com/v1beta/files/doc_user2',
      ownerEmail: 'user2@gmail.com',
    );

    cache.saveCachedDocuments('user1@gmail.com', [doc1], selectedDocName: doc1.name);
    cache.saveCachedDocuments('user2@gmail.com', [doc2], selectedDocName: doc2.name);

    cache.saveChatHistory('user1@gmail.com', doc1.name, [ChatEntry.user('سؤال ١')]);
    cache.saveChatHistory('user2@gmail.com', doc2.name, [ChatEntry.user('سؤال ٢')]);

    final user1Docs = cache.loadCachedDocuments('USER1@gmail.com');
    final user2Docs = cache.loadCachedDocuments('user2@gmail.com');
    final user3Docs = cache.loadCachedDocuments('user3@gmail.com');

    expect(user1Docs.length, 1);
    expect(user1Docs.first.name, 'files/doc_user1');
    expect(cache.loadLastSelectedDocName('user1@gmail.com'), 'files/doc_user1');

    expect(user2Docs.length, 1);
    expect(user2Docs.first.name, 'files/doc_user2');
    expect(cache.loadLastSelectedDocName('user2@gmail.com'), 'files/doc_user2');

    expect(user3Docs, isEmpty);

    final user1History = cache.loadAllChatHistories('user1@gmail.com');
    final user2History = cache.loadAllChatHistories('user2@gmail.com');

    expect(user1History.containsKey('files/doc_user1'), isTrue);
    expect(user1History.containsKey('files/doc_user2'), isFalse);
    expect(user2History.containsKey('files/doc_user2'), isTrue);
    expect(user2History.containsKey('files/doc_user1'), isFalse);
  });

  test('DetectedGoogleAccount serializes and GoogleAuthService persists known accounts', () async {
    final tempDir = Directory.systemTemp.createTempSync('kids_ai_auth_test_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    const sample = DetectedGoogleAccount(
      email: 'hero@gmail.com',
      displayName: 'Hero Kid',
      source: 'chrome',
    );
    final roundTrip = DetectedGoogleAccount.fromJson(sample.toJson());
    expect(roundTrip.email, 'hero@gmail.com');
    expect(roundTrip.displayName, 'Hero Kid');
    expect(roundTrip.source, 'chrome');

    final authService = GoogleAuthService(overrideStorageDir: tempDir);
    await authService.saveSession(const UserSession(
      email: 'sara@gmail.com',
      displayName: 'سارة',
      apiKey: 'test-key',
    ));
    await authService.signOut();

    final detected = await authService.detectDeviceGoogleAccounts(
      includeWindowsBrowsers: false,
    );
    expect(detected.length, 1);
    expect(detected.first.email, 'sara@gmail.com');
    expect(detected.first.displayName, 'سارة');
  });

  test('LessonCacheService.deleteDocumentForUser removes only target doc, history, cache, and backup', () async {
    final tempDir = Directory.systemTemp.createTempSync('kids_ai_delete_test_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final cache = LessonCacheService(overrideRootDir: tempDir);
    const email = 'kid@gmail.com';
    final backupPath1 = await cache.saveLocalPdfBackup(
      userEmail: email,
      filename: 'lesson1.pdf',
      bytes: [1, 2, 3, 4],
    );
    final backupPath2 = await cache.saveLocalPdfBackup(
      userEmail: email,
      filename: 'lesson2.pdf',
      bytes: [5, 6, 7, 8],
    );

    final doc1 = UploadedPdfDocument(
      name: 'files/doc1',
      displayName: 'lesson1.pdf',
      uri: 'https://generativelanguage.googleapis.com/v1beta/files/doc1',
      localBackupPath: backupPath1,
      ownerEmail: email,
    );
    final doc2 = UploadedPdfDocument(
      name: 'files/doc2',
      displayName: 'lesson2.pdf',
      uri: 'https://generativelanguage.googleapis.com/v1beta/files/doc2',
      localBackupPath: backupPath2,
      ownerEmail: email,
    );

    cache.saveCachedDocuments(email, [doc1, doc2], selectedDocName: doc1.name);
    cache.saveChatHistory(email, doc1.name, [ChatEntry.user('سؤال 1')]);
    cache.saveChatHistory(email, doc2.name, [ChatEntry.user('سؤال 2')]);
    cache.savePreparedResponse(
      docName: doc1.name,
      lastCoveredPage: 0,
      prompt: 'سؤال 1',
      response: const TutorResponse(
        explanation: 'شرح 1',
        avatarEmotion: AvatarEmotion.happy,
      ),
    );
    cache.savePreparedResponse(
      docName: doc2.name,
      lastCoveredPage: 0,
      prompt: 'سؤال 2',
      response: const TutorResponse(
        explanation: 'شرح 2',
        avatarEmotion: AvatarEmotion.happy,
      ),
    );

    await cache.deleteDocumentForUser(userEmail: email, doc: doc1);

    final remaining = cache.loadCachedDocuments(email);
    expect(remaining.length, 1);
    expect(remaining.first.name, 'files/doc2');
    expect(cache.loadLastSelectedDocName(email), 'files/doc2');

    final histories = cache.loadAllChatHistories(email);
    expect(histories.containsKey(doc1.name), isFalse);
    expect(histories.containsKey(doc2.name), isTrue);

    expect(
      cache.getCachedResponse(docName: doc1.name, lastCoveredPage: 0, prompt: 'سؤال 1'),
      isNull,
    );
    expect(
      cache.getCachedResponse(docName: doc2.name, lastCoveredPage: 0, prompt: 'سؤال 2'),
      isNotNull,
    );

    expect(File(backupPath1).existsSync(), isFalse);
    expect(File(backupPath2).existsSync(), isTrue);
  });

  testWidgets('Login screen never exposes API key text', (WidgetTester tester) async {
    await tester.pumpWidget(const KidsAiTutorApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('AQ.Ab8'), findsNothing);
    expect(find.textContaining('مفتاح Gemini API'), findsNothing);
  });

  test('GeminiTtsService splits long Arabic text into short playable sentences', () {
    final tts = GeminiTtsService();
    const longText =
        'أهلاً يا صديقي! سنتعلم اليوم المد بالألف بطريقة سهلة وممتعة. عندما نضع الألف بعد الفتحة نطيل الصوت قليلاً مثل با وتا، هيا نجرب معاً ونقرأ الأمثلة الجديدة في الصفحة الرابعة!';
    final sentences = tts.splitIntoPlayableSentences(longText);
    expect(sentences.length, greaterThanOrEqualTo(2));
    expect(sentences.first.length, lessThan(115));
  });

  test('TutorResponse removes hero phrases while preserving real Arabic words', () {
    final parsed = TutorResponse.fromJson({
      'explanation':
          'أحسنت يا بطل! أنت بطل حقيقي في القراءة وتتعلم القراءة بطلاقة!',
      'referenced_page': 12,
      'avatar_emotion': 'happy',
      'follow_up_quiz': {
        'question': 'اختر الكلمة الصحيحة يا بطل؟',
        'options': ['أ', 'ب', 'ج'],
        'correct_index': 0,
        'hint': 'فكر جيداً يا بطل!',
      },
    });
    expect(parsed.explanation, contains('أحسنت!'));
    expect(parsed.explanation, contains('بطلاقة'));
    expect(parsed.explanation, isNot(contains('يا بطل')));
    expect(parsed.explanation, isNot(contains('بطل حقيقي')));
    expect(parsed.followUpQuiz!.question, isNot(contains('يا بطل')));
    expect(parsed.followUpQuiz!.hint, isNot(contains('يا بطل')));
  });

  test('TutorResponse preserves multi-line numbered explanations cleanly', () {
    final parsed = TutorResponse.fromJson({
      'explanation': '1- الجملة الأولى.\n\n2- الجملة الثانية يا بطل!\n3- المثال الثالث.',
      'referenced_page': 2,
      'avatar_emotion': 'talking',
    });
    expect(parsed.explanation, contains('\n'));
    expect(parsed.explanation, contains('1- الجملة الأولى.'));
    expect(parsed.explanation, contains('2- الجملة الثانية!'));
    expect(parsed.explanation, contains('3- المثال الثالث.'));
    expect(parsed.explanation, isNot(contains('يا بطل')));
  });

  test('GeminiService.isAdvanceRequest only triggers on page-advance intents', () {
    expect(GeminiService.isAdvanceRequest('اشرح لي الصفحة التالية في الملف جملة بجملة'), isTrue);
    expect(GeminiService.isAdvanceRequest('مستعد'), isTrue);
    expect(
      GeminiService.isAdvanceRequest('بسّط لي شرح هذه الصفحة أكثر واشرح كل جملة بمثال سهل'),
      isFalse,
    );
    expect(
      GeminiService.isAdvanceRequest('أعطني سؤالاً جديداً من نفس الصفحة لأختبر نفسي'),
      isFalse,
    );
    expect(GeminiService.isAdvanceRequest('يعني ايه الكلمة دي؟'), isFalse);
  });

  test('TutorResponse tracks paragraph-by-paragraph progression within a page', () {
    final part1 = TutorResponse.fromJson({
      'explanation': 'نشرح الفقرة الأولى من الصفحة.',
      'referenced_page': 13,
      'current_part': 1,
      'total_parts_in_page': 3,
      'avatar_emotion': 'talking',
    });
    expect(part1.currentPart, 1);
    expect(part1.totalPartsInPage, 3);
    expect(part1.hasMorePartsInPage, isTrue);

    final part3 = TutorResponse.fromJson(
      part1.toJson()..['current_part'] = 3,
    );
    expect(part3.currentPart, 3);
    expect(part3.totalPartsInPage, 3);
    expect(part3.hasMorePartsInPage, isFalse);

    expect(
      GeminiService.isAdvanceRequest('اشرح لي الفقرة التالية في الملف واختبرني فيها'),
      isTrue,
    );
    expect(
      GeminiService.isExplicitNextPageRequest('اشرح لي الفقرة التالية في الملف واختبرني فيها'),
      isFalse,
    );
    expect(
      GeminiService.isExplicitNextPageRequest('انتقل إلى الصفحة التالية واشرح الفقرة الأولى منها'),
      isTrue,
    );
  });

  test('UploadedPdfDocument parses cross-device owner tag cleanly', () {
    final tag = UploadedPdfDocument.ownerHashForEmail('Khaled@gmail.com');
    expect(tag, UploadedPdfDocument.ownerHashForEmail('khaled@gmail.com'));
    final doc = UploadedPdfDocument.fromJson({
      'name': 'files/abc123',
      'displayName': '[u:$tag] كتاب القراءة.pdf',
    });
    expect(doc.ownerTag, tag);
    expect(doc.displayName, 'كتاب القراءة.pdf');
  });
}
