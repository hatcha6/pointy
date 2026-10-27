import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/settings/app_settings.dart';
import 'package:pointy_cards/src/data/vault/code_vault.dart';
import 'package:pointy_cards/src/dependencies.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Face ID that counts how often it is asked, and answers [answer].
class _AskingLock extends CodeLock {
  _AskingLock(AppSettings settings) : super(settings: settings);

  bool answer = false;
  int asked = 0;

  @override
  Future<bool> unlock(String reason) async {
    asked++;
    return answer;
  }
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  Future<(AppSettings, _AskingLock)> openAccount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final fixtures = fixtureDependencies(signedIn: false);
    final settings = AppSettings();
    final lock = _AskingLock(settings);
    await tester.pumpWidget(
      CardsApp(
        dependencies: CardsDependencies(
          config: fixtures.config,
          auth: fixtures.auth,
          catalog: fixtures.catalog,
          orders: fixtures.orders,
          vault: fixtures.vault,
          lock: lock,
          settings: settings,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('حسابي').last);
    await tester.pumpAndSettle();
    return (settings, lock);
  }

  Future<void> tapSetting(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    // Clear the tab bar the page scrolls under.
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('signed out, the account tab is still the settings', (
    tester,
  ) async {
    await openAccount(tester);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('الإعدادات'), findsOneWidget);
    expect(find.text('حماية الرموز'), findsOneWidget);
    expect(find.text('المظهر'), findsOneWidget);
    // No language row yet: the catalog only speaks Arabic.
    expect(find.text('اللغة'), findsNothing);
    expect(find.text('English'), findsNothing);
  });

  testWidgets('a language an earlier build saved still opens in Arabic', (
    tester,
  ) async {
    final (settings, _) = await openAccount(tester);
    settings.setLanguage('en');
    await tester.pumpAndSettle();
    expect(find.text('حسابي'), findsWidgets);
    expect(find.text('Account'), findsNothing);
    expect(
      Directionality.of(tester.element(find.text('الإعدادات'))),
      TextDirection.rtl,
    );
  });

  testWidgets('the theme follows the choice', (tester) async {
    await openAccount(tester);
    ThemeMode mode() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;
    expect(mode(), ThemeMode.system);
    await tapSetting(tester, 'داكن');
    expect(mode(), ThemeMode.dark);
    await tapSetting(tester, 'فاتح');
    expect(mode(), ThemeMode.light);
  });

  testWidgets('turning the code lock off takes Face ID; on does not', (
    tester,
  ) async {
    final (settings, lock) = await openAccount(tester);
    final toggle = find.byType(Switch).first;
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();

    // Face ID says no: the lock stays on.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(lock.asked, 1);
    expect(settings.codeLock, isTrue);
    expect(lock.isUnlocked, isFalse);

    // Face ID says yes: off, and saved codes open without asking.
    lock.answer = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.codeLock, isFalse);
    expect(lock.isUnlocked, isTrue);

    // Back on: nothing to confirm.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(lock.asked, 2);
    expect(settings.codeLock, isTrue);
  });

  testWidgets('usage sharing is on until the customer turns it off', (
    tester,
  ) async {
    final (settings, _) = await openAccount(tester);
    expect(settings.shareUsage, isTrue);
    final toggle = find.widgetWithText(
      SwitchListTile,
      'مشاركة بيانات الاستخدام',
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.shareUsage, isFalse);
  });

  test('the choices outlive the app', () async {
    final first = AppSettings(preferences: SharedPreferencesAsync());
    await first.load();
    first
      ..setLanguage('fr')
      ..setThemeMode(ThemeMode.dark)
      ..setCodeLock(false)
      ..setShareUsage(false);
    await Future<void>.delayed(Duration.zero);

    final next = AppSettings(preferences: SharedPreferencesAsync());
    await next.load();
    expect(next.language, 'fr');
    expect(next.themeMode, ThemeMode.dark);
    expect(next.codeLock, isFalse);
    expect(next.shareUsage, isFalse);
  });
}
