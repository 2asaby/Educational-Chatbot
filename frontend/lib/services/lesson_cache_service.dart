import 'dart:convert';
import 'dart:io';
import '../models/tutor_models.dart';

class LessonCacheService {
  final Directory? overrideRootDir;

  LessonCacheService({this.overrideRootDir});

  Directory _getRootDir() {
    if (overrideRootDir != null) {
      if (!overrideRootDir!.existsSync()) {
        overrideRootDir!.createSync(recursive: true);
      }
      return overrideRootDir!;
    }
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    final dir = Directory('$home${Platform.pathSeparator}.kids_ai_tutor');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  File _getCacheFile() {
    final dir = _getRootDir();
    return File('${dir.path}${Platform.pathSeparator}lessons_state.json');
  }

  String _normalizeEmail(String email) => email.trim().toLowerCase();

  String _sanitizeEmailForPath(String email) {
    return _normalizeEmail(email).replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
  }

  Map<String, dynamic> _readRaw() {
    try {
      final file = _getCacheFile();
      if (!file.existsSync()) return {};
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _writeRaw(Map<String, dynamic> data) {
    try {
      final file = _getCacheFile();
      file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  /// Loads cached PDF list for a specific Gmail user from previous runs.
  /// Migrates legacy documents into 'student@gmail.com' if needed.
  List<UploadedPdfDocument> loadCachedDocuments(String userEmail) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final userDocuments =
        (raw['user_documents'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    if (!userDocuments.containsKey(normEmail)) {
      if (normEmail == 'student@gmail.com' && raw['documents'] is List) {
        final legacyList = (raw['documents'] as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .map(UploadedPdfDocument.fromJson)
            .toList();
        userDocuments[normEmail] = legacyList.map((d) => d.toJson()).toList();
        raw['user_documents'] = userDocuments;
        if (raw['selected_doc_name'] != null) {
          final userSelected =
              (raw['user_selected_doc'] as Map<String, dynamic>?) ??
                  <String, dynamic>{};
          userSelected.putIfAbsent(
            normEmail,
            () => raw['selected_doc_name'].toString(),
          );
          raw['user_selected_doc'] = userSelected;
        }
        _writeRaw(raw);
        return legacyList;
      }
      return [];
    }

    final list = userDocuments[normEmail] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(UploadedPdfDocument.fromJson)
        .toList();
  }

  void saveCachedDocuments(
    String userEmail,
    List<UploadedPdfDocument> docs, {
    String? selectedDocName,
  }) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final userDocuments =
        (raw['user_documents'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    userDocuments[normEmail] = docs.map((d) => d.toJson()).toList();
    raw['user_documents'] = userDocuments;

    if (selectedDocName != null) {
      final userSelected =
          (raw['user_selected_doc'] as Map<String, dynamic>?) ??
              <String, dynamic>{};
      userSelected[normEmail] = selectedDocName;
      raw['user_selected_doc'] = userSelected;
    }
    _writeRaw(raw);
  }

  String? loadLastSelectedDocName(String userEmail) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final userSelected = raw['user_selected_doc'] as Map<String, dynamic>?;
    if (userSelected != null && userSelected.containsKey(normEmail)) {
      return userSelected[normEmail]?.toString();
    }
    if (normEmail == 'student@gmail.com') {
      return raw['selected_doc_name']?.toString();
    }
    return null;
  }

  /// Returns document names explicitly cached under OTHER local Gmail accounts on this device.
  Set<String> loadDocNamesOwnedByOtherUsers(String userEmail) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final others = <String>{};

    final userDocuments =
        (raw['user_documents'] as Map<String, dynamic>?) ?? const {};
    for (final entry in userDocuments.entries) {
      if (_normalizeEmail(entry.key) == normEmail) continue;
      final list = entry.value as List<dynamic>? ?? const [];
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final name = (item['name'] ?? '').toString();
        if (name.isNotEmpty) others.add(name);
      }
    }

    if (normEmail != 'student@gmail.com' && raw['documents'] is List) {
      for (final item
          in (raw['documents'] as List<dynamic>).whereType<Map<String, dynamic>>()) {
        final name = (item['name'] ?? '').toString();
        if (name.isNotEmpty) others.add(name);
      }
    }
    return others;
  }

  /// Returns document names explicitly deleted by this user so untagged remote docs don't reappear.
  Set<String> loadDeletedDocNames(String userEmail) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final deletedMap =
        (raw['user_deleted_docs'] as Map<String, dynamic>?) ?? const {};
    final list = deletedMap[normEmail] as List<dynamic>? ?? const [];
    return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toSet();
  }

  /// Loads all saved chat histories per PDF for a specific Gmail user.
  /// Migrates legacy histories into 'student@gmail.com' if needed.
  Map<String, List<ChatEntry>> loadAllChatHistories(String userEmail) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final userHistories =
        (raw['user_histories'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    if (!userHistories.containsKey(normEmail)) {
      if (normEmail == 'student@gmail.com' && raw['histories'] is Map) {
        final legacyMap = raw['histories'] as Map<String, dynamic>;
        userHistories[normEmail] = legacyMap;
        raw['user_histories'] = userHistories;
        _writeRaw(raw);
      } else {
        return {};
      }
    }

    final map = userHistories[normEmail] as Map<String, dynamic>? ?? const {};
    final result = <String, List<ChatEntry>>{};
    for (final entry in map.entries) {
      final list = entry.value as List<dynamic>? ?? const [];
      result[entry.key] = list
          .whereType<Map<String, dynamic>>()
          .map(ChatEntry.fromJson)
          .toList();
    }
    return result;
  }

  /// Saves chat history for a specific PDF document under the user's Gmail account.
  void saveChatHistory(
    String userEmail,
    String docName,
    List<ChatEntry> entries,
  ) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();
    final userHistories =
        (raw['user_histories'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final emailHistories =
        (userHistories[normEmail] as Map<String, dynamic>?) ??
            <String, dynamic>{};

    emailHistories[docName] = entries.map((e) => e.toJson()).toList();
    userHistories[normEmail] = emailHistories;
    raw['user_histories'] = userHistories;
    _writeRaw(raw);
  }

  /// Saves a permanent local backup of the PDF bytes under the user's folder
  /// so expired Gemini files (after 48 hours) can be transparently re-uploaded.
  Future<String> saveLocalPdfBackup({
    required String userEmail,
    required String filename,
    required List<int> bytes,
  }) async {
    final root = _getRootDir();
    final safeEmail = _sanitizeEmailForPath(userEmail);
    final backupDir = Directory(
      '${root.path}${Platform.pathSeparator}pdf_backups${Platform.pathSeparator}$safeEmail',
    );
    if (!backupDir.existsSync()) {
      backupDir.createSync(recursive: true);
    }
    final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final filePath =
        '${backupDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$safeName';
    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Deletes a PDF document, its selected state, chat history, prepared responses,
  /// and local backup file for the specified user.
  Future<void> deleteDocumentForUser({
    required String userEmail,
    required UploadedPdfDocument doc,
  }) async {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();

    // 1. Remove from user_documents[normEmail]
    final userDocuments =
        (raw['user_documents'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final remainingDocs = (userDocuments[normEmail] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(UploadedPdfDocument.fromJson)
        .where((d) => d.name != doc.name)
        .toList();
    userDocuments[normEmail] = remainingDocs.map((d) => d.toJson()).toList();
    raw['user_documents'] = userDocuments;

    // 2. Update user_selected_doc[normEmail]
    final userSelected =
        (raw['user_selected_doc'] as Map<String, dynamic>?) ??
            <String, dynamic>{};
    if (userSelected[normEmail]?.toString() == doc.name) {
      if (remainingDocs.isNotEmpty) {
        userSelected[normEmail] = remainingDocs.first.name;
      } else {
        userSelected.remove(normEmail);
      }
      raw['user_selected_doc'] = userSelected;
    }

    // 3. Remove chat history for this doc
    final userHistories =
        (raw['user_histories'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final emailHistories = userHistories[normEmail] as Map<String, dynamic>?;
    if (emailHistories != null) {
      emailHistories.remove(doc.name);
      userHistories[normEmail] = emailHistories;
      raw['user_histories'] = userHistories;
    }

    // 4. Remove prepared_responses for this doc (supports legacy, v2, v3, and v4 keys)
    final responses = raw['prepared_responses'] as Map<String, dynamic>?;
    if (responses != null) {
      final legacyPrefix = '${doc.name}::';
      final v2Prefix = 'v2::${doc.name}::';
      final v3Prefix = 'v3::${doc.name}::';
      final v4Prefix = 'v4::${doc.name}::';
      responses.removeWhere(
        (k, _) =>
            k.startsWith(legacyPrefix) ||
            k.startsWith(v2Prefix) ||
            k.startsWith(v3Prefix) ||
            k.startsWith(v4Prefix),
      );
      raw['prepared_responses'] = responses;
    }

    // 4b. Record deleted doc name under user_deleted_docs[normEmail]
    final deletedMap =
        (raw['user_deleted_docs'] as Map<String, dynamic>?) ??
            <String, dynamic>{};
    final deletedList = <String>{
      ...((deletedMap[normEmail] as List<dynamic>? ?? const [])
          .map((e) => e.toString())),
      doc.name,
    }.toList();
    deletedMap[normEmail] = deletedList;
    raw['user_deleted_docs'] = deletedMap;

    _writeRaw(raw);

    // 5. Delete local backup file on disk if it exists
    final backupPath = doc.localBackupPath;
    if (backupPath != null && backupPath.trim().isNotEmpty) {
      try {
        final f = File(backupPath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
  }

  /// Updates an expired Gemini document ID/URI across the user's document list,
  /// chat histories, and prepared responses.
  void replaceExpiredDocId({
    required String userEmail,
    required String oldDocName,
    required UploadedPdfDocument newDoc,
  }) {
    final normEmail = _normalizeEmail(userEmail);
    final raw = _readRaw();

    // 1. Update cached documents for this user
    final userDocuments =
        (raw['user_documents'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final docsList = (userDocuments[normEmail] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(UploadedPdfDocument.fromJson)
        .map((d) => d.name == oldDocName ? newDoc : d)
        .toList();
    userDocuments[normEmail] = docsList.map((d) => d.toJson()).toList();
    raw['user_documents'] = userDocuments;

    // 2. Update selected doc if it matched oldDocName
    final userSelected =
        (raw['user_selected_doc'] as Map<String, dynamic>?) ??
            <String, dynamic>{};
    if (userSelected[normEmail]?.toString() == oldDocName) {
      userSelected[normEmail] = newDoc.name;
      raw['user_selected_doc'] = userSelected;
    }

    // 3. Migrate chat history for oldDocName -> newDoc.name
    final userHistories =
        (raw['user_histories'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final emailHistories = userHistories[normEmail] as Map<String, dynamic>?;
    if (emailHistories != null && emailHistories.containsKey(oldDocName)) {
      emailHistories[newDoc.name] = emailHistories.remove(oldDocName);
      userHistories[normEmail] = emailHistories;
      raw['user_histories'] = userHistories;
    }

    // 4. Migrate prepared_responses keys for oldDocName -> newDoc.name
    final responses = raw['prepared_responses'] as Map<String, dynamic>?;
    if (responses != null) {
      for (final version in ['', 'v2::', 'v3::', 'v4::']) {
        final prefix = '$version$oldDocName::';
        final newPrefix = '$version${newDoc.name}::';
        final keysToMigrate =
            responses.keys.where((k) => k.startsWith(prefix)).toList();
        for (final oldKey in keysToMigrate) {
          final suffix = oldKey.substring(prefix.length);
          responses['$newPrefix$suffix'] = responses.remove(oldKey);
        }
      }
      raw['prepared_responses'] = responses;
    }

    _writeRaw(raw);
  }

  /// Normalizes a prompt key for disk caching per PDF + context page + paragraph part.
  String _buildPromptKey(
    String docName,
    int lastCoveredPage,
    String prompt, {
    int lastCoveredPart = 0,
  }) {
    return 'v4::$docName::p${lastCoveredPage}_part$lastCoveredPart::${prompt.trim()}';
  }

  /// Checks if a response for this exact PDF + page/paragraph progression + question was already prepared.
  TutorResponse? getCachedResponse({
    required String docName,
    required int lastCoveredPage,
    int lastCoveredPart = 0,
    required String prompt,
  }) {
    final raw = _readRaw();
    final responses =
        raw['prepared_responses'] as Map<String, dynamic>? ?? const {};
    final key = _buildPromptKey(
      docName,
      lastCoveredPage,
      prompt,
      lastCoveredPart: lastCoveredPart,
    );
    final item = responses[key];
    if (item is Map<String, dynamic>) {
      return TutorResponse.fromJson(item);
    }
    return null;
  }

  /// Stores a prepared response on disk so future runs or restarts load it in 0.01s.
  void savePreparedResponse({
    required String docName,
    required int lastCoveredPage,
    int lastCoveredPart = 0,
    required String prompt,
    required TutorResponse response,
  }) {
    final raw = _readRaw();
    final responses = (raw['prepared_responses'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    final key = _buildPromptKey(
      docName,
      lastCoveredPage,
      prompt,
      lastCoveredPart: lastCoveredPart,
    );
    responses[key] = response.toJson();
    raw['prepared_responses'] = responses;
    _writeRaw(raw);
  }
}
