import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/features/pos/view_models/airtime_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/bill_flow_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_catalog.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_explainer_controller.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/airtime_flow_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/bill_flow_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

/// An Arabic, right-to-left app around [child], the way the till runs it.
Widget servicesApp(Widget child, {bool dark = false, double textScale = 1}) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: dark ? PointyTheme.dark() : PointyTheme.light(),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: app ?? const SizedBox.shrink(),
      ),
    ),
    home: Scaffold(body: child),
  );
}

/// Sizes the test window like a till's catalog pane (or a phone).
void useWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final List<void Function()> _disposers = [];

/// A widget test that leaves nothing running. After [body], time runs forward
/// until the debounce timers and the fake relay's delays are done, the tree is
/// unmounted and every harness made in it is disposed — all before the
/// framework checks for timers still pending.
void testServices(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    _disposers.clear();
    try {
      await body(tester);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final dispose in _disposers) {
        dispose();
      }
      _disposers.clear();
    }
  });
}

/// Runs [dispose] when the test is over, with the rest of what [testServices]
/// cleans up.
void disposeWithTest(void Function() dispose) => _disposers.add(dispose);

/// The airtime pane on a fake relay, with everything it reports. Disposed by
/// [testServices] when the test is over.
class AirtimeHarness {
  AirtimeHarness({required this.repository}) {
    catalog = ServicesCatalog(repository: repository);
    viewModel = AirtimeViewModel(catalog: catalog, repository: repository);
    explainers = ServicesExplainerController();
    _disposers.add(dispose);
  }

  final PreviewServicesRepository repository;
  late final ServicesCatalog catalog;
  late final AirtimeViewModel viewModel;
  late final ServicesExplainerController explainers;

  /// Every quote the flow put in the cart.
  final List<ServiceQuote> added = [];

  /// How many times the flow was closed with its ✕.
  int closed = 0;

  /// Whether the cart takes what it is handed — it does not while a sale is
  /// being completed.
  bool cartAccepts = true;

  /// What the pane calls to put a priced line in the cart.
  bool accept(ServiceQuote quote) {
    if (!cartAccepts) {
      return false;
    }
    added.add(quote);
    return true;
  }

  void dispose() {
    viewModel.dispose();
    catalog.dispose();
    explainers.dispose();
  }
}

Future<AirtimeHarness> pumpAirtimeFlow(
  WidgetTester tester, {
  PreviewServicesRepository? repository,
  Size size = const Size(700, 760),
  bool dark = false,
  double textScale = 1,
  bool canSell = true,
  bool testMode = false,
  Future<bool> Function()? onTransferBalance,
  AirtimeFlowStep? initialStep,
}) async {
  useWindow(tester, size);
  final harness = AirtimeHarness(
    repository: repository ?? PreviewServicesRepository(),
  );
  await tester.pumpWidget(
    servicesApp(
      Padding(
        padding: const EdgeInsets.all(8),
        child: AirtimeFlowSheet(
          viewModel: harness.viewModel,
          initialStep: initialStep,
          onClose: () => harness.closed++,
          onAdd: canSell ? harness.accept : null,
          testMode: testMode,
          onTransferBalance: onTransferBalance,
        ),
      ),
      dark: dark,
      textScale: textScale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return harness;
}

/// One bill flow on a fake relay, with everything it reports.
class BillHarness {
  BillHarness({required this.type, required this.repository}) {
    catalog = ServicesCatalog(repository: repository);
    viewModel = BillFlowViewModel(
      type: type,
      catalog: catalog,
      repository: repository,
      quoteDebounce: const Duration(milliseconds: 20),
    );
    _disposers.add(dispose);
  }

  final BillType type;
  final PreviewServicesRepository repository;
  late final ServicesCatalog catalog;
  late final BillFlowViewModel viewModel;

  /// Every quote the flow put in the cart.
  final List<ServiceQuote> added = [];

  /// Whether the cart takes what it is handed.
  bool cartAccepts = true;

  /// What the flow calls to put the priced bill in the cart.
  bool accept(ServiceQuote quote) {
    if (!cartAccepts) {
      return false;
    }
    added.add(quote);
    return true;
  }

  /// How many times the flow was closed with its ✕.
  int closed = 0;

  void dispose() {
    viewModel.dispose();
    catalog.dispose();
  }
}

/// A bill flow, drawn the way its dialog draws it: [width] wide on a till,
/// the phone's whole width on a phone.
Future<BillHarness> pumpBillFlow(
  WidgetTester tester,
  BillType type, {
  PreviewServicesRepository? repository,
  Size size = const Size(1366, 768),
  double? width,
  bool dark = false,
  double textScale = 1,
  bool canSell = true,
  bool testMode = false,
}) async {
  useWindow(tester, size);
  final harness = BillHarness(
    type: type,
    repository: repository ?? PreviewServicesRepository(),
  );
  await tester.pumpWidget(
    servicesApp(
      Center(
        child: SizedBox(
          width: width ?? (size.width < 600 ? size.width : 560),
          child: BillFlowSheet(
            viewModel: harness.viewModel,
            onAdd: canSell ? harness.accept : null,
            testMode: testMode,
            onClose: () => harness.closed++,
          ),
        ),
      ),
      dark: dark,
      textScale: textScale,
    ),
  );
  // The host loads the directory as the dialog opens.
  await harness.catalog.ensureLoaded();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return harness;
}
