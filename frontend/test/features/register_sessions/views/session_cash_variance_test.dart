import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/session_cash_variance.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  test('a shortage and an overage read differently, amount unsigned', () {
    expect(sessionCashVarianceFlag(l10n, -12), 'عجز 12.00 د.ل');
    expect(sessionCashVarianceFlag(l10n, 12), 'زيادة 12.00 د.ل');
    expect(sessionCashVarianceMetric(l10n, -12), 'عجز النقد');
    expect(sessionCashVarianceMetric(l10n, 12), 'زيادة النقد');
  });

  test('rounding dust is a match, not a shortage', () {
    expect(sessionCashVarianceFlag(l10n, -0.001), 'مطابق');
    expect(sessionCashVarianceKind(0.004), SessionCashVarianceKind.matched);
  });
}
