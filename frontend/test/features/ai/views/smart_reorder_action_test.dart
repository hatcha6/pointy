import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/ai/views/smart_reorder_action.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';

import '../../../shared/fake_app_navigation.dart';

PosUser _user({
  UserRole role = UserRole.manager,
  bool aiAvailable = true,
}) {
  return PosUser(
    id: 1,
    username: 'u',
    role: role,
    isActive: true,
    aiAvailable: aiAvailable,
  );
}

Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('ar'),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('hidden when AI entitlement is inactive', (tester) async {
    final user = _user(aiAvailable: false);
    final nav = FakeAppNavigation(currentUser: user);
    await tester.pumpWidget(
      _host(
        SmartReorderAction(
          navigation: nav,
          capabilities: nav.capabilities,
          from: AppNavigationDestination.purchasing,
        ),
      ),
    );
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('hidden when the user cannot create purchase orders', (tester) async {
    // A cashier has no createPurchaseOrder capability even with AI available.
    final user = _user(role: UserRole.cashier, aiAvailable: true);
    final nav = FakeAppNavigation(currentUser: user);
    await tester.pumpWidget(
      _host(
        SmartReorderAction(
          navigation: nav,
          capabilities: nav.capabilities,
          from: AppNavigationDestination.purchasing,
        ),
      ),
    );
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('shows a clear label and tapping auto-sends the seed prompt', (tester) async {
    String? seenPrompt;
    bool? seenAutoSend;
    final user = _user();
    final nav = FakeAppNavigation(
      currentUser: user,
      onOpenAiChat: (prompt, autoSend) {
        seenPrompt = prompt;
        seenAutoSend = autoSend;
      },
    );
    await tester.pumpWidget(
      _host(
        SmartReorderAction(
          navigation: nav,
          capabilities: nav.capabilities,
          from: AppNavigationDestination.purchasing,
        ),
      ),
    );

    // Visible with a clear text label (not just an icon) for a manager with AI.
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.smartReorderButton), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);

    // No confirmation dialog — tapping goes straight into the chat.
    await tester.tap(find.text(l10n.smartReorderButton));
    await tester.pumpAndSettle();

    expect(seenPrompt, l10n.smartReorderSeed);
    expect(seenAutoSend, isTrue);
  });
}
