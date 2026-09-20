import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../companion/companion_scan_listener.dart';
import '../../companion/companion_scope.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/unit_options.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_catalog_pane.dart';
import 'purchase_draft_pane.dart';
import 'purchase_pricing_sheet.dart';
import 'purchasing_shortcuts_sheet.dart';
import 'purchase_product_create.dart';

class PurchasingScreen extends StatelessWidget {
  const PurchasingScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    required this.navigation,
    this.showBackButton = false,
    this.onSaved,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final bool showBackButton;

  /// Invoked after the draft is saved/submitted from this workspace. The edit
  /// flow uses it to return to the order it reopened; null in the create flow.
  final VoidCallback? onSaved;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.purchasing,
            navigation: navigation,
          ),
          appBar: PointyAppBar(
            leading: showBackButton
                ? IconButton(
                    tooltip: l10n.backTooltip,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  )
                : const PointyNavigationMenuButton(),
            title: Text(
              viewModel.isEditing
                  ? l10n.editPurchaseOrderTitle
                  : l10n.newPurchaseOrderTitle,
            ),
            actions: [
              AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.accessPurchasing,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.purchasingShortcutsTooltip,
                  onPressed: () => showPurchasingShortcutsSheet(context),
                  icon: const Icon(Icons.keyboard_outlined),
                ),
              ),
              AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.accessPurchasing,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshCatalogTooltip,
                  onPressed: viewModel.loadCatalog,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.accessPurchasing,
            child: _PurchasingWorkspace(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
              onSaved: onSaved,
            ),
          ),
        );
      },
    );
  }
}

class _PurchasingWorkspace extends StatefulWidget {
  const _PurchasingWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    this.onSaved,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onSaved;

  @override
  State<_PurchasingWorkspace> createState() => _PurchasingWorkspaceState();
}

class _PurchasingWorkspaceState extends State<_PurchasingWorkspace> {
  /// The draft pane publishes its submit/save and settings closures here so the
  /// keyboard runs the same flows as the on-screen buttons, from anywhere on
  /// the screen — exactly how the POS's checkout chord works.
  final PurchaseSubmitController _submitController = PurchaseSubmitController();

  PurchaseViewModel get viewModel => widget.viewModel;

  /// Cycles the active line through the product's purchasable units. Arrow
  /// Up/Right = next, Down/Left = previous; F2 (no [key]) advances forward.
  bool _cycleActiveLineUnit([LogicalKeyboardKey? key]) {
    final line = viewModel.activeDraftLine;
    if (line == null) {
      return false;
    }
    final options = purchasableUnitOptions(
      AppLocalizations.of(context)!,
      Product.fromVariant(line.variant),
    );
    if (options.length < 2) {
      return false;
    }
    final currentCode = line.unitCode.isEmpty
        ? options.first.code
        : line.unitCode;
    var index = options.indexWhere((option) => option.code == currentCode);
    if (index == -1) {
      index = 0;
    }
    final forward =
        key == null ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowRight;
    final next =
        options[(index + (forward ? 1 : -1) + options.length) % options.length];
    viewModel.updateLineUnit(
      line.variant,
      unitCode: next.isBase ? '' : next.code,
      unitLabel: next.label,
      unitFactor: next.factorToBase,
      allowsFractional: next.allowsFractional,
    );
    return true;
  }

  /// F3 — price the active line. The cost was just typed; pricing is the
  /// decision that follows it, so it gets a key rather than a hunt for a button.
  bool _openPricingForActiveLine() {
    final line = viewModel.activeDraftLine;
    if (line == null || viewModel.isSubmitting) {
      return false;
    }
    unawaited(
      showPurchasePricingSheet(context, viewModel: viewModel, line: line),
    );
    return true;
  }

  /// F6 — take the habitual quantity for the active line. The same accept the
  /// line's chip performs, for hands that are on the scanner rather than the
  /// mouse. Returns false (so the key falls through) when this shop's history
  /// has no quantity to offer for that line.
  bool _acceptSuggestedQuantityForActiveLine() {
    final line = viewModel.activeDraftLine;
    if (line == null || viewModel.isSubmitting) {
      return false;
    }
    final hint = viewModel.quantityHintFor(line);
    if (hint == null) {
      return false;
    }
    viewModel.applySuggestedQuantity(
      line,
      hint,
      source: 'purchase_keyboard_quantity_hint',
    );
    return true;
  }

  /// F4 — delete the active line, with an Undo. A mis-fire on a delivery
  /// somebody is halfway through counting must be one tap to recover.
  bool _deleteActiveLine() {
    final line = viewModel.activeDraftLine;
    if (line == null) {
      return false;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final removed = viewModel.removeLine(
      line.variant.id,
      source: 'purchase_keyboard_delete_line',
    );
    if (removed == null) {
      return false;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.purchaseDraftLineRemovedMessage),
          action: SnackBarAction(
            label: l10n.undoButton,
            onPressed: () => viewModel.restoreLine(removed),
          ),
        ),
      );
    viewModel.requestSearchFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return CompanionScanListener(
      bridge: CompanionScope.bridgeOf(context),
      enabled: !viewModel.isSubmitting,
      onScan: (barcode) {
        unawaited(_addBarcode(context, barcode));
      },
      child: BarcodeScanListener(
        enabled: !viewModel.isSubmitting,
        onBarcodeScanned: (barcode) {
          unawaited(_addBarcode(context, barcode));
        },
        // A scan only ever adds its own product; it never touches a line's
        // quantity. Arrow keys flip the active line's unit of measure — the
        // deliberate quantity edit lives behind a line tap.
        onArrowKey: (key) => _cycleActiveLineUnit(key),
        // Till function keys, dispatched through the same global hardware-keyboard
        // handler as scans — NOT focus-tree Shortcuts, which silently die when
        // focus parks outside the workspace. Deliberately the same keys as the
        // POS where the job is the same (F2 unit, F4 delete line), so a cashier
        // moved onto receiving does not have to relearn the two they know.
        onFunctionKey: (key) {
          if (key == LogicalKeyboardKey.f1) {
            final open = _submitController.onOpenSettings;
            if (open == null) {
              return false;
            }
            open();
            return true;
          }
          if (key == LogicalKeyboardKey.f2) {
            return _cycleActiveLineUnit();
          }
          if (key == LogicalKeyboardKey.f3) {
            return _openPricingForActiveLine();
          }
          if (key == LogicalKeyboardKey.f4) {
            return _deleteActiveLine();
          }
          if (key == LogicalKeyboardKey.f6) {
            return _acceptSuggestedQuantityForActiveLine();
          }
          return false;
        },
        onCommandEnter: () => _submitController.onSubmit?.call(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            if (AppBreakpoints.usesTwoPane(width)) {
              return TwoPaneLayout(
                minPrimaryWidth: 390,
                primaryPane: PurchaseCatalogPane(
                  viewModel: viewModel,
                  capabilities: widget.capabilities,
                ),
                secondaryPane: PurchaseDraftPane(
                  viewModel: viewModel,
                  contactRepository: widget.contactRepository,
                  submitController: _submitController,
                  onSubmitSuccess: widget.onSaved,
                ),
              );
            }

            return _CompactPurchasingWorkspace(
              viewModel: viewModel,
              contactRepository: widget.contactRepository,
              capabilities: widget.capabilities,
              onSaved: widget.onSaved,
            );
          },
        ),
      ),
    );
  }

  Future<void> _addBarcode(BuildContext context, String barcode) =>
      addScannedPurchaseBarcode(
        context,
        viewModel: viewModel,
        barcode: barcode,
      );
}

class _CompactPurchasingWorkspace extends StatelessWidget {
  const _CompactPurchasingWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    this.onSaved,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onSaved;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Expanded(
          child: PurchaseCatalogPane(
            viewModel: viewModel,
            capabilities: capabilities,
          ),
        ),
        PointyCompactOrderLauncher(
          title: l10n.purchaseDraftTitle,
          lineCountLabel: l10n.lineItemCount(viewModel.draft.length),
          totalLabel: formatMoney(viewModel.total),
          actionLabel: l10n.openPurchaseDraftSheetButton,
          icon: Icons.assignment_outlined,
          isBusy: viewModel.isSubmitting,
          onPressed: () => _showDraftSheet(context),
        ),
      ],
    );
  }

  Future<void> _showDraftSheet(BuildContext context) {
    final colors = context.pointyColors;

    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(PointyRadii.sheet),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) {
        return ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) {
            return PurchaseDraftPane(
              viewModel: viewModel,
              contactRepository: contactRepository,
              onSubmitSuccess: () {
                Navigator.of(sheetContext).pop();
                onSaved?.call();
              },
            );
          },
        );
      },
    );
  }
}
