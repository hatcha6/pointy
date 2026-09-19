import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/migration_collapse.dart';
import 'package:pointy_frontend/src/features/migration/view_models/collapse_view_model.dart';
import 'package:pointy_frontend/src/features/migration/views/collapse_review_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

/// §12's screen exists to say one sentence to a shop owner. These check it says
/// it — in Arabic, with the rows that need a person first, and with the fact
/// that applying it turns identified stock on stated rather than implied.
Widget _wrap(Widget child) {
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
    builder: (context, inner) => PointyNavigationRailScope(
      isActive: false,
      controller: PointyNavigationRailController(),
      child: inner ?? const SizedBox.shrink(),
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  CollapsePlan plan({String status = 'ready'}) => CollapsePlan.fromJson({
    'id': 7,
    'source': 1,
    'status': status,
    'is_editable': status == 'ready',
    'thresholds': const {'low': 0.5, 'high': 0.8},
    'asset_type_name': 'هاتف',
    'stats': const {
      'source_products': 340,
      'products': 12,
      'variants': 31,
      'units': 331,
      'units_in_stock': 96,
      'units_sold': 235,
      'kept': 9,
      'needs_review': 14,
    },
  });

  CollapseCluster cluster() => CollapseCluster.fromJson(const {
    'stem_key': 'iphone 13 pro',
    'stem': 'iPhone 13 Pro',
    'variants': 6,
    'units': 84,
    'units_in_stock': 21,
    'units_sold': 63,
    'needs_review': 4,
    'option_values': {
      'storage': ['128GB', '256GB'],
    },
  });

  CollapseCandidate candidate({
    String decision = 'collapse',
    String confidence = '0.30',
    List<String> reasons = const ['imei_check_digit_failed'],
  }) => CollapseCandidate.fromJson({
    'id': 1,
    'source_key': '1007',
    'source_name': 'iPhone 13 Pro 256GB Blue Battery86 IMEI351234567890111',
    'decision': decision,
    'stem': 'iPhone 13 Pro',
    'stem_key': 'iphone 13 pro',
    'identifier': '351234567890111',
    'identifier_kind': 'imei',
    'options': const {'storage': '256GB', 'colour': 'blue'},
    'option_labels': const {'storage': '256GB', 'colour': 'أزرق'},
    'attributes': const {'battery_health': 86},
    'unit_status': 'in_stock',
    'confidence': confidence,
    'reasons': reasons,
    'needs_review': true,
  });

  Widget body({
    CollapsePlan? current,
    List<CollapseCluster> clusters = const [],
    List<CollapseCandidate> candidates = const [],
  }) => _wrap(
    CollapseReviewBody(
      plan: current,
      clusters: clusters,
      candidates: candidates,
      filter: CollapseFilter.needsReview,
    ),
  );

  testWidgets('with no proposal the screen offers to build one', (
    tester,
  ) async {
    await tester.pumpWidget(body());
    expect(find.text('صنف لكل جهاز؟'), findsOneWidget);
    expect(find.text('افحص الأصناف'), findsOneWidget);
  });

  testWidgets('the headline is the whole argument', (tester) async {
    await tester.pumpWidget(body(current: plan(), clusters: [cluster()]));
    expect(find.text('340 صنفًا ← 331 وحدة'), findsOneWidget);
    expect(find.text('96 في المخزون · 235 مباعة'), findsOneWidget);
    // And the counts under it, including the rows it left alone.
    expect(find.text('12'), findsWidgets);
    expect(find.text('تبقى أصنافًا كما هي'), findsOneWidget);
  });

  testWidgets('a proposed product names what it would hold', (tester) async {
    await tester.pumpWidget(body(current: plan(), clusters: [cluster()]));
    expect(find.text('iPhone 13 Pro'), findsOneWidget);
    expect(find.text('84 وحدة · 6 خيار'), findsOneWidget);
    expect(find.text('256GB'), findsOneWidget);
  });

  testWidgets('an uncertain row shows the old name, the new one, and why', (
    tester,
  ) async {
    await tester.pumpWidget(
      body(current: plan(), clusters: [cluster()], candidates: [candidate()]),
    );
    expect(
      find.text('iPhone 13 Pro 256GB Blue Battery86 IMEI351234567890111'),
      findsOneWidget,
    );
    expect(find.text('351234567890111'), findsOneWidget);
    expect(find.text('رقم التحقق في IMEI لا يطابق'), findsOneWidget);
  });

  testWidgets('a row the collapse left alone says so', (tester) async {
    await tester.pumpWidget(
      body(
        current: plan(),
        candidates: [
          candidate(decision: 'keep', reasons: const ['sold_more_than_once']),
        ],
      ),
    );
    expect(find.text('يبقى صنفًا'), findsOneWidget);
    expect(find.text('يبقى صنفًا كما هو'), findsOneWidget);
    expect(find.text('بيع أكثر من مرة — ليس جهازًا بعينه'), findsOneWidget);
  });

  testWidgets('approval says what it will turn on before it is offered', (
    tester,
  ) async {
    await tester.pumpWidget(body(current: plan(), clusters: [cluster()]));
    expect(
      find.text('سيُفعَّل تتبّع الأجهزة المعرّفة في المتجر عند النقل.'),
      findsOneWidget,
    );
    expect(find.text('اعتمد الاقتراح'), findsOneWidget);
  });

  testWidgets('an approved proposal offers no approve button', (tester) async {
    await tester.pumpWidget(
      body(
        current: plan(status: 'approved'),
        clusters: [cluster()],
      ),
    );
    expect(find.text('اعتمد الاقتراح'), findsNothing);
    expect(find.text('تم اعتماد الاقتراح'), findsOneWidget);
  });

  testWidgets('a catalogue that is already normal says so', (tester) async {
    final empty = CollapsePlan.fromJson({
      'id': 7,
      'status': 'ready',
      'is_editable': true,
      'stats': const {'source_products': 1200, 'units': 0},
    });
    await tester.pumpWidget(body(current: empty));
    expect(
      find.text('لم نجد في هذا الملف ما يشبه صنفًا لكل جهاز.'),
      findsOneWidget,
    );
  });
}
