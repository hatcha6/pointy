// Dev-only preview harness for the AI assistant route.
//
// Renders the AI assistant screen full-viewport with an in-memory fake
// repository (no backend, no auth, no relay). A scripted reply streams in
// token-by-token so the live-typing UI can be screenshotted. Pick a surface
// with a `?screen=` query param and resize the browser to test responsiveness.
// Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/ai_chat_preview.dart
//
// Screens:
//   chat        — auto-streams a reply (default)
//   compose     — composer carrying pending attachments + the usage ring
//   attachments — a sent turn with an image thumbnail + a file chip
//   empty       — the empty state
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/ai_chat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/ai/ai_attachment_picker.dart';
import 'package:pointy_frontend/src/features/ai/view_models/ai_chat_view_model.dart';
import 'package:pointy_frontend/src/features/ai/views/ai_assistant_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _PreviewHost(screen: _screen()),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'chat';
}

class _PreviewHost extends StatefulWidget {
  const _PreviewHost({required this.screen});

  final String screen;

  @override
  State<_PreviewHost> createState() => _PreviewHostState();
}

class _PreviewHostState extends State<_PreviewHost> {
  late final AiChatViewModel _viewModel = AiChatViewModel(
    _FakeAiChatRepository(),
    picker: _FakeAttachmentPicker(),
  );
  final AppNavigation _navigation = _FakeNavigation();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  Future<void> _run() async {
    await _viewModel.loadUsage();
    switch (widget.screen) {
      case 'empty':
        return;
      case 'compose':
        await _viewModel.addImage(fromCamera: false);
        await _viewModel.addFiles();
      case 'attachments':
        await _viewModel.addImage(fromCamera: false);
        await _viewModel.addFiles();
        await _viewModel.sendMessage('لخّص لي هذه الفاتورة من فضلك');
      case 'long':
        // Seed several settled markdown turns, then stream a new reply — the
        // exact "3+ messages" scenario that used to jank (every token re-parsed
        // every prior reply). Used to verify streaming stays smooth at length.
        await _viewModel.openConversation(1);
        await _viewModel.sendMessage('وكم كانت مبيعات الأسبوع الماضي تقريبًا؟');
      default:
        await _viewModel.sendMessage('كيف أضيف منتجًا جديدًا إلى المتجر؟');
    }
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AiAssistantScreen(viewModel: _viewModel, navigation: _navigation);
  }
}

/// Streams a scripted Arabic reply with per-word delays so the live-typing
/// cursor and bubbles can be screenshotted.
class _FakeAiChatRepository extends AiChatRepository {
  _FakeAiChatRepository() : super(PosApiService());

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    // A scripted tool round so the "querying sales…" chip can be screenshotted.
    yield const AiChatToolActivity(
      name: 'query_resource',
      resource: 'orders',
      label: 'فواتير ومبيعات نقطة البيع',
      phase: 'start',
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    yield const AiChatToolActivity(
      name: 'query_resource',
      resource: 'orders',
      label: 'فواتير ومبيعات نقطة البيع',
      phase: 'done',
      ok: true,
    );
    const reasoning =
        'المستخدم يسأل عن إضافة منتج جديد. سأشرح الخطوات من شاشة الكتالوج '
        'بالترتيب: الزر، ثم الحقول الأساسية، ثم الحفظ.';
    for (final word in reasoning.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 45));
      yield AiChatReasoning('$word ');
    }
    // Markdown-rich reply so the gpt_markdown rendering can be screenshotted.
    const reply =
        '## ملخص مبيعات آخر 30 يومًا\n\n'
        'إليك أبرز الأرقام:\n\n'
        '- **إجمالي المبيعات:** 12,127 د.ل\n'
        '- **عدد الطلبات:** 118 طلب\n'
        '- *متوسط قيمة الطلب:* ~103 د.ل\n\n'
        '### أكثر المنتجات مبيعًا\n\n'
        '| المنتج | الكمية |\n'
        '| --- | --- |\n'
        '| أرز ٥ كجم | 59 |\n'
        '| ماوس لاسلكي | 58 |\n'
        '| ساندويتش فلافل | 57 |\n\n'
        '> تنبيه: نفد مخزون "سماعات لاسلكية" — يُنصح بإعادة الطلب.\n\n'
        'يمكنك تكرار التحليل عبر استدعاء `aggregate` متى شئت.';
    for (final word in reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      yield AiChatDelta('$word ');
    }
    yield AiChatDone(
      conversationId: 1,
      messageId: 2,
      userMessageId: 1,
      model: 'preview/model',
      usage: _fakeUsage(fiveUsed: 24, weekUsed: 97),
    );
  }

  @override
  Future<Result<AiUsage>> loadUsage() async {
    return Ok(_fakeUsage(fiveUsed: 23, weekUsed: 96));
  }

  @override
  Future<Result<bool>> truncateConversation(
    int conversationId,
    int messageId,
  ) async {
    return const Ok(true);
  }

  @override
  Future<Result<AiConversation>> loadConversation(int id) async {
    AiMessage user(String content) =>
        AiMessage(role: AiMessageRole.user, content: content);
    AiMessage bot(String content) =>
        AiMessage(role: AiMessageRole.assistant, content: content);
    return Ok(
      AiConversation(
        id: id,
        title: 'تحليل المبيعات',
        messages: [
          user('كم عدد المنتجات في المتجر؟'),
          bot(
            'لديك حاليًا **٢٥ منتجًا** موزعة على ٥ فئات:\n\n'
            '- خضار وفواكه\n- مشروبات\n- وجبات\n- إلكترونيات\n- منظفات',
          ),
          user('ما هي أكثر ٣ منتجات مبيعًا؟'),
          bot(
            '## الأكثر مبيعًا\n\n'
            '| المنتج | الكمية |\n| --- | --- |\n'
            '| أرز ٥ كجم | 59 |\n| ماوس لاسلكي | 58 |\n| ساندويتش فلافل | 57 |',
          ),
          user('اعطني ملخصًا سريعًا لأداء اليوم'),
          bot(
            '### ملخص اليوم\n\n'
            '- **المبيعات:** 1,240 د.ل\n- **الطلبات:** 18\n'
            '- *متوسط الطلب:* ~69 د.ل\n\n'
            '> الأداء أعلى من متوسط الأسبوع بنسبة 12%.',
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({
    int page = 1,
  }) async {
    return const Ok([
      AiConversationSummary(id: 1, title: 'إضافة منتج جديد', messageCount: 4),
      AiConversationSummary(
        id: 2,
        title: 'تقرير مبيعات اليوم',
        messageCount: 2,
      ),
      AiConversationSummary(id: 3, title: 'كيف أغلق الوردية؟', messageCount: 6),
    ]);
  }
}

AiUsage _fakeUsage({required int fiveUsed, required int weekUsed}) {
  return AiUsage(
    fiveHour: AiUsageWindow(
      used: fiveUsed,
      limit: 30,
      resetAt: DateTime.now().add(const Duration(hours: 2, minutes: 40)),
    ),
    weekly: AiUsageWindow(
      used: weekUsed,
      limit: 200,
      resetAt: DateTime.now().add(const Duration(days: 4)),
    ),
  );
}

/// Returns canned attachments (a generated colour swatch + a PDF chip) so the
/// composer strip and sent-turn thumbnails render without a real picker.
class _FakeAttachmentPicker extends AiAttachmentPicker {
  @override
  Future<AiAttachment?> pickImage({required bool fromCamera}) async {
    return AiAttachment(
      kind: AiAttachmentKind.image,
      dataUri: 'data:image/png;base64,preview',
      name: 'receipt.png',
      mime: 'image/png',
      previewBytes: _swatch(0x4F, 0x8D, 0xF5),
    );
  }

  @override
  Future<List<AiAttachment>> pickFiles() async {
    return [
      AiAttachment(
        kind: AiAttachmentKind.file,
        dataUri: 'data:application/pdf;base64,preview',
        name: 'invoice-2026-06.pdf',
        mime: 'application/pdf',
      ),
    ];
  }
}

Uint8List _swatch(int r, int g, int b) {
  final image = img.Image(width: 96, height: 96);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodePng(image);
}

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => const PosUser(
    id: 1,
    username: 'manager',
    role: UserRole.manager,
    isActive: true,
    aiAvailable: true,
  );

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(currentUser);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}
