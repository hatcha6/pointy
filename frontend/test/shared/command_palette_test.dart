import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/command_palette/command_palette.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingNavigation implements AppNavigation {
  final List<AppNavigationDestination> navigated = [];

  @override
  final PosUser currentUser = PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'role': 'manager',
    'permissions': <String>[],
  });

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(currentUser);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {
    navigated.add(destination);
  }

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

/// A fake async source so we can exercise debounced entity search without a
/// backend.
AsyncCommandSource<String> _fakeAsyncSource(List<String> data) {
  return AsyncCommandSource<String>(
    labelBuilder: (l10n) => l10n.commandPaletteProductsSection,
    fetch: (query) async =>
        data.where((value) => value.contains(query)).toList(growable: false),
    toItem: (value) => CommandItem(
      id: 'entity-$value',
      icon: Icons.inventory_2_outlined,
      title: value,
      onSelect: (_) {},
    ),
  );
}

Widget _harness(List<CommandSource> sources) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: CommandPaletteScope(
      key: commandPaletteScopeKey,
      sources: sources,
      child: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: openCommandPalette,
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    commandPaletteRecents.clear();
  });

  testWidgets('opens, filters by query, and navigates on selection', (
    tester,
  ) async {
    final navigation = _RecordingNavigation();
    await tester.pumpWidget(_harness([NavigationCommandSource(navigation)]));
    final l10n = AppLocalizations.of(tester.element(find.text('open')))!;

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Palette is open and lists capability-gated destinations.
    expect(find.text(l10n.commandPaletteScreensSection), findsOneWidget);
    expect(find.text(l10n.dashboardDrawerLabel), findsOneWidget);
    expect(find.text(l10n.posDrawerLabel), findsOneWidget);

    // Typing filters the list down to matching destinations only. (Filter by a
    // latin keyword so the query text in the field can't collide with the row's
    // Arabic label.)
    await tester.enterText(find.byType(TextField), 'pos');
    await tester.pumpAndSettle();
    expect(find.text(l10n.posDrawerLabel), findsOneWidget);
    expect(find.text(l10n.dashboardDrawerLabel), findsNothing);

    // Selecting a row closes the palette and routes to its destination.
    await tester.tap(find.text(l10n.posDrawerLabel));
    await tester.pumpAndSettle();
    expect(navigation.navigated, contains(AppNavigationDestination.pos));
  });

  testWidgets('keyword search matches latin aliases', (tester) async {
    final navigation = _RecordingNavigation();
    await tester.pumpWidget(_harness([NavigationCommandSource(navigation)]));
    final l10n = AppLocalizations.of(tester.element(find.text('open')))!;

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // "pos" is a latin keyword alias for the (Arabic-labelled) POS screen.
    await tester.enterText(find.byType(TextField), 'pos');
    await tester.pumpAndSettle();
    expect(find.text(l10n.posDrawerLabel), findsOneWidget);
    expect(find.text(l10n.dashboardDrawerLabel), findsNothing);
  });

  testWidgets('debounced entity search renders an async results section', (
    tester,
  ) async {
    final navigation = _RecordingNavigation();
    await tester.pumpWidget(
      _harness([
        NavigationCommandSource(navigation),
        _fakeAsyncSource(['قهوة عربية', 'شاي أخضر']),
      ]),
    );
    final l10n = AppLocalizations.of(tester.element(find.text('open')))!;

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Entity search is debounced; before the timer fires nothing has loaded.
    await tester.enterText(find.byType(TextField), 'قهوة');
    await tester.pump(); // process onChanged
    expect(find.text('قهوة عربية'), findsNothing);

    // After the debounce window the async section appears.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text(l10n.commandPaletteProductsSection), findsOneWidget);
    expect(find.text('قهوة عربية'), findsOneWidget);
    expect(find.text('شاي أخضر'), findsNothing);
  });

  testWidgets('quick actions show on the empty query and run on selection', (
    tester,
  ) async {
    var ran = false;
    final actions = StaticCommandSource(
      label: 'الإجراءات',
      items: [
        CommandItem(
          id: 'a1',
          icon: Icons.add,
          title: 'إجراء تجريبي',
          keywords: const ['demo'],
          onSelect: (_) => ran = true,
        ),
      ],
    );
    await tester.pumpWidget(
      _harness([actions, NavigationCommandSource(_RecordingNavigation())]),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Visible on the empty query, under the actions section.
    expect(find.text('الإجراءات'), findsOneWidget);
    expect(find.text('إجراء تجريبي'), findsOneWidget);

    // Reachable by latin keyword, and runs on tap.
    await tester.enterText(find.byType(TextField), 'demo');
    await tester.pumpAndSettle();
    await tester.tap(find.text('إجراء تجريبي'));
    await tester.pumpAndSettle();
    expect(ran, isTrue);
  });

  testWidgets('opened entities are remembered under recents', (tester) async {
    final navigation = _RecordingNavigation();
    final products = AsyncCommandSource<String>(
      labelBuilder: (l10n) => l10n.commandPaletteProductsSection,
      fetch: (query) async =>
          ['قهوة عربية'].where((value) => value.contains(query)).toList(),
      toItem: (value) => CommandItem(
        id: 'product-$value',
        icon: Icons.inventory_2_outlined,
        title: value,
        recent: RecentEntry(kind: RecentKind.product, id: 1, title: value),
        onSelect: (_) {},
      ),
    );
    await tester.pumpWidget(
      _harness([
        RecentsCommandSource(label: 'الأخيرة', onOpen: (context, entry) {}),
        NavigationCommandSource(navigation),
        products,
      ]),
    );
    await tester.pumpAndSettle();

    // Open the palette, search for and select a product.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'قهوة');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('قهوة عربية'));
    await tester.pumpAndSettle();

    // Reopen on the empty query: the product is now under recents.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('الأخيرة'), findsOneWidget);
    expect(find.text('قهوة عربية'), findsOneWidget);
  });

  testWidgets('a row action runs without triggering the primary open', (
    tester,
  ) async {
    var opened = false;
    var printed = false;
    final products = AsyncCommandSource<String>(
      labelBuilder: (l10n) => l10n.commandPaletteProductsSection,
      fetch: (query) async =>
          ['قهوة عربية'].where((value) => value.contains(query)).toList(),
      toItem: (value) => CommandItem(
        id: 'product-$value',
        icon: Icons.inventory_2_outlined,
        title: value,
        actions: [
          CommandRowAction(
            icon: Icons.print_outlined,
            tooltip: 'طباعة',
            onRun: (_) => printed = true,
          ),
        ],
        onSelect: (_) => opened = true,
      ),
    );
    await tester.pumpWidget(
      _harness([NavigationCommandSource(_RecordingNavigation()), products]),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'قهوة');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    // Tapping the action runs it and closes the palette — not the row's open.
    await tester.tap(find.byTooltip('طباعة'));
    await tester.pumpAndSettle();
    expect(printed, isTrue);
    expect(opened, isFalse);
  });

  testWidgets('Tab focuses a row action and Enter runs it (keyboard-only)', (
    tester,
  ) async {
    var opened = false;
    var printed = false;
    final products = AsyncCommandSource<String>(
      labelBuilder: (l10n) => l10n.commandPaletteProductsSection,
      fetch: (query) async =>
          ['قهوة عربية'].where((value) => value.contains(query)).toList(),
      toItem: (value) => CommandItem(
        id: 'product-$value',
        icon: Icons.inventory_2_outlined,
        title: value,
        actions: [
          CommandRowAction(
            icon: Icons.print_outlined,
            tooltip: 'طباعة',
            onRun: (_) => printed = true,
          ),
        ],
        onSelect: (_) => opened = true,
      ),
    );
    await tester.pumpWidget(
      _harness([NavigationCommandSource(_RecordingNavigation()), products]),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'قهوة');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    // The single result is selected; Tab focuses its action and Enter runs it,
    // not the row's primary open.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(printed, isTrue);
    expect(opened, isFalse);
  });

  testWidgets('shows an empty state when nothing matches', (tester) async {
    final navigation = _RecordingNavigation();
    await tester.pumpWidget(_harness([NavigationCommandSource(navigation)]));
    final l10n = AppLocalizations.of(tester.element(find.text('open')))!;

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzzzzznotathing');
    await tester.pumpAndSettle();
    expect(find.text(l10n.commandPaletteNoResults), findsOneWidget);
  });
}
