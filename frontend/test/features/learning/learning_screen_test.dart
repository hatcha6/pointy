import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';
import 'package:pointy_frontend/src/features/learning/view_models/learning_view_model.dart';
import 'package:pointy_frontend/src/features/learning/views/learning_filter_sheet.dart';
import 'package:pointy_frontend/src/features/learning/views/learning_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  testWidgets('the catalogue lists guides and opens one', (tester) async {
    await _pumpLearning(tester);

    expect(find.text('تعلّم دفتر'), findsOneWidget);
    expect(find.text('كيف يعمل دفتر؟'), findsWidgets);

    await tester.tap(find.text('كيف يعمل دفتر؟').first);
    await tester.pumpAndSettle();

    // The reader shows the guide's own section headings, not just its title.
    expect(find.text('دفتر واحد، لا دفاتر متعددة'), findsOneWidget);
    expect(find.textContaining('نسميه «الخادم»'), findsOneWidget);
  });

  testWidgets('searching narrows the list to matching guides', (tester) async {
    final viewModel = await _pumpLearning(tester);

    await tester.enterText(find.byType(TextField).first, 'اجل');
    // The search field debounces, so let the timer fire before asserting.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(viewModel.results, isNotEmpty);
    expect(
      viewModel.results.map((guide) => guide.id),
      contains('money.credit_sale'),
    );
    expect(find.text('البيع الآجل (الدَّين)'), findsWidgets);
    expect(find.text('إعداد الطابعات وأدوارها'), findsNothing);
  });

  testWidgets('a track chip filters the catalogue', (tester) async {
    final viewModel = await _pumpLearning(tester, size: const Size(900, 1600));

    await tester.tap(find.widgetWithText(ChoiceChip, 'البيع'));
    await tester.pumpAndSettle();

    expect(viewModel.results, isNotEmpty);
    expect(
      viewModel.results.every((guide) => guide.track == LearningTrack.selling),
      isTrue,
    );
    expect(find.text('إعداد الطابعات وأدوارها'), findsNothing);
  });

  testWidgets('the filter sheet applies a sort and filters', (tester) async {
    final viewModel = await _pumpLearning(tester);

    await tester.tap(find.byIcon(Icons.tune).first);
    await tester.pumpAndSettle();

    // Scope every finder to the sheet: the catalogue behind it carries the
    // same level words on its cards.
    final sheet = find.byType(LearningFilterSheet);
    final sheetScrollable = find
        .descendant(of: sheet, matching: find.byType(Scrollable))
        .first;
    Finder inSheet(String text) =>
        find.descendant(of: sheet, matching: find.text(text));

    Future<void> tapInSheet(String text) async {
      await tester.scrollUntilVisible(
        inSheet(text),
        200,
        scrollable: sheetScrollable,
      );
      await tester.tap(inSheet(text));
      await tester.pump();
    }

    await tapInSheet('مبتدئ');
    await tapInSheet('الأقصر أولًا');
    await tapInSheet('تطبيق');
    await tester.pumpAndSettle();

    expect(viewModel.results, isNotEmpty);
    expect(
      viewModel.results.every((guide) => guide.level == LearningLevel.beginner),
      isTrue,
    );
    final minutes = viewModel.results.map((guide) => guide.minutes).toList();
    expect(minutes, orderedEquals(List.of(minutes)..sort()));
  });

  testWidgets('a search with no match offers a way back', (tester) async {
    await _pumpLearning(tester);

    await tester.enterText(find.byType(TextField).first, 'زرافة');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.textContaining('لا توجد نتائج'), findsOneWidget);
    expect(find.text('مسح البحث'), findsWidgets);
  });
}

Future<LearningViewModel> _pumpLearning(
  WidgetTester tester, {
  Size size = const Size(430, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final viewModel = LearningViewModel(
    capabilities: AuthorizationCapabilities.forUser(_managerUser),
    userId: _managerUser.id,
  );

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
      home: LearningScreen(viewModel: viewModel, navigation: _FakeNavigation()),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

const _managerUser = PosUser(
  id: 1,
  username: 'manager',
  role: UserRole.manager,
  isActive: true,
);

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => _managerUser;

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(_managerUser);

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
