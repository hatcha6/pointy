// Renders the Daftar wallet's top-up sheet in each of its stages, and the
// wallet section, to PNG, headlessly — the Dafa methods with their marks, the
// payer fields per method, the code step, and the verdicts — so the screens can
// be looked at instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/wallet_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_section.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_top_up_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../features/settings/wallet_view_model_test.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';

ThemeData _withButtonFont(ThemeData theme) {
  ButtonStyle patch(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = style?.textStyle?.resolve(states);
        return (resolved ?? const TextStyle()).copyWith(
          fontFamily: PointyTypography.fontFamily,
        );
      }),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: patch(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patch(theme.textButtonTheme.style),
    ),
  );
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

const _methods = [
  bankCards,
  sadad,
  WalletTopUpMethod(
    key: 'dafa_edfali',
    gateway: 'dafa',
    provider: 'edfali',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.phone,
  ),
  WalletTopUpMethod(
    key: 'dafa_mobicash',
    gateway: 'dafa',
    provider: 'mobicash',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
  yussor,
  WalletTopUpMethod(
    key: 'dafa_masrafi_pay',
    gateway: 'dafa',
    provider: 'masrafi-pay',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
  WalletTopUpMethod(
    key: 'dafa_sahara_pay',
    gateway: 'dafa',
    provider: 'sahara-pay',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
];

const _marks = [
  'assets/payment_methods/sadad.png',
  'assets/payment_methods/edfali.png',
  'assets/payment_methods/mobicash.png',
  'assets/payment_methods/yussor-pay.png',
  'assets/payment_methods/masrafi-pay.png',
  'assets/payment_methods/sahara-pay.png',
];

WalletOverview _overview({bool testMode = false}) {
  final base = overview(methods: _methods);
  return WalletOverview(
    available: true,
    balance: 245.5,
    currency: 'LYD',
    testMode: testMode,
    topUpOptions: base.topUpOptions,
    recentTopUps: [
      sadadTopUp(status: WalletTopUpStatus.paid, expenseId: 3),
      topUp(status: WalletTopUpStatus.paid),
      WalletTopUp(
        id: 't3',
        invoiceNo: 'DFW-YSR3K7M2QX',
        method: 'dafa_yussor_pay',
        kind: WalletTopUpMethod.kindOtp,
        payerHint: '•••• 0860',
        amount: 50,
        status: WalletTopUpStatus.failed,
        errorCode: 'declined',
        testMode: false,
        createdAt: DateTime(2026, 9, 28, 12),
      ),
    ],
    recentEntries: const [],
    settings: base.settings,
  );
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    // Arabic needs the app's font, and button labels resolve to Roboto, which
    // has no Arabic: point both at IBM Plex Sans Arabic.
    for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final iconFont = File(
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  });

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    bool testMode = false,
    bool section = false,
    Future<void> Function(WalletViewModel viewModel, FakeWalletRepository repo)?
    setUp,
    Future<void> Function(WidgetTester tester, FakeWalletRepository repo)?
    interact,
    bool settles = true,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    final repo = FakeWalletRepository()
      ..walletResult = Ok(_overview(testMode: testMode));
    final viewModel = WalletViewModel(
      repo,
      launchCheckout: (_) async => true,
      newAttemptKey: () => 'capture',
      fastPollInterval: const Duration(hours: 1),
      slowPollInterval: const Duration(hours: 1),
    );
    await viewModel.load();
    viewModel.beginTopUp();
    if (setUp != null) {
      await setUp(viewModel, repo);
    }

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _withButtonFont(PointyTheme.light()),
        builder: (context, inner) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: section
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: WalletSection(viewModel: viewModel),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Material(
                      child: WalletTopUpFlow(viewModel: viewModel),
                    ),
                  ),
                ),
        ),
      ),
    );
    Future<void> settle() async => settles
        ? tester.pumpAndSettle()
        : tester.pump(const Duration(milliseconds: 500));
    await settle();
    // Decoding a real asset is real async I/O, which a widget test's fake
    // clock never advances: runAsync steps outside it to decode the marks.
    await tester.runAsync(() async {
      for (final asset in _marks) {
        await precacheImage(
          AssetImage(asset),
          tester.element(find.byType(MaterialApp)),
        );
      }
    });
    await settle();
    if (interact != null) {
      await interact(tester, repo);
      await settle();
    }
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/wallet_$name.png'),
      );
    } finally {
      debugDisableShadows = true;
      viewModel.dispose();
    }
  }

  const phone = Size(430, 1150);
  const wide = Size(1100, 1000);

  testWidgets('the form, bank cards', (tester) async {
    await shoot(tester, name: 'form_phone', size: phone);
  }, skip: !_capture);

  testWidgets('the form, wide', (tester) async {
    await shoot(tester, name: 'form_wide', size: wide);
  }, skip: !_capture);

  testWidgets('the form, Sadad selected: the amount only', (tester) async {
    await shoot(
      tester,
      name: 'form_sadad_phone',
      size: phone,
      setUp: (viewModel, _) async => viewModel.selectMethod('dafa_sadad'),
    );
  }, skip: !_capture);

  Future<void> openPayerDialog(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField), '100');
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.walletTopUpContinue));
    await tester.pumpAndSettle();
  }

  Finder dialogFields() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextFormField),
  );

  testWidgets('the payer dialog, Sadad', (tester) async {
    await shoot(
      tester,
      name: 'payer_dialog_sadad_phone',
      size: phone,
      setUp: (viewModel, _) async => viewModel.selectMethod('dafa_sadad'),
      interact: (tester, _) async {
        await openPayerDialog(tester);
        await tester.enterText(dialogFields().at(0), '0912345678');
        await tester.enterText(dialogFields().at(1), '1990');
      },
    );
  }, skip: !_capture);

  testWidgets('the payer dialog, a card wallet, wide', (tester) async {
    await shoot(
      tester,
      name: 'payer_dialog_card_wide',
      size: wide,
      setUp: (viewModel, _) async => viewModel.selectMethod('dafa_yussor_pay'),
      interact: (tester, _) => openPayerDialog(tester),
    );
  }, skip: !_capture);

  testWidgets('the payer dialog with the provider\'s refusal', (tester) async {
    await shoot(
      tester,
      name: 'payer_dialog_refused_phone',
      size: phone,
      setUp: (viewModel, repo) async {
        viewModel.selectMethod('dafa_sadad');
        repo.startResult = Error(
          const WalletException(
            code: 'payer_rejected',
            message: '',
            gatewayMessage: 'الرقم غير مشترك في خدمة سداد.',
          ),
        );
      },
      interact: (tester, _) async {
        await openPayerDialog(tester);
        await tester.enterText(dialogFields().at(0), '0912345678');
        await tester.enterText(dialogFields().at(1), '1990');
        final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(l10n.walletTopUpSendCode),
          ),
        );
      },
    );
  }, skip: !_capture);

  Future<void> startSadad(
    WalletViewModel viewModel,
    FakeWalletRepository repo,
  ) {
    repo.startResult = codeStart();
    viewModel.selectMethod('dafa_sadad');
    return viewModel.startTopUp(
      100,
      userIdentifier: '0912345678',
      birthYear: '1990',
    );
  }

  testWidgets('the code step, test mode', (tester) async {
    await shoot(
      tester,
      name: 'code_phone',
      size: phone,
      testMode: true,
      setUp: startSadad,
    );
  }, skip: !_capture);

  testWidgets('a wrong code', (tester) async {
    await shoot(
      tester,
      name: 'code_wrong_phone',
      size: phone,
      setUp: (viewModel, repo) async {
        await startSadad(viewModel, repo);
        repo.confirmResult = Error(
          WalletException(
            code: 'otp_rejected',
            message: '',
            attemptsLeft: 4,
            topUp: sadadTopUp(),
          ),
        );
        await viewModel.confirmCode('123456');
      },
    );
  }, skip: !_capture);

  testWidgets('declined', (tester) async {
    await shoot(
      tester,
      name: 'declined_phone',
      size: phone,
      setUp: (viewModel, repo) async {
        await startSadad(viewModel, repo);
        repo.confirmResult = Error(
          WalletException(
            code: 'declined',
            message: '',
            gatewayMessage: 'تعذّر إتمام العملية، يرجى مراجعة المصرف.',
            topUp: sadadTopUp(
              status: WalletTopUpStatus.failed,
              errorCode: 'declined',
            ),
          ),
        );
        await viewModel.confirmCode('222222');
      },
    );
  }, skip: !_capture);

  testWidgets('paid', (tester) async {
    await shoot(
      tester,
      name: 'paid_phone',
      size: phone,
      setUp: (viewModel, repo) async {
        await startSadad(viewModel, repo);
        await viewModel.confirmCode('111111');
      },
    );
  }, skip: !_capture);

  testWidgets('waiting on the bank-card page', (tester) async {
    await shoot(
      tester,
      name: 'waiting_card_phone',
      size: phone,
      settles: false,
      setUp: (viewModel, _) => viewModel.startTopUp(100),
    );
  }, skip: !_capture);

  testWidgets('the wallet section with top-ups by several methods', (
    tester,
  ) async {
    await shoot(tester, name: 'section_wide', size: wide, section: true);
  }, skip: !_capture);
}
