import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_credentials_sheet.dart';

/// The denominations field this replaces was a single text box asking an
/// owner to type "10, 20, 25" and get the separator right — and on
/// Annaseem's machine, an edit meant to keep eight amounts silently kept
/// two, with no error shown at any point. These pin the replacement: every
/// amount is typed into its own field and validated before it can reach the
/// list, so there is nothing left for a save to reject, and nothing for an
/// owner to get subtly wrong.
void main() {
  IntegrationProvider lnetLikeProvider({List<Object?> denominations = const [
    '10',
    '20',
    '25',
    '30',
    '40',
    '45',
    '50',
    '100',
  ]}) {
    return IntegrationProvider(
      key: IntegrationProviderKey.lnet,
      availability: IntegrationAvailability.available,
      capabilities: const ['balance', 'lookup', 'recharge'],
      fields: const ['base_url', 'username', 'password'],
      secretFields: const ['password'],
      // A username already on file and a password already stored, so Save
      // is not blocked on fields this test has nothing to do with — a blank
      // password field is "leave it alone" precisely because one is stored.
      account: const IntegrationAccount(
        provider: IntegrationProviderKey.lnet,
        username: 'lnet_r67',
        hasPassword: true,
        isConfigured: true,
      ),
      settings: [
        IntegrationSetting(
          key: IntegrationSettingKey.commissionPercent,
          kind: 'percent',
          value: '5',
          defaultValue: '5',
          minimum: 0,
          maximum: 50,
        ),
        IntegrationSetting(
          key: IntegrationSettingKey.denominations,
          kind: 'amount_list',
          value: denominations,
          defaultValue: denominations,
        ),
      ],
    );
  }

  Widget harness(
    IntegrationProvider provider, {
    required Future<bool> Function(IntegrationCredentialsDraft draft) onSubmit,
  }) {
    return MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        // A real save sits inside showAdaptiveFormSurface's scrollable sheet;
        // this harness gives the form the same room to overflow into rather
        // than a fixed-height test window it was never meant to fit inside.
        body: SingleChildScrollView(
          child: IntegrationCredentialsForm(
            provider: provider,
            onSubmit: onSubmit,
          ),
        ),
      ),
    );
  }

  /// The dialog overlays the form rather than replacing it, so once it is
  /// open the SAME amount can legitimately appear twice — once in the
  /// (still unsaved) summary underneath, once in the dialog's own live list.
  /// Every assertion made while the dialog is open scopes to it for that
  /// reason.
  Finder withinDialog(Finder matching) =>
      find.descendant(of: find.byType(AlertDialog), matching: matching);

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('manage_integration_amount_list_button')),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addAmount(WidgetTester tester, String amount) async {
    await tester.enterText(
      find.byKey(const ValueKey('integration_amount_field')),
      amount,
    );
    await tester.tap(find.byKey(const ValueKey('add_integration_amount_button')));
    await tester.pump();
  }

  testWidgets('a raw comma-separated text field is never shown', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(lnetLikeProvider(), onSubmit: (_) async => true),
    );
    await tester.pumpAndSettle();

    // The old field, gone: nothing here should ever read a delimited
    // "10، 20، 25" string back at the owner.
    expect(find.textContaining('،'), findsNothing);
    expect(
      find.byKey(const ValueKey('integration_amount_list_field')),
      findsOneWidget,
    );
  });

  testWidgets('the current amounts are summarised, not hidden in a text box', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['10', '45']),
        onSubmit: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('10.00 د.ل'), findsOneWidget);
    expect(find.text('45.00 د.ل'), findsOneWidget);
  });

  testWidgets('an empty list reads as a real, explained state', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const []),
        onSubmit: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.integrationAmountListEmptyMessage), findsOneWidget);
  });

  testWidgets('managing the list opens pre-filled with what is set now', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['10', '45']),
        onSubmit: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();
    await openDialog(tester);

    expect(withinDialog(find.text('10.00 د.ل')), findsOneWidget);
    expect(withinDialog(find.text('45.00 د.ل')), findsOneWidget);
  });

  testWidgets('adding an amount validates, dedups and sorts numerically', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['9', '100']),
        onSubmit: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();
    await openDialog(tester);

    // Invalid: rejected with a shown reason, not silently dropped.
    await addAmount(tester, '0');
    expect(find.text(l10n.integrationAmountListInvalidError), findsOneWidget);

    // A real amount lands between the two existing ones — sorted as a
    // number, not as a string (where "20" would otherwise follow "100").
    await addAmount(tester, '20');

    final rows = tester
        .widgetList<Text>(withinDialog(find.textContaining('د.ل')))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    expect(rows, ['9.00 د.ل', '20.00 د.ل', '100.00 د.ل']);

    // The same amount again is refused as a duplicate, not added twice.
    await addAmount(tester, '20');
    expect(find.text(l10n.integrationAmountListDuplicateError), findsOneWidget);
  });

  testWidgets('removing an amount takes it out of the list', (tester) async {
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['10', '45']),
        onSubmit: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();
    await openDialog(tester);

    await tester.tap(find.byKey(const ValueKey('remove_integration_amount_10')));
    await tester.pump();

    expect(withinDialog(find.text('10.00 د.ل')), findsNothing);
    expect(withinDialog(find.text('45.00 د.ل')), findsOneWidget);
  });

  testWidgets('confirming the dialog updates the summary and reaches save', (
    tester,
  ) async {
    IntegrationCredentialsDraft? submitted;
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['10']),
        onSubmit: (draft) async {
          submitted = draft;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    await openDialog(tester);
    await addAmount(tester, '45');
    await tester.tap(
      find.byKey(const ValueKey('integration_amount_list_done_button')),
    );
    await tester.pumpAndSettle();

    // The dialog is gone; the summary reflects the edit before Save is even
    // pressed.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('45.00 د.ل'), findsOneWidget);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.integrationSave));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(
      submitted!.settings![IntegrationSettingKey.denominations],
      ['10', '45'],
    );
  });

  testWidgets('leaving the list untouched sends no change for it', (
    tester,
  ) async {
    // _changedSettings() only sends what differs from what was loaded — the
    // same contract every other setting already has, and this field must
    // not break it just by rendering.
    IntegrationCredentialsDraft? submitted;
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['10', '45']),
        onSubmit: (draft) async {
          submitted = draft;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.integrationSave));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(
      submitted!.settings!.containsKey(IntegrationSettingKey.denominations),
      isFalse,
    );
  });

  testWidgets('cancelling the dialog leaves the list exactly as it was', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        lnetLikeProvider(denominations: const ['10', '45']),
        onSubmit: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();
    await openDialog(tester);
    await addAmount(tester, '99');

    await tester.tap(
      find.byKey(const ValueKey('integration_amount_list_cancel_button')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('99.00 د.ل'), findsNothing);
    expect(find.text('10.00 د.ل'), findsOneWidget);
    expect(find.text('45.00 د.ل'), findsOneWidget);
  });
}
