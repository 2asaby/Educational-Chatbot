import 'dart:convert';

enum AvatarEmotion {
  happy,
  talking,
  thinking,
  celebrating,
  encouraging;

  static AvatarEmotion fromString(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'happy':
        return AvatarEmotion.happy;
      case 'talking':
        return AvatarEmotion.talking;
      case 'thinking':
        return AvatarEmotion.thinking;
      case 'celebrating':
        return AvatarEmotion.celebrating;
      case 'encouraging':
        return AvatarEmotion.encouraging;
      default:
        return AvatarEmotion.happy;
    }
  }

  String get arabicLabel {
    switch (this) {
      case AvatarEmotion.happy:
        return 'سعيد ومبتسم';
      case AvatarEmotion.talking:
        return 'يشرح الدرس';
      case AvatarEmotion.thinking:
        return 'يفكر بعمق';
      case AvatarEmotion.celebrating:
        return 'يحتفل بك!';
      case AvatarEmotion.encouraging:
        return 'يشجعك بحماس';
    }
  }

  String get emoji {
    switch (this) {
      case AvatarEmotion.happy:
        return '😄';
      case AvatarEmotion.talking:
        return '🗣️';
      case AvatarEmotion.thinking:
        return '🤔';
      case AvatarEmotion.celebrating:
        return '🎉';
      case AvatarEmotion.encouraging:
        return '🌟';
    }
  }
}

class QuizQuestion {
  final String question;
  final List<String> options;
  final int correctIndex;
  final String hint;

  const QuizQuestion({
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.hint,
  });

  factory QuizQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = (json['options'] as List<dynamic>? ?? const [])
        .map((e) => TutorResponse.sanitizeText(e.toString()))
        .toList();
    final rawIndex = (json['correct_index'] as num?)?.toInt() ?? 0;
    final safeIndex = rawOptions.isEmpty
        ? 0
        : rawIndex.clamp(0, rawOptions.length - 1);
    return QuizQuestion(
      question: TutorResponse.sanitizeText((json['question'] ?? '').toString()),
      options: rawOptions,
      correctIndex: safeIndex,
      hint: TutorResponse.sanitizeText((json['hint'] ?? '').toString()),
    );
  }

  Map<String, dynamic> toJson() => {
        'question': question,
        'options': options,
        'correct_index': correctIndex,
        'hint': hint,
      };
}

class TutorResponse {
  final String explanation;
  final int? referencedPage;
  final int? currentPart;
  final int? totalPartsInPage;
  final AvatarEmotion avatarEmotion;
  final QuizQuestion? followUpQuiz;
  final String? pageType; // 'lesson', 'assessment', or 'mixed'
  final List<TutorResponse> remainingPageParts;

  const TutorResponse({
    required this.explanation,
    this.referencedPage,
    this.currentPart,
    this.totalPartsInPage,
    required this.avatarEmotion,
    this.followUpQuiz,
    this.pageType,
    this.remainingPageParts = const [],
  });

  bool get hasMorePartsInPage =>
      currentPart != null &&
      totalPartsInPage != null &&
      totalPartsInPage! > 1 &&
      currentPart! < totalPartsInPage!;

  TutorResponse copyWith({
    String? explanation,
    int? referencedPage,
    int? currentPart,
    int? totalPartsInPage,
    AvatarEmotion? avatarEmotion,
    QuizQuestion? followUpQuiz,
    String? pageType,
    List<TutorResponse>? remainingPageParts,
  }) {
    return TutorResponse(
      explanation: explanation ?? this.explanation,
      referencedPage: referencedPage ?? this.referencedPage,
      currentPart: currentPart ?? this.currentPart,
      totalPartsInPage: totalPartsInPage ?? this.totalPartsInPage,
      avatarEmotion: avatarEmotion ?? this.avatarEmotion,
      followUpQuiz: followUpQuiz ?? this.followUpQuiz,
      pageType: pageType ?? this.pageType,
      remainingPageParts: remainingPageParts ?? this.remainingPageParts,
    );
  }

  /// Removes unwanted "يا بطل" / "أنت بطل" phrasing while keeping real words like "بطلاقة".
  static String sanitizeText(String input) {
    var out = input;
    out = out.replaceAll(
      RegExp(r'(^|\s)أنت\s+بطل\s+حقيقي(?=\s|$|[!.,،؟])'),
      ' أنت رائع جداً',
    );
    out = out.replaceAll(
      RegExp(r'(^|\s)أنت\s+بطل(?=\s|$|[!.,،؟])'),
      ' أنت رائع',
    );
    out = out.replaceAll(
      RegExp(r'\s+يا\s+بطل(?=\s|$|[!.,،؟])'),
      '',
    );
    out = out.replaceAll(
      RegExp(r'^يا\s+بطل[\s!،,]*'),
      '',
    );
    out = out.replaceAll(
      RegExp(r'\s+بطلنا(?=\s|$|[!.,،؟])'),
      ' صديقنا',
    );
    out = out.replaceAll(RegExp(r'[^\S\n]+([!.,،؟])'), r'$1');
    out = out.replaceAll(RegExp(r'[^\S\n]{2,}'), ' ');
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return out;
  }

  factory TutorResponse.fromJson(Map<String, dynamic> json) {
    final page = (json['referenced_page'] as num?)?.toInt();
    final pageType = json['page_type']?.toString();
    final rawItems = json['page_items'];

    if (rawItems is List && rawItems.isNotEmpty) {
      final validItems = rawItems.whereType<Map<String, dynamic>>().toList();
      if (validItems.isNotEmpty) {
        final total = validItems.length;
        final built = <TutorResponse>[];
        for (var i = 0; i < total; i++) {
          final item = validItems[i];
          built.add(
            TutorResponse(
              explanation: sanitizeText((item['explanation'] ?? '').toString()),
              referencedPage: page,
              currentPart: i + 1,
              totalPartsInPage: total,
              avatarEmotion: AvatarEmotion.fromString(
                item['avatar_emotion']?.toString(),
              ),
              followUpQuiz: item['follow_up_quiz'] is Map<String, dynamic>
                  ? QuizQuestion.fromJson(
                      item['follow_up_quiz'] as Map<String, dynamic>,
                    )
                  : null,
              pageType: pageType,
            ),
          );
        }
        return built.first.copyWith(
          remainingPageParts: built.length > 1 ? built.sublist(1) : const [],
        );
      }
    }

    final rawPart = (json['current_part'] as num?)?.toInt();
    final rawTotal = (json['total_parts_in_page'] as num?)?.toInt();
    final safeTotal = rawTotal != null && rawTotal >= 1 ? rawTotal : rawPart;
    final safePart = rawPart != null && rawPart >= 1
        ? (safeTotal != null && rawPart > safeTotal ? safeTotal : rawPart)
        : null;
    return TutorResponse(
      explanation: sanitizeText((json['explanation'] ?? '').toString()),
      referencedPage: page,
      currentPart: safePart,
      totalPartsInPage: safeTotal,
      avatarEmotion:
          AvatarEmotion.fromString(json['avatar_emotion']?.toString()),
      followUpQuiz: json['follow_up_quiz'] is Map<String, dynamic>
          ? QuizQuestion.fromJson(
              json['follow_up_quiz'] as Map<String, dynamic>,
            )
          : null,
      pageType: pageType,
    );
  }

  Map<String, dynamic> toJson() => {
        'explanation': explanation,
        'referenced_page': referencedPage,
        'current_part': currentPart,
        'total_parts_in_page': totalPartsInPage,
        'avatar_emotion': avatarEmotion.name,
        'follow_up_quiz': followUpQuiz?.toJson(),
        if (pageType != null) 'page_type': pageType,
      };
}

class UploadedPdfDocument {
  final String name;
  final String displayName;
  final String uri;
  final int? sizeBytes;
  final String? localBackupPath;
  final String? ownerEmail;
  final String? ownerTag;

  const UploadedPdfDocument({
    required this.name,
    required this.displayName,
    required this.uri,
    this.sizeBytes,
    this.localBackupPath,
    this.ownerEmail,
    this.ownerTag,
  });

  /// Deterministic cross-platform hash tag for syncing a Gmail user's PDFs
  /// across Windows and Android via Gemini Files API without exposing raw emails.
  static String ownerHashForEmail(String email) {
    final normalized = email.trim().toLowerCase();
    final bytes = utf8.encode(normalized);
    int hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0').substring(0, 8);
  }

  UploadedPdfDocument copyWith({
    String? name,
    String? displayName,
    String? uri,
    int? sizeBytes,
    String? localBackupPath,
    String? ownerEmail,
    String? ownerTag,
  }) {
    return UploadedPdfDocument(
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      uri: uri ?? this.uri,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      localBackupPath: localBackupPath ?? this.localBackupPath,
      ownerEmail: ownerEmail ?? this.ownerEmail,
      ownerTag: ownerTag ?? this.ownerTag,
    );
  }

  factory UploadedPdfDocument.fromJson(
    Map<String, dynamic> json, {
    String? fallbackDisplayName,
  }) {
    final name = (json['name'] ?? '').toString();
    var rawDisplay = (json['displayName'] ?? '').toString().trim();
    var parsedTag = json['ownerTag']?.toString();

    final tagMatch = RegExp(r'^\[u:([0-9a-fA-F]+)\]\s*(.*)$').firstMatch(rawDisplay);
    if (tagMatch != null) {
      parsedTag = tagMatch.group(1)?.toLowerCase();
      rawDisplay = (tagMatch.group(2) ?? '').trim();
    }

    final uri = (json['uri'] ??
            'https://generativelanguage.googleapis.com/v1beta/$name')
        .toString();
    final sizeStr = json['sizeBytes']?.toString();
    return UploadedPdfDocument(
      name: name,
      displayName: rawDisplay.isNotEmpty
          ? rawDisplay
          : (fallbackDisplayName ?? name.replaceFirst('files/', 'ملف PDF: ')),
      uri: uri,
      sizeBytes: sizeStr != null ? int.tryParse(sizeStr) : null,
      localBackupPath: json['localBackupPath']?.toString(),
      ownerEmail: json['ownerEmail']?.toString(),
      ownerTag: parsedTag,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'displayName': displayName,
        'uri': uri,
        'sizeBytes': sizeBytes?.toString(),
        if (localBackupPath != null) 'localBackupPath': localBackupPath,
        if (ownerEmail != null) 'ownerEmail': ownerEmail,
        if (ownerTag != null) 'ownerTag': ownerTag,
      };
}

class UserSession {
  final String email;
  final String displayName;
  final String? photoUrl;
  final String apiKey;
  final String? googleAccessToken;
  final bool useOAuthTokenForGemini;

  const UserSession({
    required this.email,
    required this.displayName,
    this.photoUrl,
    required this.apiKey,
    this.googleAccessToken,
    this.useOAuthTokenForGemini = false,
  });

  UserSession copyWith({
    String? email,
    String? displayName,
    String? photoUrl,
    String? apiKey,
    String? googleAccessToken,
    bool? useOAuthTokenForGemini,
  }) {
    return UserSession(
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      apiKey: apiKey ?? this.apiKey,
      googleAccessToken: googleAccessToken ?? this.googleAccessToken,
      useOAuthTokenForGemini:
          useOAuthTokenForGemini ?? this.useOAuthTokenForGemini,
    );
  }
}

class ChatEntry {
  final bool isUser;
  final String? userText;
  final TutorResponse? tutorResponse;
  final DateTime timestamp;
  int? selectedOptionIndex;

  ChatEntry({
    required this.isUser,
    this.userText,
    this.tutorResponse,
    required this.timestamp,
    this.selectedOptionIndex,
  });

  ChatEntry.user(String text)
      : isUser = true,
        userText = text,
        tutorResponse = null,
        timestamp = DateTime.now();

  ChatEntry.tutor(TutorResponse response)
      : isUser = false,
        userText = null,
        tutorResponse = response,
        timestamp = DateTime.now();

  factory ChatEntry.fromJson(Map<String, dynamic> json) {
    final isUser = json['isUser'] == true;
    return ChatEntry(
      isUser: isUser,
      userText: json['userText']?.toString(),
      tutorResponse: json['tutorResponse'] is Map<String, dynamic>
          ? TutorResponse.fromJson(
              json['tutorResponse'] as Map<String, dynamic>,
            )
          : null,
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      selectedOptionIndex: (json['selectedOptionIndex'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'isUser': isUser,
        'userText': userText,
        'tutorResponse': tutorResponse?.toJson(),
        'timestamp': timestamp.toIso8601String(),
        'selectedOptionIndex': selectedOptionIndex,
      };
}
