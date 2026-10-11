import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// The shop's return window as people say it: «3 يوم», «12 ساعة»,
/// «1 يوم و6 ساعة» (`ShopSettings.cashier_return_window_hours`).
String formatReturnWindow(AppLocalizations l10n, int windowHours) {
  final days = windowHours ~/ 24;
  final hours = windowHours % 24;
  if (days == 0) {
    return l10n.cashierReturnWindowHoursValue(hours);
  }
  if (hours == 0) {
    return l10n.cashierReturnWindowDaysValue(days);
  }
  return l10n.cashierReturnWindowDaysHoursValue(days, hours);
}
