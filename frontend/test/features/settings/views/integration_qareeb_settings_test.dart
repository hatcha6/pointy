import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_credentials_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_profile_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_verification_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('ar'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: PointyTheme.light(),
  home: child,
);

/// LNET's form is the tallest one: three credentials and three settings.
const _lnet = IntegrationProvider(
  key: IntegrationProviderKey.lnet,
  availability: IntegrationAvailability.available,
  fields: ['base_url', 'username', 'password'],
  secretFields: ['password'],
  isConfigurable: true,
  settings: [
    IntegrationSetting(
      key: 'commission_percent',
      kind: 'percent',
      value: '5',
      minimum: 0,
      maximum: 50,
    ),
    IntegrationSetting(
      key: 'denominations',
      kind: 'amount_list',
      value: ['10', '20', '25', '30', '40', '45', '50', '100'],
    ),
    IntegrationSetting(
      key: 'low_balance_threshold',
      kind: 'amount',
      value: '100',
      minimum: 0,
      maximum: 1000000,
    ),
  ],
);

/// `FilledButton.icon` builds a subclass, which `find.byType` never matches.
final _save = find.ancestor(
  of: find.text('حفظ'),
  matching: find.byWidgetPredicate((widget) => widget is FilledButton),
);

const _qareeb = IntegrationProvider(
  key: IntegrationProviderKey.qareeb,
  availability: IntegrationAvailability.available,
  capabilities: ['balance', 'vouchers', 'recharge', 'profiles'],
  fields: ['username', 'password', 'pin'],
  secretFields: ['password', 'pin'],
  optionalFields: ['pin'],
  isConfigurable: true,
);

void main() {
  group('the configuration sheet', () {
    // Both surfaces the form opens on: a bottom sheet below desktop width, a
    // dialog at a till's. Each far shorter than LNET's form.
    for (final (surface, size) in const [
      ('bottom sheet', Size(800, 420)),
      ('dialog', Size(1280, 560)),
    ]) {
      testWidgets('scrolls its fields with Save kept in reach ($surface)', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        IntegrationCredentialsDraft? sent;
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAdaptiveFormSurface<bool>(
                    context: context,
                    title: 'LNET',
                    builder: (_) => IntegrationCredentialsForm(
                      provider: _lnet,
                      onSubmit: (draft) async {
                        sent = draft;
                        return true;
                      },
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Taller than the surface, and scrolling rather than overflowing.
        expect(tester.takeException(), isNull);
        final fields = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(IntegrationCredentialsForm),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(fields.position.maxScrollExtent, greaterThan(0));

        // Save sits beneath the fields, on screen without scrolling.
        final save = _save;
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(size.height));

        // And the last field is reachable by scrolling to it.
        final lastSetting = find.byType(TextFormField).last;
        await tester.dragUntilVisible(
          lastSetting,
          find.byType(SingleChildScrollView).last,
          const Offset(0, -80),
        );
        await tester.pumpAndSettle();
        expect(fields.position.pixels, greaterThan(0));

        await tester.enterText(find.byType(TextFormField).at(1), 'lnet_r67');
        await tester.enterText(find.byType(EditableText).at(2), 'pw');
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(sent?.username, 'lnet_r67');
      });
    }

    testWidgets('asks Qareeb for a phone number and an optional PIN', (
      tester,
    ) async {
      IntegrationCredentialsDraft? sent;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: IntegrationCredentialsForm(
              provider: _qareeb,
              onSubmit: (draft) async {
                sent = draft;
                return false;
              },
            ),
          ),
        ),
      );

      expect(find.text('رقم الهاتف'), findsOneWidget);
      expect(find.text('رمز الشراء (PIN)'), findsOneWidget);

      final fields = find.byType(EditableText);
      await tester.enterText(fields.at(0), '0912345678');
      await tester.enterText(fields.at(1), 'secret');
      // The PIN is optional: saving without one is allowed.
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(sent?.username, '0912345678');
      expect(sent?.toJson().containsKey('pin'), isFalse);

      await tester.enterText(fields.at(2), '4321');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(sent?.toJson()['pin'], '4321');
    });
  });

  group('confirming this device', () {
    // A 1×1 transparent PNG, standing in for the captcha picture.
    const picture =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

    testWidgets('picture, then the texted code, then trusted', (tester) async {
      String? sentAnswer;
      String? confirmedCode;
      bool? closedWith;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  closedWith = await showAdaptiveFormSurface<bool>(
                    context: context,
                    builder: (_) => IntegrationVerificationForm(
                      onStart: () async =>
                          const IntegrationVerificationChallenge(
                            ok: true,
                            challengeRef: 'ref-1',
                            imageDataUrl: picture,
                          ),
                      onSend: (ref, answer) async {
                        sentAnswer = '$ref:$answer';
                        return const IntegrationVerificationStep(
                          ok: true,
                          expiresInMinutes: 5,
                        );
                      },
                      onConfirm: (code) async {
                        confirmedCode = code;
                        return const IntegrationVerificationStep(ok: true);
                      },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'ab12cd');
      await tester.tap(find.text('أرسل الرمز'));
      await tester.pumpAndSettle();
      expect(sentAnswer, 'ref-1:ab12cd');

      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();
      expect(confirmedCode, '1234');
      expect(closedWith, isTrue);
    });

    testWidgets('a wrong code is said plainly and the sheet stays', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: IntegrationVerificationForm(
              onStart: () async => const IntegrationVerificationChallenge(
                ok: true,
                challengeRef: 'ref-1',
                imageDataUrl: picture,
              ),
              onSend: (ref, answer) async =>
                  const IntegrationVerificationStep(ok: true),
              onConfirm: (code) async => const IntegrationVerificationStep(
                ok: false,
                errorCode: IntegrationErrorCode.verificationRejected,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ab12cd');
      await tester.tap(find.text('أرسل الرمز'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0000');
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();

      expect(find.textContaining('الرمز غير صحيح'), findsOneWidget);
    });
  });

  group('choosing the profile', () {
    testWidgets('names the active one and saves the choice', (tester) async {
      String? chosen;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: IntegrationProfileForm(
              load: () async => const IntegrationProfileList(
                ok: true,
                profiles: [
                  IntegrationProfile(
                    profileId: 'p-1',
                    name: 'صاحب المتجر',
                    kind: 'individual',
                  ),
                  IntegrationProfile(
                    profileId: 'p-2',
                    name: 'النسيم',
                    kind: 'store_employee',
                    isCurrent: true,
                  ),
                ],
              ),
              choose: (profileId) async {
                chosen = profileId;
                return false;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('النشط الآن'), findsOneWidget);
      // Choosing one the login is not acting as is allowed, and warned about.
      await tester.tap(find.text('صاحب المتجر'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ليس النشط'), findsOneWidget);

      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(chosen, 'p-1');
    });
  });
}
