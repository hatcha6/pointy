// Dev-only preview harness for the floating calculator (F12).
//
// Renders the real CalculatorPanel in its states with no backend/auth. Run:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/calculator_preview.dart
//
// Screens (`?screen=`):
//   board — every state side by side, light and dark (size the viewport
//           large, e.g. 1500x1200, so Flutter paints all of it)
//   live  — a till-like page with the real FloatingCalculatorHost, opened
//           on load; type on the keyboard, drag the title bar, F12 toggles
//
// See AGENTS.md ("UI preview harness"). Not part of the shipping app; never
// imported by lib/main.dart. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_controller.dart';
import 'package:pointy_frontend/src/shared/calculator/calculator_panel.dart';
import 'package:pointy_frontend/src/shared/calculator/currency_converter.dart';
import 'package:pointy_frontend/src/shared/calculator/floating_calculator.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() => runApp(const _PreviewApp());

String get _screen => Uri.base.queryParameters['screen'] ?? 'board';

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final live = _screen == 'live';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: live
          ? (context, child) => FloatingCalculatorHost(
              key: floatingCalculatorKey,
              child: child!,
            )
          : null,
      home: live ? const _LivePage() : const _Board(),
    );
  }
}

const _registry = <Currency>[
  Currency(
    code: 'LYD',
    nameAr: 'دينار ليبي',
    nameEn: 'Libyan Dinar',
    symbolAr: 'د.ل',
    symbolEn: 'LD',
    decimals: 3,
  ),
  Currency(
    code: 'USD',
    nameAr: 'دولار أمريكي',
    nameEn: 'US Dollar',
    symbolAr: '\$',
    symbolEn: '\$',
    displayOrder: 1,
  ),
  Currency(
    code: 'EUR',
    nameAr: 'يورو',
    nameEn: 'Euro',
    symbolAr: '€',
    symbolEn: '€',
    displayOrder: 2,
  ),
  Currency(
    code: 'GBP',
    nameAr: 'جنيه إسترليني',
    nameEn: 'Pound Sterling',
    symbolAr: '£',
    symbolEn: '£',
    displayOrder: 3,
  ),
  Currency(
    code: 'TRY',
    nameAr: 'ليرة تركية',
    nameEn: 'Turkish Lira',
    symbolAr: '₺',
    symbolEn: '₺',
    displayOrder: 4,
  ),
  Currency(
    code: 'EGP',
    nameAr: 'جنيه مصري',
    nameEn: 'Egyptian Pound',
    symbolAr: 'ج.م',
    symbolEn: 'E£',
    displayOrder: 5,
  ),
  Currency(
    code: 'TND',
    nameAr: 'دينار تونسي',
    nameEn: 'Tunisian Dinar',
    symbolAr: 'د.ت',
    symbolEn: 'DT',
    decimals: 3,
    displayOrder: 6,
  ),
];

ResolvedRate _rate(
  String code,
  double rate, {
  double age = 3,
  bool stale = false,
}) => ResolvedRate(
  fromCode: code,
  toCode: 'LYD',
  rate: rate,
  effectiveAt: DateTime(2026, 10, 13, 9),
  source: RateSource.relay,
  instrument: SettlementInstrument.cash,
  bankCode: '',
  requestedInstrument: SettlementInstrument.cash,
  requestedBankCode: '',
  ageHours: age,
  isStale: stale,
);

/// A converter fed Fulus-like cash rates (or a failure).
CurrencyConverter _converter({
  bool stale = false,
  bool fail = false,
  String? top,
}) {
  final converter = CurrencyConverter(
    loader: () async {
      if (fail) return Error(Exception('offline'));
      return Ok(
        ConverterRates.from(
          CurrentRates(
            baseCode: 'LYD',
            instrument: SettlementInstrument.cash,
            bankCode: '',
            stalenessHours: 24,
            rates: [
              _rate('USD', 7.15, age: stale ? 52 : 3, stale: stale),
              _rate('EUR', 7.82),
              _rate('GBP', 9.31),
              _rate('TRY', 0.204),
              _rate('EGP', 0.146),
              _rate('TND', 2.31),
            ],
          ),
          _registry,
          loadedAt: DateTime.now(),
        ),
      );
    },
  );
  converter.setEnabled(true);
  if (top != null) {
    converter.refresh().then((_) => converter.pick(top, top: true));
  }
  return converter;
}

CalculatorController _typed(String keys) {
  final controller = CalculatorController();
  controller.inputText(keys);
  return controller;
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    final states = <(String, CalculatorController, bool)>[
      ('ترتيب الأرقام', _typed('12-3='), false),
      ('فارغة', CalculatorController(), false),
      ('أثناء الكتابة', _typed('1250+20%'), false),
      ('بعد =', _typed('1250+20%='), false),
      ('خطأ', _typed('9/0='), false),
      ('السجل', _typed('200+20%=×3=1/3=2+2='), true),
      ('رقم طويل', _typed('123456789*987654321='), false),
    ];
    // Convert mode: (title, typed, converter, picker open).
    final converting =
        <(String, CalculatorController, CurrencyConverter, bool)>[
          ('تحويل: أثناء الكتابة', _typed('200+20%'), _converter(), false),
          ('تحويل: بعد =', _typed('200+20%='), _converter(top: 'EUR'), false),
          ('تحويل: اختيار العملة', _typed('50'), _converter(), true),
          ('تحويل: سعر قديم', _typed('100'), _converter(stale: true), false),
          (
            'تحويل: الأسعار غير متاحة',
            CalculatorController(),
            _converter(fail: true),
            false,
          ),
        ];
    Widget column(ThemeData theme, String label) => Theme(
      data: theme,
      child: Builder(
        builder: (context) => ColoredBox(
          color: context.pointyColors.page,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 24,
                  runSpacing: 24,
                  children: [
                    for (final (title, controller, converter, picking)
                        in converting)
                      SizedBox(
                        width: FloatingCalculatorHost.panelWidth,
                        height: picking ? 640 : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 8),
                            CalculatorPanel(
                              controller: controller,
                              converter: converter,
                              focusNode: FocusNode(),
                              onClose: () {},
                              onInsert: (_) => CalculatorInsertOutcome.inserted,
                              canInsert: false,
                              initialPickTop: picking,
                            ),
                          ],
                        ),
                      ),
                    for (final (index, (title, controller, history))
                        in states.indexed)
                      SizedBox(
                        width: FloatingCalculatorHost.panelWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 8),
                            CalculatorPanel(
                              controller: controller,
                              // The first panel shows the focused look.
                              focusNode: FocusNode(),
                              onClose: () {},
                              onInsert: (_) => CalculatorInsertOutcome.inserted,
                              canInsert: index.isOdd,
                              initialShowHistory: history,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            column(PointyTheme.light(), 'الوضع الفاتح'),
            column(PointyTheme.dark(), 'الوضع الداكن'),
          ],
        ),
      ),
    );
  }
}

/// A till-ish page behind the real floating host.
class _LivePage extends StatefulWidget {
  const _LivePage();

  @override
  State<_LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<_LivePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      openFloatingCalculator();
      floatingCalculatorKey.currentState?.controller.inputText('1250+20%');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('نقطة البيع')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: GridView.count(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (var i = 1; i <= 16; i++)
                    Card(child: Center(child: Text('صنف $i'))),
                ],
              ),
            ),
            const SizedBox(width: 24),
            const Expanded(
              flex: 2,
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('الفاتورة'),
                      SizedBox(height: 16),
                      TextField(
                        decoration: InputDecoration(
                          labelText: 'المبلغ المدفوع',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
