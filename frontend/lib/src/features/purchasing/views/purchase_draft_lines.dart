import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tracking/unit_intake_permissions.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_draft_pane.dart' show PurchaseDraftLineTile;
import 'purchase_line_capture_row.dart';
import 'purchase_pricing_sheet.dart';
import 'purchase_suggestion_strip.dart';

/// The draft's lines, and the keyboard that walks through them.
///
/// Selecting a line works exactly like the POS cart (the two share
/// [LineQuantityEntry]): tap or Page ↓/↑ to a line, type a quantity, `+`/`-`
/// step it, Esc clears. A purchase line has more to fill than a cart line, so
/// Enter does not stop there — it walks on, the way a paper invoice is read
/// left to right:
///
///   quantity ⏎ → cost ⏎ → expiry ⏎ (lot-tracked lines) → back to search
///
/// Esc from anywhere in that walk returns to the search box, which is where
/// the next product comes from. Nothing in the walk is a dialog, so a scan
/// arriving mid-walk still lands as a scan (BarcodeScanListener restores the
/// field it burst into).
class PurchaseDraftLines extends StatefulWidget {
  const PurchaseDraftLines({
    super.key,
    required this.viewModel,
    this.permissions = UnitIntakePermissions.none,
    @visibleForTesting this.clock,
  });

  final PurchaseViewModel viewModel;
  final UnitIntakePermissions permissions;

  /// The scanner-burst guard's time source; tests drive it.
  final DateTime Function()? clock;

  @override
  State<PurchaseDraftLines> createState() => _PurchaseDraftLinesState();
}

class _PurchaseDraftLinesState extends State<PurchaseDraftLines> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'purchase_draft_keyboard');
  late final LineQuantityEntry _quantityEntry = LineQuantityEntry(
    clock: widget.clock,
  );

  /// One cost and one expiry node per line, so Enter can hand focus from one
  /// field to the next across the tile boundary.
  final Map<int, FocusNode> _costNodes = {};
  final Map<int, FocusNode> _expiryNodes = {};
  int? _focusedVariantId;
  int _lastLineCount = -1;
  int _handledEntryToken = 0;

  PurchaseViewModel get _viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _handledEntryToken = _viewModel.lineEntryToken;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    for (final node in [..._costNodes.values, ..._expiryNodes.values]) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _nodeFor(Map<int, FocusNode> nodes, int variantId, String label) =>
      nodes.putIfAbsent(
        variantId,
        () => FocusNode(debugLabel: 'purchase_line_${label}_$variantId'),
      );

  /// Nodes of lines that have left the draft, disposed after the frame that
  /// stops building their fields.
  void _dropStaleNodes(Set<int> live) {
    final stale = [
      for (final nodes in [_costNodes, _expiryNodes])
        for (final id in nodes.keys.toList())
          if (!live.contains(id)) nodes.remove(id)!,
    ];
    if (stale.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in stale) {
        node.dispose();
      }
    });
  }

  PurchaseDraftLine? _focusedLine() {
    final id = _focusedVariantId;
    if (id == null) {
      return null;
    }
    return _viewModel.draft.where((line) => line.variant.id == id).firstOrNull;
  }

  void _focusLine(PurchaseDraftLine line) {
    setState(() {
      _focusedVariantId = line.variant.id;
      _quantityEntry.clear();
    });
    // The function keys fire through the global scan listener, outside this
    // focus tree, so they read the selection off the view model. Publishing it
    // here is what keeps "the line I tapped" and "the line F4 deletes" the same
    // line.
    _viewModel.selectLine(line.variant.id);
    _focusNode.requestFocus();
  }

  /// The walk's next step after the quantity: the line's cost.
  void _focusCost(int variantId) {
    final node = _costNodes[variantId];
    if (node == null) {
      _finishEntry();
      return;
    }
    node.requestFocus();
  }

  /// After the cost: the expiry, where the line shows one inline.
  void _afterCost(PurchaseDraftLine line) {
    final expiry = _expiryNodes[line.variant.id];
    if (PurchaseLineCaptureRow.hasInlineExpiry(line) && expiry != null) {
      expiry.requestFocus();
      return;
    }
    _finishEntry();
  }

  /// Done with this line: back to the search box for the next product.
  void _finishEntry() {
    setState(() {
      _focusedVariantId = null;
      _quantityEntry.clear();
    });
    _viewModel.selectLine(null);
    _viewModel.requestSearchFocus();
  }

  /// A request from outside the pane — a keyboard add, F5, Page ↓/↑ — to walk
  /// a line. Run after the frame, because the line it names may only now be
  /// getting its tile.
  void _takeEntryRequest() {
    final token = _viewModel.lineEntryToken;
    if (token == _handledEntryToken) {
      return;
    }
    _handledEntryToken = token;
    final variantId = _viewModel.lineEntryVariantId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || variantId == null) {
        return;
      }
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        return;
      }
      final line = _viewModel.draft
          .where((line) => line.variant.id == variantId)
          .firstOrNull;
      if (line != null) {
        _focusLine(line);
      }
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (_viewModel.isSubmitting) {
      return KeyEventResult.ignored;
    }
    // Esc inside one of a line's own fields (cost, expiry) leaves the walk.
    // The field itself has no use for it.
    if (!node.hasPrimaryFocus && node.hasFocus) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _finishEntry();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final line = _focusedLine();
    if (line == null) {
      return KeyEventResult.ignored;
    }
    return _quantityEntry.handle(
      node,
      event,
      LineQuantityActions(
        onPendingChanged: () => setState(() {}),
        onIncrement: () => unawaited(
          _viewModel.addVariant(line.variant, source: 'purchase_keyboard'),
        ),
        onDecrement: () => _viewModel.decrementVariant(
          line.variant,
          source: 'purchase_keyboard',
        ),
        onCommit: (quantity) {
          if (quantity != null) {
            _viewModel.setLineQuantity(
              line.variant,
              quantity,
              source: 'purchase_quantity_edit',
            );
          }
          _focusCost(line.variant.id);
        },
        onDismiss: _finishEntry,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final viewModel = _viewModel;
    final visibleDraft = viewModel.draft.reversed.toList(growable: false);
    // A structural change (line added/removed) invalidates half-typed input.
    if (visibleDraft.length != _lastLineCount) {
      _lastLineCount = visibleDraft.length;
      _quantityEntry.clear();
    }
    _dropStaleNodes({for (final line in visibleDraft) line.variant.id});
    _takeEntryRequest();
    final focusedLine = _focusedLine();
    final scopeFocused = _focusNode.hasFocus;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(
                spacing.md,
                spacing.sm,
                spacing.md,
                spacing.md,
              ),
              children: [
                if (viewModel.draft.isEmpty)
                  SizedBox(
                    height: 240,
                    child: PointyEmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: l10n.emptyPurchaseDraft,
                      message: l10n.emptyPurchaseDraftMessage,
                    ),
                  )
                else
                  for (
                    var index = 0;
                    index < visibleDraft.length;
                    index += 1
                  ) ...[
                    if (index > 0) Divider(height: 1, color: colors.line),
                    _lineTile(
                      context,
                      visibleDraft[index],
                      index,
                      scopeFocused,
                    ),
                  ],
              ],
            ),
          ),
          if (_quantityEntry.pending.isNotEmpty && focusedLine != null)
            PendingQuantityBanner(
              quantity: _quantityEntry.pending,
              productName: focusedLine.variant.productLabel,
            ),
        ],
      ),
    );
  }

  Widget _lineTile(
    BuildContext context,
    PurchaseDraftLine line,
    int index,
    bool scopeFocused,
  ) {
    final viewModel = _viewModel;
    final variant = line.variant;
    final enabled = !viewModel.isSubmitting;
    return PurchaseDraftLineTile(
      key: ValueKey('purchase_draft_line_${variant.id}'),
      line: line,
      previewLine: viewModel.discountPreviewLineForDraftIndex(
        viewModel.draft.length - index - 1,
      ),
      enabled: enabled,
      selected: scopeFocused && _focusedVariantId == variant.id,
      onSelect: enabled ? () => _focusLine(line) : null,
      onAdd: () => viewModel.addVariant(
        variant,
        source: 'purchase_draft_quantity_button',
      ),
      onRemove: () => viewModel.decrementVariant(
        variant,
        source: 'purchase_draft_quantity_button',
      ),
      onCostChanged: (unitCost) => viewModel.updateLineCost(variant, unitCost),
      costFocusNode: _nodeFor(_costNodes, variant.id, 'cost'),
      onCostSubmitted: () => _afterCost(line),
      onUnitChanged: (code, label, factor, allowsFractional) {
        viewModel.updateLineUnit(
          variant,
          unitCode: code,
          unitLabel: label,
          unitFactor: factor,
          allowsFractional: allowsFractional,
        );
      },
      onQuantityChanged: (quantity) => viewModel.setLineQuantity(
        variant,
        quantity,
        source: 'purchase_quantity_edit',
      ),
      previousBaseCost: viewModel.previousBaseCostFor(variant.id),
      onChangePrices: () => unawaited(
        showPurchasePricingSheet(context, viewModel: viewModel, line: line),
      ),
      quantityHint: PurchaseQuantityHintChip.maybeBuild(
        viewModel: viewModel,
        line: line,
      ),
      onLineTotalEntry: (total) =>
          viewModel.setLineCostFromTotal(variant, total),
      capture: variant.trackingMode.isTracked
          ? PurchaseLineCaptureRow(
              line: line,
              enabled: enabled,
              expiryFocusNode: _nodeFor(_expiryNodes, variant.id, 'expiry'),
              onExpiryChanged: (expiry) =>
                  viewModel.setLineExpiry(variant, expiry),
              onExpirySubmitted: _finishEntry,
              onCaptureLots: () => unawaited(
                capturePurchaseLine(
                  context,
                  viewModel: viewModel,
                  line: line,
                  permissions: widget.permissions,
                  units: false,
                ),
              ),
              onCaptureUnits: () => unawaited(
                capturePurchaseLine(
                  context,
                  viewModel: viewModel,
                  line: line,
                  permissions: widget.permissions,
                  lots: false,
                ),
              ),
            )
          : null,
    );
  }
}
