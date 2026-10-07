import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';
import 'package:pointy_frontend/src/features/app_updates/view_models/app_update_prompter.dart';
import 'package:pointy_frontend/src/features/app_updates/views/app_update_dialog.dart';
import 'package:pointy_frontend/src/features/app_updates/views/app_update_prompt_host.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _megabyte = 1024 * 1024;

const _offer = AppUpdateOffer(
  currentVersion: '0.7.9',
  release: ClientRelease(
    version: '0.8.0',
    file: 'pointy-0.8.0-android-universal.apk',
    sha256: '',
    size: 80 * _megabyte,
    url: '/clients/files/pointy-0.8.0-android-universal.apk',
  ),
);

Widget _app({
  GlobalKey<NavigatorState>? navigatorKey,
  TransitionBuilder? builder,
  Widget home = const Scaffold(body: SizedBox.expand()),
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    builder: builder,
    home: home,
  );
}

/// Opens the dialog over a plain screen, with the install and the "later"
/// answers captured for the test to drive.
class _Harness {
  final postponed = <String>[];
  Completer<void> install = Completer<void>();
  void Function(double progress)? onProgress;
  int installs = 0;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAppUpdateDialog(
                  context,
                  offer: _offer,
                  install: (release, progress) {
                    installs += 1;
                    onProgress = progress;
                    return install.future;
                  },
                  onPostpone: (version) async => postponed.add(version),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('offers the new build beside the running one', (tester) async {
    await _Harness().open(tester);

    expect(find.text('تحديث جديد جاهز'), findsOneWidget);
    expect(find.text('الإصدار الحالي'), findsOneWidget);
    expect(find.text('0.7.9'), findsOneWidget);
    expect(find.text('الإصدار الجديد'), findsOneWidget);
    expect(find.text('0.8.0'), findsOneWidget);
    expect(find.text('حجم التنزيل: 80 ميجابايت'), findsOneWidget);
    expect(find.text('تحديث الآن'), findsOneWidget);
    expect(find.text('لاحقاً'), findsOneWidget);
  });

  testWidgets('"later" turns into a reminder of where the update lives', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.open(tester);

    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();

    expect(harness.postponed, ['0.8.0']);
    expect(find.text('لا تنسَ التحديث'), findsOneWidget);
    expect(
      find.text('يمكنك تثبيت الإصدار 0.8.0 في أي وقت من:'),
      findsOneWidget,
    );
    expect(find.text('إعدادات الجهاز'), findsOneWidget);
    expect(find.text('تحديثات التطبيق'), findsOneWidget);

    await tester.tap(find.text('حسناً'));
    await tester.pumpAndSettle();

    expect(find.text('لا تنسَ التحديث'), findsNothing);
  });

  testWidgets('back goes through "later", so the reminder is not skipped', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.open(tester);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(harness.postponed, ['0.8.0']);
    expect(find.text('لا تنسَ التحديث'), findsOneWidget);
  });

  testWidgets('updating shows its progress, then hands over and closes', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.open(tester);

    await tester.tap(find.text('تحديث الآن'));
    await tester.pump();

    expect(harness.installs, 1);
    expect(find.text('جارٍ بدء التنزيل…'), findsOneWidget);
    expect(find.text('لاحقاً'), findsNothing, reason: 'nothing to press');
    expect(find.text('تحديث الآن'), findsNothing);

    harness.onProgress!(0.42);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('42٪'), findsOneWidget);
    expect(find.text('34 من 80 ميجابايت'), findsOneWidget);
    expect(find.text('جارٍ تنزيل التحديث…'), findsOneWidget);

    harness.onProgress!(1);
    await tester.pump();
    expect(find.text('100٪'), findsOneWidget);
    expect(find.text('اكتمل التنزيل، جارٍ فتح المثبّت…'), findsOneWidget);

    harness.install.complete();
    await tester.pumpAndSettle();

    expect(find.text('تحديث جديد جاهز'), findsNothing);
    expect(harness.postponed, isEmpty);
  });

  testWidgets('a failed download says so and offers to try again', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.open(tester);

    await tester.tap(find.text('تحديث الآن'));
    await tester.pump();
    harness.install.completeError(Exception('download failed (502)'));
    await tester.pumpAndSettle();

    expect(find.text('تعذّر التحديث. حاول مرة أخرى.'), findsOneWidget);
    expect(find.text('لاحقاً'), findsOneWidget);

    harness.install = Completer<void>();
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pump();

    expect(harness.installs, 2);
    expect(find.text('تعذّر التحديث. حاول مرة أخرى.'), findsNothing);
  });

  group('prompt host', () {
    late ValueNotifier<bool> calm;
    late AppUpdatePrompter prompter;

    setUp(() {
      calm = ValueNotifier<bool>(true);
      prompter = AppUpdatePrompter(
        check: () async => ClientUpdateStatus(
          currentVersion: _offer.currentVersion,
          platform: ClientPlatform.android,
          available: _offer.release,
        ),
        serverVersion: ValueNotifier<String?>(null),
        loadPostponed: () async => null,
        savePostponed: (_) async {},
      );
    });

    tearDown(() => prompter.dispose());

    Future<void> pumpHost(WidgetTester tester) {
      final navigatorKey = GlobalKey<NavigatorState>();
      return tester.pumpWidget(
        _app(
          navigatorKey: navigatorKey,
          builder: (context, child) => AppUpdatePromptHost(
            prompter: prompter,
            navigatorKey: navigatorKey,
            canPrompt: () => calm.value,
            promptConditions: calm,
            install: (_, _) async {},
            child: child!,
          ),
        ),
      );
    }

    testWidgets('opens over the app as soon as an update is found', (
      tester,
    ) async {
      await pumpHost(tester);

      prompter.start();
      await tester.pumpAndSettle();

      expect(find.text('تحديث جديد جاهز'), findsOneWidget);
      expect(prompter.offer, isNull, reason: 'taken by the dialog');
    });

    testWidgets('waits for the sale at the till to finish', (tester) async {
      calm.value = false; // items in the cart
      await pumpHost(tester);

      prompter.start();
      await tester.pumpAndSettle();
      expect(find.text('تحديث جديد جاهز'), findsNothing);
      expect(prompter.offer, isNotNull, reason: 'still waiting');

      calm.value = true; // the sale is paid and the cart cleared
      await tester.pumpAndSettle();

      expect(find.text('تحديث جديد جاهز'), findsOneWidget);
    });
  });
}
