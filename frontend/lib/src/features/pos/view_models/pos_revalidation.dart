import '../../../core/revalidation.dart';
import '../../../core/server_state.dart';
import 'pos_view_model.dart';

/// Everything the sell screen has to re-read when the server says it moved.
///
/// Kept here rather than inline in the dependency graph so the rules the till
/// actually runs are the rules the tests exercise — which domains, and the one
/// gate that decides when a refresh may touch the screen.
void registerPosRevalidation({
  required Revalidator revalidator,
  required PosViewModel posViewModel,
}) {
  // A held refresh runs the moment the cashier's hands are free.
  posViewModel.onInteractionSettled = revalidator.gateOpened;

  // The shop settings singleton: currency, overselling, auto-print, tax,
  // credit policy. Edited on one back-office device and read by every till.
  revalidator.watch(
    label: 'pos-settings',
    domains: const {ServerStateDomain.settings},
    canRun: () => posViewModel.canRevalidateNow,
    onStale: posViewModel.loadCheckoutSettings,
  );

  // The one the tills are judged on: a price or a name the back office changed
  // must reach the sell screen before the next customer, not after the next
  // restart. Watching `catalog_defs` and not the composite `catalog` is what
  // makes that affordable — the composite moves on every sale in the shop, so
  // watching it would refresh every till's grid all day for nothing.
  revalidator.watch(
    label: 'pos-catalog',
    domains: const {ServerStateDomain.catalogDefs},
    canRun: () => posViewModel.canRevalidateNow,
    onStale: posViewModel.refreshVisibleCatalog,
  );
}
