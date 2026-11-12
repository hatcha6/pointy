import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/repositories/contact_repository.dart';
import '../view_models/purchase_order_documents.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tracking/unit_intake_permissions.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_catalog_pane.dart';
import 'purchase_draft_pane.dart';
import 'purchase_line_capture_row.dart';
import 'purchase_line_entry_guide.dart';
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
    this.documents,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final bool showBackButton;

  /// The order as paper, and the stickers for what its receipt brings in.
  final PurchaseOrderDocuments? documents;

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
              documents: documents,
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
    this.documents,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final PurchaseOrderDocuments? documents;
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

  /// Whether the draft pane is on screen beside the catalog.
  bool _twoPane = false;

  /// Cycles the active line through the product's purchasable units. Arrow
  /// Up/Right = next, Down/Left = previous; F2 (no [key]) advances forward.
  /// The arrows only get here with the keyboard parked nowhere — in the draft
  /// pane they are the pane's own.
  bool _cycleActiveLineUnit([LogicalKeyboardKey? key]) {
    final line = viewModel.activeDraftLine;
    return line != null &&
        cyclePurchaseLineUnit(
          AppLocalizations.of(context)!,
          viewModel,
          line,
          key,
        );
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
    final removed = viewModel.removeLine(
      line.variant.id,
      source: 'purchase_keyboard_delete_line',
    );
    if (removed == null) {
      return false;
    }
    showLineRemovedUndo(
      context,
      message: AppLocalizations.of(context)!.purchaseDraftLineRemovedMessage,
      onUndo: () => viewModel.restoreLine(removed),
    );
    viewModel.requestSearchFocus();
    return true;
  }

  /// F5 — walk the active line from the keyboard: its quantity, then Enter
  /// to its unit, its cost, its expiry, then back to the search box.
  bool _walkActiveLine() {
    final line = viewModel.activeDraftLine;
    if (line == null || viewModel.isSubmitting) {
      return false;
    }
    viewModel.requestLineEntry(line.variant.id);
    return true;
  }

  /// F9 — the active line's lots, expiry dates and serials, in the sheets the
  /// receiving form uses. Falls through for goods counted rather than named.
  bool _captureActiveLine() {
    final line = viewModel.activeDraftLine;
    if (line == null ||
        viewModel.isSubmitting ||
        !line.variant.trackingMode.isTracked) {
      return false;
    }
    unawaited(
      capturePurchaseLine(
        context,
        viewModel: viewModel,
        line: line,
        permissions: UnitIntakePermissions.of(widget.capabilities),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // The counter scanner, the counter camera and a paired phone all type
    // their scans (the last two through ScanKeyboard), so this one listener
    // hears all three.
    return BarcodeScanListener(
      enabled: !viewModel.isSubmitting,
      onBarcodeScanned: (barcode) {
        unawaited(_addBarcode(context, barcode));
      },
      // A scan only ever adds its own product; it never touches a line's
      // quantity — it selects the line, and the quantity is typed after it.
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
        if (key == LogicalKeyboardKey.f5) {
          return _walkActiveLine();
        }
        if (key == LogicalKeyboardKey.f6) {
          return _acceptSuggestedQuantityForActiveLine();
        }
        if (key == LogicalKeyboardKey.f9) {
          return _captureActiveLine();
        }
        return false;
      },
      // Page Down / Page Up step through the order's lines, from anywhere —
      // the search box included, where the keys do nothing of their own. The
      // POS spends them on held invoices; an order has one, and many lines.
      onPageKey: (key) => viewModel.selectAdjacentLine(
        forward: key == LogicalKeyboardKey.pageDown,
      ),
      onCommandEnter: () => _submitController.onSubmit?.call(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          _twoPane = AppBreakpoints.usesTwoPane(width);
          if (_twoPane) {
            return TwoPaneLayout(
              minPrimaryWidth: 390,
              secondaryPaneMaxWidth: AppPaneWidths.orderPaneMaxWidthFor(width),
              primaryPane: PurchaseCatalogPane(
                viewModel: viewModel,
                capabilities: widget.capabilities,
              ),
              secondaryPane: PurchaseDraftPane(
                viewModel: viewModel,
                contactRepository: widget.contactRepository,
                submitController: _submitController,
                onSubmitSuccess: widget.onSaved,
                capabilities: widget.capabilities,
                documents: widget.documents,
              ),
            );
          }

          return _CompactPurchasingWorkspace(
            viewModel: viewModel,
            contactRepository: widget.contactRepository,
            capabilities: widget.capabilities,
            onSaved: widget.onSaved,
            documents: widget.documents,
          );
        },
      ),
    );
  }

  Future<void> _addBarcode(BuildContext context, String barcode) =>
      addScannedPurchaseBarcode(
        context,
        viewModel: viewModel,
        barcode: barcode,
        // With the draft beside the catalog, a scan leaves the keyboard on its
        // line: the count on the box is typed next, then Enter walks the rest.
        // The next scan lands as a scan all the same. On a phone the draft is
        // a sheet away, so the search box keeps the focus.
        walkLine: _twoPane,
      );
}

class _CompactPurchasingWorkspace extends StatelessWidget {
  const _CompactPurchasingWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    this.onSaved,
    this.documents,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final PurchaseOrderDocuments? documents;
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
              capabilities: capabilities,
              documents: documents,
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
