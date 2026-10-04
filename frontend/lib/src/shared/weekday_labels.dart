import '../../l10n/generated/app_localizations.dart';

/// Weekday labels keyed by python weekday number (Monday = 0 .. Sunday = 6),
/// the numbering the backend stores work weeks and settlement weeks in.
String weekdayLabel(AppLocalizations l10n, int weekday) {
  return switch (weekday) {
    0 => l10n.weekdayMonday,
    1 => l10n.weekdayTuesday,
    2 => l10n.weekdayWednesday,
    3 => l10n.weekdayThursday,
    4 => l10n.weekdayFriday,
    5 => l10n.weekdaySaturday,
    _ => l10n.weekdaySunday,
  };
}

/// The week in the order a Libyan shop reads it: Saturday first.
const weekdaysSaturdayFirst = [5, 6, 0, 1, 2, 3, 4];
