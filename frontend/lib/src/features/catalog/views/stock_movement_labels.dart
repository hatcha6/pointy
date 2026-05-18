import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_movement.dart';

String stockMovementTypeLabel(
  AppLocalizations l10n,
  StockMovementType movementType,
) {
  return switch (movementType) {
    StockMovementType.increase => l10n.stockMovementIncrease,
    StockMovementType.decrease => l10n.stockMovementDecrease,
    StockMovementType.damaged => l10n.stockMovementDamaged,
  };
}
