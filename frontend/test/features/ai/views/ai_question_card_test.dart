import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/ai_chat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/ai/view_models/ai_chat_view_model.dart';
import 'package:pointy_frontend/src/features/ai/views/ai_assistant_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/async_selection/async_multi_select_picker.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

/// Emits one ask_user question, then captures the resume answers.
class _AskRepo extends AiChatRepository {
  _AskRepo(this.questions) : super(PosApiService());

  final List<AiQuestion> questions;
  List<AiAnswer> resumeAnswers = const [];
  bool resumeCalled = false;
  bool resumeDeclined = false;

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    yield AiChatAskUser(
      conversationId: 1,
      messageId: 42,
      toolCallId: 'call_1',
      questions: questions,
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
    resumeCalled = true;
    resumeAnswers = answers;
    resumeDeclined = declined;
    yield const AiChatDone(conversationId: 1);
  }

  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('none'));

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({int page = 1}) async =>
      const Ok([]);
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

Future<AsyncSelectionPage<int>> _fakeProductSearch(String search, int page) async {
  return const AsyncSelectionPage<int>(
    options: [
      AsyncSelectionOption<int>(id: 10, label: 'حليب المراعي ١ لتر', subtitle: '6291000111'),
      AsyncSelectionOption<int>(id: 11, label: 'حليب نادك ١ لتر', subtitle: '6291000222'),
    ],
    hasMore: false,
  );
}

Future<void> _pump(
  WidgetTester tester,
  AiChatViewModel viewModel, {
  AiProductSearch? productSearch,
}) async {
  await tester.pumpWidget(
    MaterialApp(
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
      home: AiAssistantScreen(
        viewModel: viewModel,
        navigation: _FakeNavigation(),
        productSearch: productSearch,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('single-select card resumes with the chosen option', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'branch',
        type: AiQuestionType.singleSelect,
        prompt: 'أي فرع؟',
        config: const {
          'options': [
            {'value': 'main', 'label': 'الرئيسي'},
            {'value': 'city', 'label': 'المدينة'},
          ],
        },
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    // The card renders the prompt + options + the submit/skip actions.
    expect(find.text('أي فرع؟'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'الرئيسي'), findsOneWidget);
    expect(find.text('إرسال الإجابة'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'الرئيسي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.questionId, 'branch');
    expect(repo.resumeAnswers.single.value, 'main');
    // The card flips to a read-only summary showing the chosen option's label.
    expect(find.text('تم إرسال إجابتك'), findsOneWidget);
    expect(find.text('الرئيسي'), findsWidgets);
  });

  testWidgets('a required question blocks submit until answered', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'name',
        type: AiQuestionType.freeText,
        prompt: 'اسم المنتج؟',
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    // Submitting empty surfaces the required error and does not resume.
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();
    expect(find.text('هذا السؤال مطلوب'), findsOneWidget);
    expect(repo.resumeCalled, isFalse);

    // The card's field is first in the tree; the composer's (disabled) is last.
    await tester.enterText(find.byType(TextField).first, 'عصير');
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();
    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.value, 'عصير');
  });

  testWidgets('single-select "other" submits the typed custom value', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'branch',
        type: AiQuestionType.singleSelect,
        prompt: 'أي فرع؟',
        config: const {
          'options': [
            {'value': 'main', 'label': 'الرئيسي'},
          ],
          'allow_other': true,
        },
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'أخرى…'));
    await tester.pumpAndSettle();
    // The revealed "other" field is first; the (disabled) composer field is last.
    await tester.enterText(find.byType(TextField).first, 'فرع جديد');
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.value, 'فرع جديد');
    expect(repo.resumeAnswers.single.isOther, isTrue);
  });

  testWidgets('number question resumes with the parsed value', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'qty',
        type: AiQuestionType.number,
        prompt: 'كم الكمية؟',
        config: const {'min': 1, 'max': 100},
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '7');
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.value, 7);
  });

  testWidgets('product picker "create new" resumes with is_other', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'line1',
        type: AiQuestionType.productPicker,
        prompt: 'لم أجد «حليب المراعي» — اختره أو أنشئه',
        config: const {'name': 'حليب المراعي', 'suggested_price': '3.25'},
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel, productSearch: _fakeProductSearch);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنشاء منتج جديد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.questionId, 'line1');
    expect(repo.resumeAnswers.single.isOther, isTrue);
    // The summary reflects the "new product" choice (localized).
    expect(find.text('سيُنشأ منتج جديد'), findsWidgets);
  });

  testWidgets('product picker confirms a pre-suggested candidate with one tap', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'line1',
        type: AiQuestionType.productPicker,
        prompt: 'راجع البند غير المطابق',
        config: const {
          'name': 'كابل يو اس بي سي',
          'deny_label': 'أنشئ منتجًا جديدًا',
          'options': [
            {'value': '23', 'label': 'كابل USB-C — 8.00 د.ل'},
          ],
        },
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel, productSearch: _fakeProductSearch);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    // The candidate renders as a one-tap option — no need to open the search.
    expect(find.text('كابل USB-C — 8.00 د.ل'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai_product_candidate_line1_23')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.value, 23);
    expect(repo.resumeAnswers.single.isOther, isFalse);
  });

  testWidgets('product picker resumes with the chosen variant id', (tester) async {
    final repo = _AskRepo([
      AiQuestion(
        id: 'line1',
        type: AiQuestionType.productPicker,
        prompt: 'اختر المنتج',
        config: const {'name': 'حليب'},
      ),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel, productSearch: _fakeProductSearch);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    // Open the async picker sheet, choose a product, apply, then submit.
    await tester.tap(find.text('ابحث واختر منتجًا'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حليب المراعي ١ لتر'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai_product_picker_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرسال الإجابة'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeAnswers.single.value, 10);
    expect(repo.resumeAnswers.single.isOther, isFalse);
  });

  testWidgets('skip resumes with a declined result', (tester) async {
    final repo = _AskRepo([
      AiQuestion(id: 'go', type: AiQuestionType.confirm, prompt: 'أتابع؟'),
    ]);
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    await tester.tap(find.text('تخطّي'));
    await tester.pumpAndSettle();

    expect(repo.resumeCalled, isTrue);
    expect(repo.resumeDeclined, isTrue);
  });
}
