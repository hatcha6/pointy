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
  bool Function()? isSignedIn,
}) {
  // A held refresh runs the moment the cashier's hands are free.
  posViewModel.onInteractionSettled = revalidator.gateOpened;

  // Nobody signed in — a price-checker kiosk, a till waiting at the sign-in
  // screen — means no sell screen to refresh, and both reads below need a
  // session. Dropped, not held: signing in loads everything fresh anyway.
  // Without this each price change at the back office cost every kiosk a 401
  // (55 in one field week, 0.4 s after a lookup brought the new version).
  bool signedIn() => isSignedIn?.call() ?? true;

  // The shop settings singleton: currency, overselling, auto-print, tax,
  // credit policy. Edited on one back-office device and read by every till.
  revalidator.watch(
    label: 'pos-settings',
    domains: const {ServerStateDomain.settings},
    canRun: () => posViewModel.canRevalidateNow,
    onStale: () async {
      if (signedIn()) {
        await posViewModel.loadCheckoutSettings();
      }
    },
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
    onStale: () async {
      if (signedIn()) {
        await posViewModel.refreshVisibleCatalog();
        // The cards are mirrored into system products, so a new promotion or
        // a card that sold out moves the same version. Only a menu the till
        // already read is re-read.
        await posViewModel.voucherMenu.refreshIfLoaded();
      }
    },
  );
}
