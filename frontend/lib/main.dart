import 'dart:io';
import 'package:flutter/material.dart';
import 'models/tutor_models.dart';
import 'services/gemini_service.dart';
import 'services/google_auth_service.dart';
import 'services/lesson_cache_service.dart';
import 'services/pdf_picker_helper.dart';
import 'services/tts_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KidsAiTutorApp());
}

class KidsAiTutorApp extends StatelessWidget {
  const KidsAiTutorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'المعلم الذكي للأطفال - Kids AI Tutor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4F46E5),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const RootGateScreen(),
    );
  }
}

class RootGateScreen extends StatefulWidget {
  const RootGateScreen({super.key});

  @override
  State<RootGateScreen> createState() => _RootGateScreenState();
}

class _RootGateScreenState extends State<RootGateScreen> {
  final GoogleAuthService _authService = GoogleAuthService();
  UserSession? _session;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final saved = await _authService.loadSavedSession();
    if (!mounted) return;
    setState(() {
      _session = saved;
      _loading = false;
    });
  }

  void _onSignedIn(UserSession session) {
    setState(() {
      _session = session;
    });
  }

  Future<void> _onSignOut() async {
    await _authService.signOut();
    if (!mounted) return;
    setState(() {
      _session = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_session == null) {
      return GoogleLoginScreen(
        authService: _authService,
        onSignedIn: _onSignedIn,
      );
    }
    return TutorHomeScreen(
      session: _session!,
      authService: _authService,
      onSessionUpdated: _onSignedIn,
      onSignOut: _onSignOut,
    );
  }
}

class GoogleLoginScreen extends StatefulWidget {
  final GoogleAuthService authService;
  final ValueChanged<UserSession> onSignedIn;

  const GoogleLoginScreen({
    super.key,
    required this.authService,
    required this.onSignedIn,
  });

  @override
  State<GoogleLoginScreen> createState() => _GoogleLoginScreenState();
}

class _GoogleLoginScreenState extends State<GoogleLoginScreen> {
  final _nameController = TextEditingController(text: 'طالب المستقبل');
  final _emailController = TextEditingController(text: 'student@gmail.com');

  List<DetectedGoogleAccount> _detectedAccounts = [];
  bool _showManualForm = false;
  bool _busy = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDetectedAccounts();
  }

  Future<void> _loadDetectedAccounts() async {
    final accounts = await widget.authService.detectDeviceGoogleAccounts();
    if (!mounted) return;
    setState(() {
      _detectedAccounts = accounts;
      if (accounts.isNotEmpty) {
        _emailController.text = accounts.first.email;
        _nameController.text = accounts.first.displayName;
      } else {
        _showManualForm = true;
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _signInWithDetectedAccount(DetectedGoogleAccount account) async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final session = UserSession(
        email: account.email,
        displayName: account.displayName.isNotEmpty
            ? account.displayName
            : account.email.split('@').first,
        photoUrl: account.photoUrl,
        apiKey: GeminiService.defaultTestApiKey,
      );
      await widget.authService.saveSession(session);
      widget.onSignedIn(session);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _onSignInWithGooglePressed() async {
    if (Platform.isAndroid) {
      setState(() {
        _busy = true;
        _errorMessage = null;
      });
      final picked = await widget.authService.pickAndroidSystemGoogleAccount();
      if (picked != null) {
        await _signInWithDetectedAccount(picked);
        return;
      }
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
    if (!mounted) return;
    await _showGoogleAccountChooserDialog();
  }

  Future<void> _showGoogleAccountChooserDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xFFEEF2FF),
              child: Text(
                'G',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF4285F4),
                  fontSize: 18,
                ),
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'اختيار حساب Google للمتابعة إلى المعلم الذكي',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_detectedAccounts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'لم يتم العثور على حسابات Gmail محفوظة على الجهاز تلقائياً.',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _detectedAccounts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final acct = _detectedAccounts[index];
                      final initial = acct.displayName.isNotEmpty
                          ? acct.displayName.characters.first.toUpperCase()
                          : acct.email.characters.first.toUpperCase();
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFEEF2FF),
                          child: Text(
                            initial,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4F46E5),
                            ),
                          ),
                        ),
                        title: Text(
                          acct.displayName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          acct.email,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        trailing: Chip(
                          label: Text(
                            acct.sourceLabel,
                            style: const TextStyle(fontSize: 11),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _signInWithDetectedAccount(acct);
                        },
                      );
                    },
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(
                  Icons.person_add_alt_1_rounded,
                  color: Color(0xFF4F46E5),
                ),
                title: const Text(
                  'استخدام حساب آخر (كتابة إيميل Gmail يدوياً)',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _showManualForm = true;
                    _emailController.clear();
                    _nameController.clear();
                  });
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  Future<void> _signInQuickWithGmail() async {
    final email = _emailController.text.trim();
    final name = _nameController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorMessage = 'يرجى إدخال بريد جوجل (Gmail) صحيح.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final finalName = name.isNotEmpty ? name : email.split('@').first;
      final session = UserSession(
        email: email,
        displayName: finalName,
        apiKey: GeminiService.defaultTestApiKey,
      );

      await widget.authService.saveSession(session);
      widget.onSignedIn(session);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFEEF2FF), Color(0xFFE0E7FF), Color(0xFFFDF4FF)],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                elevation: 6,
                shadowColor: Colors.indigo.withValues(alpha: 0.2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: Text('🤖✨', style: TextStyle(fontSize: 54)),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'المعلم الذكي للأطفال',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E1B4B),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'تطبيق مستقل يعمل مباشرة بدون خادم خلفي (Windows & Android)',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: _busy ? null : _onSignInWithGooglePressed,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF1E293B),
                          side: BorderSide(color: Colors.indigo.shade200),
                          elevation: 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const CircleAvatar(
                                radius: 12,
                                backgroundColor: Color(0xFFEEF2FF),
                                child: Text(
                                  'G',
                                  style: TextStyle(
                                    color: Color(0xFF4285F4),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                        label: const Text(
                          'Sign in with Gmail / تسجيل الدخول بحساب Google',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (_detectedAccounts.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'الحسابات المسجلة على هذا الجهاز (دخول بضغطة واحدة):',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._detectedAccounts.take(4).map((acct) {
                          final initial = acct.displayName.isNotEmpty
                              ? acct.displayName.characters.first.toUpperCase()
                              : acct.email.characters.first.toUpperCase();
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: _busy
                                  ? null
                                  : () => _signInWithDetectedAccount(acct),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.indigo.shade100,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor: const Color(0xFFEEF2FF),
                                      child: Text(
                                        initial,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF4F46E5),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            acct.displayName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13.5,
                                            ),
                                          ),
                                          Text(
                                            acct.email,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Chip(
                                      label: Text(
                                        acct.sourceLabel,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _showManualForm = !_showManualForm;
                          });
                        },
                        icon: Icon(
                          _showManualForm
                              ? Icons.keyboard_arrow_up
                              : Icons.edit_outlined,
                          size: 18,
                        ),
                        label: Text(
                          _showManualForm
                              ? 'إخفاء الإدخال اليدوي'
                              : 'أو اكتب بريد Gmail آخر يدوياً',
                        ),
                      ),
                      if (_showManualForm) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: 'اسم الطالب',
                            prefixIcon: const Icon(
                              Icons.face_retouching_natural,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: 'حساب جوجل (Gmail)',
                            hintText: 'example@gmail.com',
                            prefixIcon: const Icon(Icons.mail_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: _busy ? null : _signInQuickWithGmail,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            backgroundColor: const Color(0xFF4F46E5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.rocket_launch_rounded),
                          label: const Text(
                            'دخول وبدء التعلم',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.red.shade200),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TutorHomeScreen extends StatefulWidget {
  final UserSession session;
  final GoogleAuthService authService;
  final ValueChanged<UserSession> onSessionUpdated;
  final VoidCallback onSignOut;

  const TutorHomeScreen({
    super.key,
    required this.session,
    required this.authService,
    required this.onSessionUpdated,
    required this.onSignOut,
  });

  @override
  State<TutorHomeScreen> createState() => _TutorHomeScreenState();
}

class _TutorHomeScreenState extends State<TutorHomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GeminiService _geminiService = GeminiService();
  final GeminiTtsService _ttsService = GeminiTtsService();
  final LessonCacheService _lessonCache = LessonCacheService();
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<UploadedPdfDocument> _documents = [];
  UploadedPdfDocument? _selectedDoc;

  /// Separate conversation history per PDF document so switching PDFs never mixes chats.
  final Map<String, List<ChatEntry>> _historyByDoc = {};

  AvatarEmotion _currentEmotion = AvatarEmotion.happy;
  bool _loadingFiles = false;
  bool _uploadingPdf = false;
  bool _askingTutor = false;
  bool _prefetchingNext = false;
  String? _inFlightPrefetchKey;
  Future<TutorResponse?>? _inFlightPrefetchFuture;
  String? _statusBanner;

  // Voice / TTS State
  bool _autoSpeak = true;
  String _selectedVoice = 'Puck';
  bool _generatingTts = false;
  bool _playingTts = false;
  String? _activeSpeechId;

  List<ChatEntry> get _messages {
    final docKey = _selectedDoc?.name ?? '_default';
    return _historyByDoc.putIfAbsent(docKey, () => <ChatEntry>[]);
  }

  int _getLastCoveredPage(List<ChatEntry> entries) {
    for (int i = entries.length - 1; i >= 0; i--) {
      final page = entries[i].tutorResponse?.referencedPage;
      if (page != null) return page;
    }
    return 0;
  }

  int _getLastCoveredPart(List<ChatEntry> entries) {
    for (int i = entries.length - 1; i >= 0; i--) {
      final part = entries[i].tutorResponse?.currentPart;
      if (part != null) return part;
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _restoreCachedLessonsImmediately();
    _refreshUploadedPdfs();
    _ttsService.prewarmConnection(
      session: widget.session,
      voiceName: _selectedVoice,
    );
  }

  @override
  void didUpdateWidget(covariant TutorHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.email.trim().toLowerCase() !=
        widget.session.email.trim().toLowerCase()) {
      _stopSpeaking();
      setState(() {
        _restoreCachedLessonsImmediately();
      });
      _refreshUploadedPdfs();
    }
  }

  void _restoreCachedLessonsImmediately() {
    final userEmail = widget.session.email;
    final cachedDocs = _lessonCache.loadCachedDocuments(userEmail);
    final savedHistories = _lessonCache.loadAllChatHistories(userEmail);
    final lastSelected = _lessonCache.loadLastSelectedDocName(userEmail);

    _historyByDoc.clear();
    // Clean any consecutive duplicate user turns or trailing unanswered turns left from crashes/restarts
    for (final entry in savedHistories.entries) {
      final cleaned = <ChatEntry>[];
      for (final item in entry.value) {
        if (item.isUser && cleaned.isNotEmpty && cleaned.last.isUser) {
          cleaned[cleaned.length - 1] = item;
        } else {
          cleaned.add(item);
        }
      }
      if (cleaned.isNotEmpty && cleaned.last.isUser) {
        cleaned.removeLast();
      }
      _historyByDoc[entry.key] = cleaned;
    }

    _documents = cachedDocs;
    if (cachedDocs.isNotEmpty) {
      _selectedDoc =
          cachedDocs.where((d) => d.name == lastSelected).firstOrNull ??
          cachedDocs.first;
    } else {
      _selectedDoc = null;
    }
  }

  @override
  void dispose() {
    _ttsService.dispose();
    _questionController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _speakText(String text, {required String speechId}) async {
    if (_activeSpeechId == speechId && (_playingTts || _generatingTts)) {
      await _stopSpeaking();
      return;
    }

    await _ttsService.stopPlayback();
    if (!mounted) return;

    final previousEmotion = _currentEmotion;
    setState(() {
      _activeSpeechId = speechId;
      _generatingTts = true;
      _playingTts = false;
    });

    try {
      await _ttsService.speakTextPipelined(
        session: widget.session,
        text: text,
        voiceName: _selectedVoice,
        onPlaybackStarted: () {
          if (!mounted || _activeSpeechId != speechId) return;
          setState(() {
            _generatingTts = false;
            _playingTts = true;
            _currentEmotion = AvatarEmotion.talking;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusBanner = 'تعذر تشغيل صوت المعلم: $e';
      });
    } finally {
      if (mounted && _activeSpeechId == speechId) {
        setState(() {
          _generatingTts = false;
          _playingTts = false;
          _activeSpeechId = null;
          if (_currentEmotion == AvatarEmotion.talking) {
            _currentEmotion = previousEmotion;
          }
        });
      }
    }
  }

  Future<void> _stopSpeaking() async {
    await _ttsService.stopPlayback();
    if (!mounted) return;
    setState(() {
      _generatingTts = false;
      _playingTts = false;
      _activeSpeechId = null;
      if (_currentEmotion == AvatarEmotion.talking) {
        _currentEmotion = AvatarEmotion.happy;
      }
    });
  }

  Future<void> _refreshUploadedPdfs() async {
    final userEmail = widget.session.email;
    final normEmail = userEmail.trim().toLowerCase();
    setState(() {
      _loadingFiles = _documents.isEmpty;
      _statusBanner = null;
    });
    try {
      final activeDocs = await _geminiService.listUploadedPdfs(widget.session);
      if (!mounted) return;
      final localDocs = _lessonCache.loadCachedDocuments(userEmail);
      final myTag = UploadedPdfDocument.ownerHashForEmail(userEmail);

      List<UploadedPdfDocument> nextDocs;
      if (localDocs.isEmpty && normEmail == 'student@gmail.com') {
        nextDocs = activeDocs
            .where((d) => d.ownerTag == null || d.ownerTag == myTag)
            .map((d) => d.copyWith(ownerEmail: userEmail))
            .toList();
      } else {
        // Keep local docs belonging to this user (refreshing active metadata,
        // and dropping remote-only synced docs if deleted from another device).
        final activeByName = {for (final a in activeDocs) a.name: a};
        final merged = <UploadedPdfDocument>[];
        final seenNames = <String>{};

        for (final doc in localDocs) {
          final active = activeByName[doc.name];
          if (active != null) {
            merged.add(
              doc.copyWith(
                uri: active.uri,
                sizeBytes: active.sizeBytes ?? doc.sizeBytes,
                ownerTag: active.ownerTag ?? doc.ownerTag,
              ),
            );
            seenNames.add(doc.name);
          } else if (doc.localBackupPath != null &&
              File(doc.localBackupPath!).existsSync()) {
            // Keep locally backed-up files so auto-reupload works after 48h
            merged.add(doc);
            seenNames.add(doc.name);
          }
        }

        // Sync any newly uploaded PDFs from this same Gmail user on another device (Mobile <-> Windows)
        final otherUserDocs = _lessonCache.loadDocNamesOwnedByOtherUsers(
          userEmail,
        );
        final deletedDocs = _lessonCache.loadDeletedDocNames(userEmail);
        for (final active in activeDocs) {
          if (seenNames.contains(active.name) ||
              deletedDocs.contains(active.name)) {
            continue;
          }
          final belongsToMe =
              active.ownerTag == myTag ||
              (active.ownerTag == null && !otherUserDocs.contains(active.name));
          if (belongsToMe) {
            merged.insert(0, active.copyWith(ownerEmail: userEmail));
            seenNames.add(active.name);
          }
        }

        nextDocs = merged;
      }

      setState(() {
        _documents = nextDocs;
        if (_selectedDoc == null && nextDocs.isNotEmpty) {
          final lastSelected = _lessonCache.loadLastSelectedDocName(userEmail);
          _selectedDoc =
              nextDocs.where((d) => d.name == lastSelected).firstOrNull ??
              nextDocs.first;
        } else if (_selectedDoc != null) {
          _selectedDoc =
              nextDocs.where((d) => d.name == _selectedDoc!.name).firstOrNull ??
              (nextDocs.isNotEmpty ? nextDocs.first : null);
        }
      });
      _lessonCache.saveCachedDocuments(
        userEmail,
        nextDocs,
        selectedDocName: _selectedDoc?.name,
      );
    } catch (e) {
      if (!mounted) return;
      if (_documents.isEmpty && normEmail == 'student@gmail.com') {
        setState(() {
          _statusBanner = 'ملاحظة: تعذر جلب قائمة الملفات السابقة ($e)';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingFiles = false;
        });
      }
    }
  }

  Future<void> _pickAndUploadPdf() async {
    try {
      PickedPdfFile? picked;
      if (Platform.isWindows) {
        picked = await PdfPickerHelper.pickPdfOnWindows();
      } else if (Platform.isAndroid) {
        picked = await PdfPickerHelper.pickPdfOnAndroid();
      } else {
        picked = await _promptPdfPathDialog();
      }

      if (picked == null) return;

      setState(() {
        _uploadingPdf = true;
        _currentEmotion = AvatarEmotion.thinking;
        _statusBanner =
            'جاري رفع الملف "${picked!.filename}" إلى Gemini مباشرة...';
      });

      final userEmail = widget.session.email;
      final backupPath = await _lessonCache.saveLocalPdfBackup(
        userEmail: userEmail,
        filename: picked.filename,
        bytes: picked.bytes,
      );

      final uploadedRaw = await _geminiService.uploadPdfBytes(
        session: widget.session,
        filename: picked.filename,
        bytes: picked.bytes,
      );
      final uploaded = uploadedRaw.copyWith(
        localBackupPath: backupPath,
        ownerEmail: userEmail,
      );

      final oauthToken = widget.session.googleAccessToken;
      if (oauthToken != null && oauthToken.trim().isNotEmpty) {
        widget.authService.backupPdfToGoogleDrive(
          accessToken: oauthToken,
          filename: picked.filename,
          bytes: picked.bytes,
        );
      }

      if (!mounted) return;
      final updatedDocs = [
        uploaded,
        ..._documents.where((d) => d.name != uploaded.name),
      ];
      setState(() {
        _documents = updatedDocs;
        _selectedDoc = uploaded;
        _currentEmotion = AvatarEmotion.celebrating;
        _statusBanner =
            'تم رفع الملف "${uploaded.displayName}" وحفظه في حسابك (${widget.session.email}) بنجاح!';
      });
      _lessonCache.saveCachedDocuments(
        userEmail,
        updatedDocs,
        selectedDocName: uploaded.name,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _currentEmotion = AvatarEmotion.encouraging;
        _statusBanner = 'فشل رفع ملف PDF: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingPdf = false;
        });
      }
    }
  }

  Future<PickedPdfFile?> _promptPdfPathDialog() async {
    final pathCtrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أدخل مسار ملف الـ PDF'),
        content: TextField(
          controller: pathCtrl,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/Download/lesson.pdf',
            labelText: 'مسار ملف PDF على الجهاز',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, pathCtrl.text),
            child: const Text('رفع الملف'),
          ),
        ],
      ),
    );
    if (path == null || path.trim().isEmpty) return null;
    return PdfPickerHelper.loadPdfFromPath(path);
  }

  void _clearCurrentChat() {
    _stopSpeaking();
    setState(() {
      _messages.clear();
      _currentEmotion = AvatarEmotion.happy;
      _statusBanner = null;
    });
    if (_selectedDoc != null) {
      _lessonCache.saveChatHistory(
        widget.session.email,
        _selectedDoc!.name,
        _messages,
      );
    }
  }

  Future<void> _confirmAndDeletePdf(UploadedPdfDocument doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف ملف الدرس'),
        content: Text(
          'هل تريد حذف ملف (${doc.displayName}) وجميع محادثاته نهائياً؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _stopSpeaking();
    final userEmail = widget.session.email;

    await _lessonCache.deleteDocumentForUser(userEmail: userEmail, doc: doc);
    // Best-effort remote deletion on Gemini Files API
    _geminiService.deleteUploadedPdf(
      session: widget.session,
      geminiFileName: doc.name,
    );

    if (!mounted) return;
    setState(() {
      _historyByDoc.remove(doc.name);
      _documents = _documents.where((d) => d.name != doc.name).toList();
      if (_selectedDoc?.name == doc.name) {
        _selectedDoc = _documents.isNotEmpty ? _documents.first : null;
      }
      _statusBanner = 'تم حذف الملف "${doc.displayName}" بنجاح.';
    });
  }

  String _buildPrefetchKey(String docName, int lastPage, int lastPart) =>
      '$docName::$lastPage::$lastPart';

  bool _isNextParagraphPresetPrompt(String text) {
    final trimmed = text.trim();
    return trimmed == 'اشرح لي الفقرة التالية في الملف واختبرني فيها' ||
        trimmed ==
            'أجبت بشكل صحيح! اشرح لي الفقرة التالية من الدرس واختبرني فيها';
  }

  /// Silently prepares the next lesson paragraph/page in the background
  /// while the child reads and answers the current quiz, so clicking "Next" is instant!
  Future<void> _prefetchNextLessonStepInBackground(
    UploadedPdfDocument doc,
    List<ChatEntry> currentHistory,
  ) async {
    final lastPage = _getLastCoveredPage(currentHistory);
    final lastPart = _getLastCoveredPart(currentHistory);
    final prefetchKey = _buildPrefetchKey(doc.name, lastPage, lastPart);
    if (_prefetchingNext && _inFlightPrefetchKey == prefetchKey) return;

    const nextPrompt = 'اشرح لي الفقرة التالية في الملف واختبرني فيها';
    const nextQuizPrompt =
        'أجبت بشكل صحيح! اشرح لي الفقرة التالية من الدرس واختبرني فيها';

    final alreadyCached = _lessonCache.getCachedResponse(
      docName: doc.name,
      lastCoveredPage: lastPage,
      lastCoveredPart: lastPart,
      prompt: nextPrompt,
    );
    if (alreadyCached != null) return;

    _prefetchingNext = true;
    _inFlightPrefetchKey = prefetchKey;

    Future<TutorResponse?> runPrefetch() async {
      try {
        final prefetchedReply = await _geminiService.askTutor(
          session: widget.session,
          pdfDocument: doc,
          studentMessage: nextPrompt,
          previousHistory: currentHistory,
        );
        _lessonCache.savePreparedResponse(
          docName: doc.name,
          lastCoveredPage: lastPage,
          lastCoveredPart: lastPart,
          prompt: nextPrompt,
          response: prefetchedReply,
        );
        _lessonCache.savePreparedResponse(
          docName: doc.name,
          lastCoveredPage: lastPage,
          lastCoveredPart: lastPart,
          prompt: nextQuizPrompt,
          response: prefetchedReply,
        );
        return prefetchedReply;
      } catch (_) {
        // Silent background prefetch
        return null;
      } finally {
        if (_inFlightPrefetchKey == prefetchKey) {
          _prefetchingNext = false;
          _inFlightPrefetchKey = null;
          _inFlightPrefetchFuture = null;
        }
      }
    }

    final future = runPrefetch();
    _inFlightPrefetchFuture = future;
    await future;
  }

  Future<void> _sendQuestion([String? presetQuestion]) async {
    final text = (presetQuestion ?? _questionController.text).trim();
    if (text.isEmpty || _askingTutor) return;

    if (_selectedDoc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى اختيار أو رفع ملف PDF أولاً لنبدأ الدرس!'),
        ),
      );
      return;
    }

    if (presetQuestion == null) {
      _questionController.clear();
    }

    await _stopSpeaking();

    final userEmail = widget.session.email;
    var currentDoc = _selectedDoc!;
    // Snapshot previous history BEFORE adding the new user turn
    final historySnapshot = List<ChatEntry>.from(_messages);
    final lastPage = _getLastCoveredPage(historySnapshot);
    final lastPart = _getLastCoveredPart(historySnapshot);

    // 1. Check persistent disk cache first (instant 0.01s response if already prepared!)
    final cachedReply = _lessonCache.getCachedResponse(
      docName: currentDoc.name,
      lastCoveredPage: lastPage,
      lastCoveredPart: lastPart,
      prompt: text,
    );

    if (cachedReply != null) {
      final newEntry = ChatEntry.tutor(cachedReply);
      setState(() {
        _messages.add(ChatEntry.user(text));
        _messages.add(newEntry);
        _currentEmotion = cachedReply.avatarEmotion;
        _statusBanner = null;
      });
      _lessonCache.saveChatHistory(userEmail, currentDoc.name, _messages);
      _scrollToBottom();

      if (_autoSpeak) {
        final speechId = 'msg_${newEntry.timestamp.millisecondsSinceEpoch}';
        _speakText(cachedReply.explanation, speechId: speechId);
      } else {
        _ttsService.prewarmFirstSentence(
          session: widget.session,
          text: cachedReply.explanation,
          voiceName: _selectedVoice,
        );
      }
      _prefetchNextLessonStepInBackground(
        currentDoc,
        List<ChatEntry>.from(_messages),
      );
      return;
    }

    setState(() {
      _messages.add(ChatEntry.user(text));
      _askingTutor = true;
      _currentEmotion = AvatarEmotion.thinking;
      _statusBanner = null;
    });
    _scrollToBottom();

    if (_autoSpeak) {
      _ttsService.prewarmConnection(
        session: widget.session,
        voiceName: _selectedVoice,
      );
    }

    try {
      TutorResponse reply;
      final currentPrefetchKey = _buildPrefetchKey(
        currentDoc.name,
        lastPage,
        lastPart,
      );
      TutorResponse? joinedPrefetch;
      if (_isNextParagraphPresetPrompt(text) &&
          _inFlightPrefetchKey == currentPrefetchKey &&
          _inFlightPrefetchFuture != null) {
        joinedPrefetch = await _inFlightPrefetchFuture;
      }
      if (joinedPrefetch != null) {
        reply = joinedPrefetch;
      } else {
        try {
          reply = await _geminiService.askTutor(
            session: widget.session,
            pdfDocument: currentDoc,
            studentMessage: text,
            previousHistory: historySnapshot,
          );
        } catch (e) {
          final errStr = e.toString();
          final isExpiredOrMissing =
              errStr.contains('(403)') || errStr.contains('(404)');
          final backupPath = currentDoc.localBackupPath;
          if (isExpiredOrMissing &&
              backupPath != null &&
              File(backupPath).existsSync()) {
            final backupBytes = await File(backupPath).readAsBytes();
            final reuploaded = await _geminiService.uploadPdfBytes(
              session: widget.session,
              filename: currentDoc.displayName,
              bytes: backupBytes,
            );
            final refreshedDoc = reuploaded.copyWith(
              localBackupPath: backupPath,
              ownerEmail: userEmail,
            );
            final oldDocName = currentDoc.name;
            _lessonCache.replaceExpiredDocId(
              userEmail: userEmail,
              oldDocName: oldDocName,
              newDoc: refreshedDoc,
            );
            final oldMessages = _historyByDoc.remove(oldDocName);
            if (oldMessages != null) {
              _historyByDoc[refreshedDoc.name] = oldMessages;
            }
            if (mounted) {
              setState(() {
                _documents = _documents
                    .map((d) => d.name == oldDocName ? refreshedDoc : d)
                    .toList();
                _selectedDoc = refreshedDoc;
              });
            }
            currentDoc = refreshedDoc;

            reply = await _geminiService.askTutor(
              session: widget.session,
              pdfDocument: currentDoc,
              studentMessage: text,
              previousHistory: historySnapshot,
            );
          } else {
            rethrow;
          }
        }
      }

      // Save prepared response to disk so next run or restart is instantaneous
      _lessonCache.savePreparedResponse(
        docName: currentDoc.name,
        lastCoveredPage: lastPage,
        lastCoveredPart: lastPart,
        prompt: text,
        response: reply,
      );

      if (!mounted) return;
      final newEntry = ChatEntry.tutor(reply);
      setState(() {
        _messages.add(newEntry);
        _currentEmotion = reply.avatarEmotion;
      });
      _lessonCache.saveChatHistory(userEmail, currentDoc.name, _messages);
      _scrollToBottom();

      if (_autoSpeak) {
        final speechId = 'msg_${newEntry.timestamp.millisecondsSinceEpoch}';
        _speakText(reply.explanation, speechId: speechId);
      } else {
        _ttsService.prewarmFirstSentence(
          session: widget.session,
          text: reply.explanation,
          voiceName: _selectedVoice,
        );
      }

      // Silently pre-prepare the NEXT page in the background!
      _prefetchNextLessonStepInBackground(
        currentDoc,
        List<ChatEntry>.from(_messages),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_messages.isNotEmpty && _messages.last.isUser) {
          _messages.removeLast();
        }
        _currentEmotion = AvatarEmotion.encouraging;
        _statusBanner = 'حدث خطأ أثناء الاتصال بالمعلم الذكي: $e';
      });
      _lessonCache.saveChatHistory(userEmail, currentDoc.name, _messages);
    } finally {
      if (mounted) {
        setState(() {
          _askingTutor = false;
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _emotionColor(AvatarEmotion emotion) {
    switch (emotion) {
      case AvatarEmotion.happy:
        return const Color(0xFF4F46E5);
      case AvatarEmotion.talking:
        return const Color(0xFF0284C7);
      case AvatarEmotion.thinking:
        return const Color(0xFF7C3AED);
      case AvatarEmotion.celebrating:
        return const Color(0xFF16A34A);
      case AvatarEmotion.encouraging:
        return const Color(0xFFD97706);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWide = width >= 860;
    final isCompact = width < 760;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isWide
          ? null
          : Drawer(
              width: width < 380 ? width * 0.85 : 325,
              child: SafeArea(child: _buildSidebarPanel(inDrawer: true)),
            ),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        automaticallyImplyLeading: false,
        titleSpacing: isCompact ? 4 : null,
        leading: isWide
            ? null
            : IconButton(
                tooltip: 'القائمة والملفات والصوت',
                icon: const Icon(Icons.menu_rounded, color: Color(0xFF1E1B4B)),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
        title: Row(
          children: [
            const Text('🎓 ', style: TextStyle(fontSize: 20)),
            Expanded(
              child: Text(
                'المعلم الذكي للأطفال',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: isCompact ? 14 : 20,
                  color: const Color(0xFF1E1B4B),
                ),
              ),
            ),
            if (_playingTts || _generatingTts)
              Padding(
                padding: EdgeInsets.only(left: isCompact ? 4 : 6),
                child: FilledButton.tonalIcon(
                  onPressed: _stopSpeaking,
                  style: FilledButton.styleFrom(
                    visualDensity: isCompact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    padding: isCompact
                        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                        : null,
                    minimumSize: isCompact ? Size.zero : null,
                    tapTargetSize: isCompact
                        ? MaterialTapTargetSize.shrinkWrap
                        : null,
                    backgroundColor: Colors.red.shade50,
                    foregroundColor: Colors.red.shade700,
                  ),
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: isCompact ? 16 : 18,
                  ),
                  label: Text(
                    isCompact
                        ? (_generatingTts ? 'تجهيز...' : 'إيقاف')
                        : (_generatingTts
                              ? 'جاري تجهيز الصوت...'
                              : 'إيقاف الصوت'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            if (isCompact)
              IconButton(
                tooltip: _autoSpeak
                    ? 'النطق التلقائي: مفعل'
                    : 'النطق التلقائي: صامت',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                onPressed: () {
                  setState(() => _autoSpeak = !_autoSpeak);
                  if (!_autoSpeak) _stopSpeaking();
                },
                icon: Icon(
                  _autoSpeak
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  size: 20,
                  color: _autoSpeak ? const Color(0xFF4F46E5) : Colors.grey,
                ),
              )
            else ...[
              FilterChip(
                selected: _autoSpeak,
                onSelected: (val) {
                  setState(() => _autoSpeak = val);
                  if (!val) _stopSpeaking();
                },
                avatar: Icon(
                  _autoSpeak
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  size: 16,
                  color: _autoSpeak ? const Color(0xFF4F46E5) : Colors.grey,
                ),
                label: Text(
                  _autoSpeak ? 'النطق التلقائي: مفعل' : 'النطق التلقائي: صامت',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (_messages.isNotEmpty)
              IconButton(
                tooltip: 'بدء درس جديد',
                visualDensity: isCompact
                    ? VisualDensity.compact
                    : VisualDensity.standard,
                padding: isCompact ? EdgeInsets.zero : null,
                constraints: isCompact
                    ? const BoxConstraints(minWidth: 34, minHeight: 34)
                    : null,
                onPressed: _askingTutor ? null : _clearCurrentChat,
                icon: const Icon(Icons.restart_alt_rounded, size: 20),
              ),
            if (isWide)
              Chip(
                avatar: const Icon(
                  Icons.person,
                  size: 16,
                  color: Color(0xFF4F46E5),
                ),
                label: Text(
                  width >= 1080
                      ? '${widget.session.displayName} (${widget.session.email})'
                      : widget.session.displayName,
                  style: const TextStyle(fontSize: 12),
                ),
                backgroundColor: const Color(0xFFEEF2FF),
              ),
            IconButton(
              tooltip: 'إعدادات الصوت والحساب',
              visualDensity: isCompact
                  ? VisualDensity.compact
                  : VisualDensity.standard,
              padding: isCompact ? EdgeInsets.zero : null,
              constraints: isCompact
                  ? const BoxConstraints(minWidth: 34, minHeight: 34)
                  : null,
              onPressed: _showAccountSettingsDialog,
              icon: const Icon(Icons.settings_outlined, size: 20),
            ),
            IconButton(
              tooltip: 'تسجيل الخروج',
              visualDensity: isCompact
                  ? VisualDensity.compact
                  : VisualDensity.standard,
              padding: isCompact ? EdgeInsets.zero : null,
              constraints: isCompact
                  ? const BoxConstraints(minWidth: 34, minHeight: 34)
                  : null,
              onPressed: widget.onSignOut,
              icon: const Icon(
                Icons.logout_rounded,
                color: Colors.redAccent,
                size: 20,
              ),
            ),
          ],
        ),
      ),
      body: isWide
          ? Row(
              children: [
                SizedBox(width: 335, child: _buildSidebarPanel()),
                const VerticalDivider(width: 1),
                Expanded(child: _buildChatSection()),
              ],
            )
          : Column(
              children: [
                _buildCompactTopBar(),
                Expanded(child: _buildChatSection()),
              ],
            ),
    );
  }

  Widget _buildSidebarPanel({bool inDrawer = false}) {
    final emotionColor = _emotionColor(_currentEmotion);
    return Container(
      color: Colors.white,
      padding: EdgeInsets.all(inDrawer ? 14 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  emotionColor.withValues(alpha: 0.14),
                  emotionColor.withValues(alpha: 0.04),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: emotionColor.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Text(
                  _currentEmotion.emoji,
                  style: const TextStyle(fontSize: 54),
                ),
                const SizedBox(height: 6),
                Text(
                  'حالة المعلم: ${_currentEmotion.arabicLabel}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: emotionColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _playingTts
                      ? '🔊 المعلم يتحدث ويشرح لك الدرس بصوته الآن...'
                      : _generatingTts
                      ? '⏳ جاري تجهيز صوت المعلم الذكي...'
                      : _askingTutor
                      ? 'المعلم يقرأ الصفحة التالية ويجهز لك شرحاً جديداً...'
                      : 'أنا جاهز لشرح درسك اليوم بالصوت والصورة!',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.record_voice_over_rounded,
                  size: 18,
                  color: Color(0xFF4F46E5),
                ),
                const SizedBox(width: 8),
                const Text(
                  'صوت المعلم:',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isDense: true,
                      isExpanded: true,
                      value: _selectedVoice,
                      items: GeminiTtsService.availableVoices.entries.map((e) {
                        return DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(
                            e.value,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedVoice = val);
                          _ttsService.prewarmConnection(
                            session: widget.session,
                            voiceName: val,
                          );
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  '📚 ملف الدرس (PDF)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              IconButton(
                tooltip: 'تحديث قائمة الملفات',
                visualDensity: VisualDensity.compact,
                onPressed: _loadingFiles ? null : _refreshUploadedPdfs,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: _uploadingPdf ? null : _pickAndUploadPdf,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
              backgroundColor: const Color(0xFF4F46E5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: _uploadingPdf
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.upload_file_rounded),
            label: Text(
              _uploadingPdf ? 'جاري رفع الـ PDF...' : 'رفع ملف PDF جديد للدرس',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loadingFiles
                ? const Center(child: CircularProgressIndicator())
                : _documents.isEmpty
                ? Center(
                    child: Text(
                      'لا توجد ملفات PDF مرفوعة حالياً.\nاضغط على "رفع ملف PDF جديد" للبدء!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _documents.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final doc = _documents[index];
                      final isSelected = _selectedDoc?.name == doc.name;
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          setState(() {
                            _selectedDoc = doc;
                          });
                          _lessonCache.saveCachedDocuments(
                            widget.session.email,
                            _documents,
                            selectedDocName: doc.name,
                          );
                          if (inDrawer) {
                            Navigator.pop(context);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFEEF2FF)
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF4F46E5)
                                  : Colors.grey.shade200,
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.picture_as_pdf_rounded,
                                color: isSelected
                                    ? const Color(0xFF4F46E5)
                                    : Colors.redAccent,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      doc.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Text(
                                      doc.name,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: Color(0xFF4F46E5),
                                  size: 20,
                                ),
                              IconButton(
                                tooltip: 'حذف الملف',
                                visualDensity: VisualDensity.compact,
                                onPressed: _askingTutor
                                    ? null
                                    : () => _confirmAndDeletePdf(doc),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactTopBar() {
    final emotionColor = _emotionColor(_currentEmotion);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Text(_currentEmotion.emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'حالة المعلم: ${_currentEmotion.arabicLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: emotionColor,
                    fontSize: 13,
                  ),
                ),
                if (_documents.isNotEmpty)
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isDense: true,
                      isExpanded: true,
                      value: _selectedDoc?.name,
                      hint: const Text(
                        'اختر ملف الدرس',
                        style: TextStyle(fontSize: 12),
                      ),
                      items: _documents.map((doc) {
                        return DropdownMenuItem<String>(
                          value: doc.name,
                          child: Text(
                            doc.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        final found = _documents
                            .where((d) => d.name == val)
                            .firstOrNull;
                        if (found != null) {
                          setState(() => _selectedDoc = found);
                          _lessonCache.saveCachedDocuments(
                            widget.session.email,
                            _documents,
                            selectedDocName: found.name,
                          );
                        }
                      },
                    ),
                  )
                else
                  Text(
                    'يرجى رفع ملف PDF للبدء',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
              ],
            ),
          ),
          if (_selectedDoc != null)
            IconButton(
              tooltip: 'حذف الملف الحالي',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              onPressed: _askingTutor || _uploadingPdf
                  ? null
                  : () => _confirmAndDeletePdf(_selectedDoc!),
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
                size: 20,
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'تغيير صوت المعلم',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            initialValue: _selectedVoice,
            onSelected: (val) {
              setState(() => _selectedVoice = val);
              _ttsService.prewarmConnection(
                session: widget.session,
                voiceName: val,
              );
            },
            itemBuilder: (ctx) => GeminiTtsService.availableVoices.entries
                .map(
                  (e) => PopupMenuItem<String>(
                    value: e.key,
                    child: Row(
                      children: [
                        if (e.key == _selectedVoice)
                          const Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: Color(0xFF4F46E5),
                          )
                        else
                          const SizedBox(width: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            e.value,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
            icon: const Icon(
              Icons.record_voice_over_rounded,
              color: Color(0xFF4F46E5),
              size: 21,
            ),
          ),
          const SizedBox(width: 2),
          FilledButton.tonalIcon(
            onPressed: _uploadingPdf ? null : _pickAndUploadPdf,
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('رفع PDF'),
          ),
        ],
      ),
    );
  }

  Widget _buildChatSection() {
    final totalItems = _messages.length + (_askingTutor ? 1 : 0);

    return Column(
      children: [
        if (_statusBanner != null)
          Container(
            width: double.infinity,
            color: const Color(0xFFFEF3C7),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Color(0xFFB45309)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusBanner!,
                    style: const TextStyle(
                      color: Color(0xFF92400E),
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _statusBanner = null),
                ),
              ],
            ),
          ),
        Expanded(
          child: _messages.isEmpty && !_askingTutor
              ? _buildEmptyChatWelcome()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                  itemCount: totalItems,
                  itemBuilder: (context, index) {
                    if (index == _messages.length && _askingTutor) {
                      return _buildTypingIndicatorBubble();
                    }
                    final entry = _messages[index];
                    return entry.isUser
                        ? _buildUserBubble(entry.userText ?? '')
                        : _buildTutorBubble(entry);
                  },
                ),
        ),
        if (_messages.isNotEmpty) _buildQuickProgressionBar(),
        _buildMessageInputBar(),
      ],
    );
  }

  Widget _buildTypingIndicatorBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.indigo.shade100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '🤔 المعلم الذكي يجهز لك شرحاً جديداً من الملف...',
                  style: TextStyle(
                    color: Colors.indigo.shade900,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickProgressionBar() {
    final actions = [
      ('➡️ الفقرة التالية', 'اشرح لي الفقرة التالية في الملف واختبرني فيها'),
      ('💡 بسّط الشرح أكثر', 'بسّط لي شرح هذه الفقرة الحالية أكثر بمثال سهل'),
      (
        '🧩 اختبرني بسؤال جديد',
        'أعطني سؤالاً جديداً عن هذه الفقرة لأختبر نفسي',
      ),
      (
        '⏭️ الصفحة التالية',
        'انتقل إلى الصفحة التالية واشرح الفقرة الأولى منها',
      ),
    ];

    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: actions.map((item) {
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ActionChip(
                backgroundColor: const Color(0xFFEEF2FF),
                side: BorderSide(color: Colors.indigo.shade100),
                label: Text(
                  item.$1,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3730A3),
                  ),
                ),
                onPressed: _askingTutor ? null : () => _sendQuestion(item.$2),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildEmptyChatWelcome() {
    final suggestions = [
      'ابدأ معي أول درس في هذا الملف واشرح كل جملة فيه بقصة ممتعة!',
      'اشرح لي الصفحة الأولى جملة بجملة ببساطة',
      'علمني كل المعلومات في هذه الصفحة واختبرني فيها!',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🌟📖', style: TextStyle(fontSize: 52)),
              const SizedBox(height: 12),
              Text(
                'أهلاً بك يا ${widget.session.displayName}!',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E1B4B),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _selectedDoc != null
                    ? 'ملف الدرس جاهز (${_selectedDoc!.displayName}). اختر سؤالاً للبدء وسيقوم المعلم بشرحه لك بالصوت!'
                    : 'قم برفع ملف PDF للدرس من القائمة، ثم اسألني أي شيء عنه!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: suggestions.map((q) {
                  return ActionChip(
                    avatar: const Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: Color(0xFF4F46E5),
                    ),
                    label: Text(q),
                    onPressed: _askingTutor ? null : () => _sendQuestion(q),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Container(
          margin: const EdgeInsets.only(bottom: 16, left: 32),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          decoration: const BoxDecoration(
            color: Color(0xFF4F46E5),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTutorBubble(ChatEntry entry) {
    final res = entry.tutorResponse!;
    final quiz = res.followUpQuiz;
    final msgSpeechId = 'msg_${entry.timestamp.millisecondsSinceEpoch}';
    final quizSpeechId = 'quiz_${entry.timestamp.millisecondsSinceEpoch}';
    final isMsgSpeaking =
        _activeSpeechId == msgSpeechId && (_playingTts || _generatingTts);
    final isQuizSpeaking =
        _activeSpeechId == quizSpeechId && (_playingTts || _generatingTts);

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: Container(
          margin: const EdgeInsets.only(bottom: 20, right: 12),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isMsgSpeaking
                  ? const Color(0xFF0284C7)
                  : Colors.indigo.shade100,
              width: isMsgSpeaking ? 1.8 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.indigo.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isMsgSpeaking ? '🗣️' : res.avatarEmotion.emoji,
                        style: const TextStyle(fontSize: 26),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          isMsgSpeaking
                              ? 'المعلم الذكي (يتحدث الآن...)'
                              : 'المعلم الذكي (${res.avatarEmotion.arabicLabel})',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isMsgSpeaking
                                ? const Color(0xFF0284C7)
                                : _emotionColor(res.avatarEmotion),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            _speakText(res.explanation, speechId: msgSpeechId),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: isMsgSpeaking
                              ? Colors.red.shade50
                              : const Color(0xFFEEF2FF),
                          foregroundColor: isMsgSpeaking
                              ? Colors.red.shade700
                              : const Color(0xFF4F46E5),
                        ),
                        icon: isMsgSpeaking && _generatingTts
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                isMsgSpeaking
                                    ? Icons.stop_rounded
                                    : Icons.volume_up_rounded,
                                size: 17,
                              ),
                        label: Text(
                          isMsgSpeaking
                              ? (_generatingTts
                                    ? 'جاري تجهيز الصوت...'
                                    : 'إيقاف الصوت')
                              : 'استمع للشرح',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (res.referencedPage != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            res.currentPart != null &&
                                    res.totalPartsInPage != null
                                ? '📖 صفحة ${res.referencedPage} • فقرة ${res.currentPart}/${res.totalPartsInPage}'
                                : '📖 صفحة ${res.referencedPage}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4F46E5),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                res.explanation,
                style: const TextStyle(
                  fontSize: 15.5,
                  height: 1.65,
                  color: Color(0xFF1E293B),
                ),
              ),
              if (quiz != null && quiz.options.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text('🧩 ', style: TextStyle(fontSize: 20)),
                          Expanded(
                            child: Text(
                              'سؤال الدرس: ${quiz.question}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14.5,
                                color: Color(0xFF1E1B4B),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'قراءة السؤال بالصوت',
                            onPressed: () {
                              final fullQuizText =
                                  'سؤال الدرس: ${quiz.question}. الاختيارات هي: ${quiz.options.join('، أو ')}';
                              _speakText(fullQuizText, speechId: quizSpeechId);
                            },
                            icon: Icon(
                              isQuizSpeaking
                                  ? Icons.stop_circle_rounded
                                  : Icons.volume_up_outlined,
                              color: isQuizSpeaking
                                  ? Colors.red
                                  : const Color(0xFF4F46E5),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ...List.generate(quiz.options.length, (idx) {
                        final isSelected = entry.selectedOptionIndex == idx;
                        final isCorrect = idx == quiz.correctIndex;

                        Color bgColor = Colors.white;
                        Color borderColor = Colors.grey.shade300;
                        IconData? trailingIcon;

                        if (isSelected) {
                          if (isCorrect) {
                            bgColor = const Color(0xFFDCFCE7);
                            borderColor = const Color(0xFF16A34A);
                            trailingIcon = Icons.check_circle_rounded;
                          } else {
                            bgColor = const Color(0xFFFEF3C7);
                            borderColor = const Color(0xFFD97706);
                            trailingIcon = Icons.lightbulb_outline_rounded;
                          }
                        }

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              setState(() {
                                entry.selectedOptionIndex = idx;
                                _currentEmotion = isCorrect
                                    ? AvatarEmotion.celebrating
                                    : AvatarEmotion.encouraging;
                              });
                              if (_selectedDoc != null) {
                                _lessonCache.saveChatHistory(
                                  widget.session.email,
                                  _selectedDoc!.name,
                                  _messages,
                                );
                              }
                              if (_autoSpeak) {
                                final feedbackText = isCorrect
                                    ? 'أحسنت! إجابتك صحيحة تماماً!'
                                    : 'فكر مرة أخرى! ${quiz.hint}';
                                _speakText(
                                  feedbackText,
                                  speechId:
                                      'fb_${entry.timestamp.millisecondsSinceEpoch}_$idx',
                                );
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: bgColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: borderColor,
                                  width: 1.4,
                                ),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 13,
                                    backgroundColor: const Color(0xFFEEF2FF),
                                    child: Text(
                                      '${idx + 1}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF4F46E5),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      quiz.options[idx],
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                  if (trailingIcon != null)
                                    Icon(
                                      trailingIcon,
                                      color: isCorrect
                                          ? const Color(0xFF16A34A)
                                          : const Color(0xFFD97706),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      if (entry.selectedOptionIndex != null) ...[
                        const SizedBox(height: 8),
                        if (entry.selectedOptionIndex == quiz.correctIndex)
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                '🎉 أحسنت! إجابتك صحيحة تماماً!',
                                style: TextStyle(
                                  color: Color(0xFF15803D),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _askingTutor
                                    ? null
                                    : () => _sendQuestion(
                                        'أجبت بشكل صحيح! اشرح لي الفقرة التالية من الدرس واختبرني فيها',
                                      ),
                                icon: const Icon(
                                  Icons.skip_next_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  res.hasMorePartsInPage
                                      ? 'اشرح الفقرة التالية (${res.currentPart! + 1}/${res.totalPartsInPage})'
                                      : 'أنهينا الصفحة! اشرح الصفحة التالية',
                                ),
                              ),
                            ],
                          )
                        else
                          Text(
                            '💡 تلميح المعلم: ${quiz.hint}',
                            style: const TextStyle(
                              color: Color(0xFFB45309),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageInputBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _questionController,
              enabled: !_askingTutor,
              onSubmitted: (_) => _sendQuestion(),
              decoration: InputDecoration(
                hintText: _askingTutor
                    ? 'جاري تجهيز الشرح...'
                    : 'اكتب سؤالك للمعلم الذكي هنا...',
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _askingTutor ? null : () => _sendQuestion(),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF4F46E5),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            icon: _askingTutor
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded),
            label: Text(_askingTutor ? 'يفكر...' : 'إرسال'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAccountSettingsDialog() async {
    final emailCtrl = TextEditingController(text: widget.session.email);
    final nameCtrl = TextEditingController(text: widget.session.displayName);
    var tempVoice = _selectedVoice;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('إعدادات الصوت والحساب'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'اسم الطالب'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'البريد الإلكتروني (Gmail)',
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: tempVoice,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'صوت المعلم',
                    prefixIcon: Icon(Icons.record_voice_over_rounded),
                  ),
                  items: GeminiTtsService.availableVoices.entries
                      .map(
                        (e) => DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(
                            e.value,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => tempVoice = val);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                setState(() => _selectedVoice = tempVoice);
                final updated = widget.session.copyWith(
                  displayName: nameCtrl.text.trim(),
                  email: emailCtrl.text.trim(),
                  apiKey: GeminiService.defaultTestApiKey,
                );
                await widget.authService.saveSession(updated);
                widget.onSessionUpdated(updated);
                if (ctx.mounted) Navigator.pop(ctx);
                _refreshUploadedPdfs();
                _ttsService.prewarmConnection(
                  session: updated,
                  voiceName: _selectedVoice,
                );
              },
              child: const Text('حفظ التغييرات'),
            ),
          ],
        ),
      ),
    );
  }
}
