import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_line.dart';
import 'package:pointy_frontend/src/data/repositories/stock_count_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_reconciliation_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _session = StockCount(
  id: 1,
  countNumber: 'SC-1',
  status: StockCountStatus.inProgress,
  scope: StockCountScope.full,
  expectedLineCount: 10,
  countedLineCount: 10,
  varianceLineCount: 2,
);

StockCountLine _line(int id, double expected, double counted) {
  return StockCountLine(
    id: id,
    stockCountId: 1,
    variantId: id,
    countedQuantity: counted,
    expectedQuantity: expected,
    variance: counted - expected,
    needsReview: true,
    applied: false,
    staleAtApply: false,
    variant: ProductVariant(
      id: id,
      productId: id,
      sku: 'SKU-$id',
      displayName: 'صنف $id',
      unitPrice: 1,
    ),
  );
}

class _StubStockCountRepository extends StockCountRepository {
  _StubStockCountRepository(this._lines, {this.failuresBeforeSuccess = 0})
    : super(PosApiService());

  final List<StockCountLine> _lines;

  /// How many `loadReconciliation` calls fail before the stub starts serving
  /// [_lines]; lets a test drive the retry path.
  final int failuresBeforeSuccess;
  int loadAttempts = 0;

  @override
  Future<Result<List<StockCountLine>>> loadReconciliation(int countId) async {
    loadAttempts++;
    if (loadAttempts <= failuresBeforeSuccess) {
      return Error(Exception('offline'));
    }
    return Ok(_lines);
  }
}

AuthorizationCapabilities get _managerCaps => AuthorizationCapabilities.forUser(
  PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'role': 'manager',
    'permissions': <String>[],
  }),
);

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
    home: child,
  );
}

void main() {
  testWidgets('summarizes shortage/surplus and offers Apply for variances', (
    tester,
  ) async {
    final repo = _StubStockCountRepository([
      _line(1, 24, 19), // shortage
      _line(2, 60, 72), // surplus
    ]);

    await tester.pumpWidget(
      _wrap(
        StockCountReconciliationScreen(
          session: _session,
          stockCountRepository: repo,
          capabilities: _managerCaps,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('نقص'), findsOneWidget);
    expect(find.text('زيادة'), findsOneWidget);
    expect(find.text('تطبيق التعديلات'), findsOneWidget);
  });

  testWidgets('matched count shows the matched state and a Finish action', (
    tester,
  ) async {
    final repo = _StubStockCountRepository(const []);

    await tester.pumpWidget(
      _wrap(
        StockCountReconciliationScreen(
          session: _session,
          stockCountRepository: repo,
          capabilities: _managerCaps,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('كل شيء مطابق'), findsOneWidget);
    expect(find.text('إنهاء الجرد'), findsOneWidget);
  });

  testWidgets(
    'a failed load offers a retry instead of a confident Finish action',
    (tester) async {
      final repo = _StubStockCountRepository([
        _line(1, 24, 19),
      ], failuresBeforeSuccess: 1);

      await tester.pumpWidget(
        _wrap(
          StockCountReconciliationScreen(
            session: _session,
            stockCountRepository: repo,
            capabilities: _managerCaps,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The error names what failed here — the variances — not the session list.
      expect(find.text('تعذّر تحميل فروقات الجرد.'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);

      // A failed load empties the lines just like a matched count does, so the
      // footer must not offer to finish a count nobody has seen.
      expect(find.text('إنهاء الجرد'), findsNothing);
      expect(find.text('تطبيق التعديلات'), findsNothing);
      expect(
        find.text(
          'لا يمكن إنهاء الجرد قبل تحميل الفروقات. أعد المحاولة أولاً.',
        ),
        findsOneWidget,
      );

      // Retrying recovers in place — no backing out of the session.
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(repo.loadAttempts, 2);
      expect(find.text('تعذّر تحميل فروقات الجرد.'), findsNothing);
      expect(find.text('تطبيق التعديلات'), findsOneWidget);
    },
  );
}
