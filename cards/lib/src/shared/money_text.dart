import '../../l10n/generated/app_localizations.dart';
import '../core/money.dart';

/// An amount as the app shows it: "10.21 د.ل".
String formatMoney(AppLocalizations l10n, Money amount) =>
    l10n.moneyAmount(amount.toFixed2());
