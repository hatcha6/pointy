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
import 'package:pointy_frontend/src/shared/async_selection/async_multi_select_picker.dart';
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
    _FakeAiChatRepository(
      askUserMode: widget.screen == 'ask',
      actionsMode: widget.screen == 'actions',
      pickerMode: widget.screen == 'po',
      linksMode: widget.screen == 'links',
      webMode: widget.screen == 'web',
    ),
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
      case 'ask':
        // The assistant asks an interactive question (all 5 types) and pauses.
        await _viewModel.sendMessage('أضف منتجًا جديدًا إلى المتجر');
      case 'actions':
        // The assistant performs a composite create (product + recipe) so the
        // accented, persistent "action" chips can be screenshotted next to a
        // muted read chip.
        await _viewModel.sendMessage('أضف برغر لحم إلى قائمة المطعم');
      case 'po':
        // A supplier-invoice flow that asks a product_picker question for an
        // unmatched line (search existing product, or create new).
        await _viewModel.sendMessage('أنشئ أمر شراء من هذه الفاتورة');
      case 'links':
        // A reply peppered with in-app deep links (tap to navigate).
        await _viewModel.sendMessage('أين أجد منتج القهوة وآخر فاتورة؟');
      case 'web':
        // A web-searched reply with source favicons next to the copy action.
        await _viewModel.sendMessage('كم سعر الذهب اليوم؟');
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
    return AiAssistantScreen(
      viewModel: _viewModel,
      navigation: _navigation,
      productSearch: _fakeProductSearch,
      onOpenAiLink: (context, link) async {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فتح: $link'), duration: const Duration(seconds: 1)),
        );
        return true;
      },
    );
  }

  /// A handful of fake products so the product_picker sheet can be exercised.
  Future<AsyncSelectionPage<int>> _fakeProductSearch(String search, int page) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    const all = [
      (10, 'حليب المراعي ١ لتر', 'MILK-1L • 6291000111'),
      (11, 'حليب نادك ١ لتر', 'MILK-N1L • 6291000222'),
      (12, 'حليب المراعي ٢٠٠ مل', 'MILK-200 • 6291000333'),
    ];
    final query = search.trim();
    final matches = query.isEmpty
        ? all
        : all.where((p) => p.$2.contains(query)).toList();
    return AsyncSelectionPage<int>(
      options: [
        for (final product in matches)
          AsyncSelectionOption<int>(
            id: product.$1,
            label: product.$2,
            subtitle: product.$3,
          ),
      ],
      hasMore: false,
    );
  }
}

/// Streams a scripted Arabic reply with per-word delays so the live-typing
/// cursor and bubbles can be screenshotted.
class _FakeAiChatRepository extends AiChatRepository {
  _FakeAiChatRepository({
    this.askUserMode = false,
    this.actionsMode = false,
    this.pickerMode = false,
    this.linksMode = false,
    this.webMode = false,
  }) : super(PosApiService());

  /// When set, the scripted reply asks an interactive question (all 5 types)
  /// instead of answering, so the ask_user card can be screenshotted.
  final bool askUserMode;

  /// When set, the scripted reply performs a composite create (product +
  /// recipe), so the accented action chips can be screenshotted.
  final bool actionsMode;

  /// When set, the scripted reply asks a product_picker question (an unmatched
  /// invoice line), so the picker card can be screenshotted.
  final bool pickerMode;

  /// When set, the scripted reply contains in-app deep links (pointy://…).
  final bool linksMode;

  /// When set, the scripted reply used web search — done carries sources, so the
  /// favicon indicator + sources sheet can be screenshotted.
  final bool webMode;

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    if (askUserMode) {
      yield* _askUserScript();
      return;
    }
    if (actionsMode) {
      yield* _actionsScript();
      return;
    }
    if (pickerMode) {
      yield* _pickerScript();
      return;
    }
    if (webMode) {
      const reply =
          'حسب آخر البيانات، ارتفع سعر الذهب عالميًا اليوم بنحو 1.2% ليصل إلى '
          'حوالي 2,380 دولارًا للأونصة، مدفوعًا بتراجع الدولار وترقّب قرارات الفائدة.';
      for (final word in reply.split(' ')) {
        await Future<void>.delayed(const Duration(milliseconds: 35));
        yield AiChatDelta('$word ');
      }
      yield AiChatDone(
        conversationId: 1,
        messageId: 2,
        userMessageId: 1,
        model: 'preview/model',
        usage: _fakeUsage(fiveUsed: 24, weekUsed: 97),
        webSearched: true,
        sources: const [
          AiSource(url: 'https://www.reuters.com/markets/gold', title: 'Reuters — Gold rises as dollar slips'),
          AiSource(url: 'https://www.bloomberg.com/gold', title: 'Bloomberg — Precious metals'),
          AiSource(url: 'https://goldprice.org/', title: 'GoldPrice.org — Live spot price'),
          AiSource(url: 'https://www.kitco.com/', title: 'Kitco — Gold market news'),
        ],
      );
      return;
    }
    if (linksMode) {
      const reply =
          'وجدت ما تبحث عنه:\n\n'
          '- المنتج: [قهوة عربية](pointy://product/42) — راجع المخزون والسعر.\n'
          '- آخر فاتورة: [الفاتورة ٩٩](pointy://order/99).\n'
          '- المورّد: [بُن اليمن](pointy://supplier/7).\n\n'
          'يمكنك أيضًا فتح [صفحة المشتريات](pointy://screen/purchasing) لمتابعة الطلبات.';
      for (final word in reply.split(' ')) {
        await Future<void>.delayed(const Duration(milliseconds: 35));
        yield AiChatDelta('$word ');
      }
      yield AiChatDone(
        conversationId: 1,
        messageId: 2,
        userMessageId: 1,
        model: 'preview/model',
        usage: _fakeUsage(fiveUsed: 24, weekUsed: 97),
      );
      return;
    }
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

  /// Streams a composite create flow — a muted read query followed by two
  /// accented, persistent create actions, then a markdown summary — so the
  /// action-chip styling can be screenshotted next to a read chip.
  Stream<AiChatEvent> _actionsScript() async* {
    const reasoning = 'مطعم — سأنشئ المنتج ثم وصفته ومكوّناته ليكتمل خصم المخزون.';
    for (final word in reasoning.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      yield AiChatReasoning('$word ');
    }
    // A read query first (muted, transient styling).
    yield const AiChatToolActivity(
      name: 'query_resource',
      resource: 'products',
      label: 'منتجات الكتالوج',
      phase: 'start',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    yield const AiChatToolActivity(
      name: 'query_resource',
      resource: 'products',
      label: 'منتجات الكتالوج',
      phase: 'done',
      ok: true,
      arguments: {'resource': 'products', 'search': 'برغر'},
      output: '{\n  "ok": true,\n  "data": { "count": 0, "results": [] }\n}',
    );
    // Then the create actions (accented, persistent styling).
    for (final action in const [
      ('إنشاء: منتجات الكتالوج', 'products'),
      ('إنشاء: الوصفات والمكوّنات', 'boms'),
    ]) {
      yield AiChatToolActivity(
        name: 'create_resource',
        resource: action.$2,
        label: action.$1,
        phase: 'start',
        mutates: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      yield AiChatToolActivity(
        name: 'create_resource',
        resource: action.$2,
        label: action.$1,
        phase: 'done',
        ok: true,
        mutates: true,
        arguments: {'resource': action.$2, 'data': {'name': 'برغر لحم'}},
        output: '{\n  "ok": true,\n  "data": { "id": 42, "name": "برغر لحم" }\n}',
      );
    }
    const reply =
        '## تم إنشاء المنتج ✅\n\n'
        'أنشأت المنتج **«برغر لحم»** بسعر 12 د.ل، مع:\n\n'
        '- **وصفة** من ٣ مكوّنات: خبز، لحم، جبن\n'
        '- يُخصم المخزون تلقائيًا من المكوّنات عند كل عملية بيع\n\n'
        'هل تريد إضافة صورة للمنتج أو تعديل السعر؟';
    for (final word in reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
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

  /// Streams a supplier-invoice flow: a read of the catalogue, then a
  /// product_picker question for a line that didn't match an existing product.
  Stream<AiChatEvent> _pickerScript() async* {
    yield const AiChatToolActivity(
      name: 'match_invoice_products',
      resource: null,
      label: 'مطابقة منتجات الفاتورة',
      phase: 'start',
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    yield const AiChatToolActivity(
      name: 'match_invoice_products',
      resource: null,
      label: 'مطابقة منتجات الفاتورة',
      phase: 'done',
      ok: true,
    );
    const reasoning = 'طابقتُ معظم البنود؛ بقي بند واحد لم أجد له منتجًا مطابقًا.';
    for (final word in reasoning.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      yield AiChatReasoning('$word ');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    yield AiChatAskUser(
      conversationId: 1,
      messageId: 77,
      toolCallId: 'call_po',
      questions: [
        AiQuestion(
          id: 'line3',
          type: AiQuestionType.productPicker,
          prompt: 'راجع البند «حليب المراعي ١ لتر» — هل المطابق هو أحد المنتجات أدناه؟',
          help: 'الكمية 12 — التكلفة 2.50 د.ل — سعر بيع مقترح 3.25 د.ل',
          config: const {
            'name': 'حليب المراعي ١ لتر',
            'barcode': '6291000111',
            'unit_cost': '2.50',
            'suggested_price': '3.25',
            'deny_label': 'أنشئ منتجًا جديدًا',
            // A pre-suggested candidate the AI matched — one tap to confirm.
            'options': [
              {'value': '10', 'label': 'حليب المراعي ١ لتر (باركود: 6291000111، السعر الحالي: 3.00 د.ل)'},
            ],
          },
        ),
      ],
    );
  }

  /// Streams a short reasoning preamble then an ask_user question carrying one
  /// of every question type, so the whole card can be screenshotted at once.
  Stream<AiChatEvent> _askUserScript() async* {
    const reasoning = 'أحتاج بعض التفاصيل قبل إضافة المنتج، سأسأل المستخدم.';
    for (final word in reasoning.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      yield AiChatReasoning('$word ');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    yield AiChatAskUser(
      conversationId: 1,
      messageId: 99,
      toolCallId: 'call_demo',
      questions: [
        AiQuestion(
          id: 'branch',
          type: AiQuestionType.singleSelect,
          prompt: 'إلى أي فرع تضيف المنتج؟',
          config: const {
            'options': [
              {'value': 'main', 'label': 'الفرع الرئيسي'},
              {'value': 'city', 'label': 'فرع المدينة'},
            ],
            'allow_other': true,
          },
        ),
        AiQuestion(
          id: 'cats',
          type: AiQuestionType.multiSelect,
          prompt: 'ما الفئات التي ينتمي إليها؟',
          help: 'يمكنك اختيار أكثر من فئة',
          config: const {
            'options': [
              {'value': 'drinks', 'label': 'مشروبات'},
              {'value': 'food', 'label': 'وجبات'},
              {'value': 'sweets', 'label': 'حلويات'},
            ],
            'allow_other': true,
            'min_select': 1,
          },
        ),
        AiQuestion(
          id: 'name',
          type: AiQuestionType.freeText,
          prompt: 'ما اسم المنتج الجديد؟',
          config: const {'placeholder': 'مثال: عصير برتقال طازج'},
        ),
        AiQuestion(
          id: 'qty',
          type: AiQuestionType.number,
          prompt: 'كم الكمية الأولية في المخزون؟',
          config: const {'min': 1, 'max': 1000, 'unit': 'قطعة'},
        ),
        AiQuestion(
          id: 'confirm',
          type: AiQuestionType.confirm,
          prompt: 'هل أحفظ المنتج فور اكتمال البيانات؟',
        ),
      ],
    );
  }

  @override
  Stream<AiChatEvent> resumeChat({
    required int conversationId,
    required int messageId,
    required String toolCallId,
    List<AiAnswer> answers = const [],
    bool declined = false,
  }) async* {
    final reply = declined
        ? 'لا بأس، أخبرني عندما تكون جاهزًا. 👍'
        : 'ممتاز! سأضيف المنتج بهذه التفاصيل الآن. ✅';
    for (final word in reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 45));
      yield AiChatDelta('$word ');
    }
    yield AiChatDone(
      conversationId: 1,
      messageId: 100,
      model: 'preview/model',
      usage: _fakeUsage(fiveUsed: 25, weekUsed: 98),
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
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}
