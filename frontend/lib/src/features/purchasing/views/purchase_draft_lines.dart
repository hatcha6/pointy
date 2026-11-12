import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tracking/unit_intake_permissions.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_draft_pane.dart' show PurchaseDraftLineTile;
import 'purchase_line_capture_row.dart';
import 'purchase_line_entry_guide.dart';
import 'purchase_pricing_sheet.dart';
import 'purchase_suggestion_strip.dart';

/// The draft's lines, and the keyboard that walks through them.
///
/// Selecting a line works exactly like the POS cart (the two share
/// [LineQuantityEntry]): tap or Page ↓/↑ to a line, type a quantity, `+`/`-`
/// step it, Esc clears. A purchase line has more to fill than a cart line, so
/// Enter does not stop there — it walks on, the way a paper invoice row is
/// read:
///
///   quantity ⏎ → unit ⏎ (products bought in several) → cost ⏎ →
///   expiry ⏎ (dated single-lot lines) → back to search
///
/// The unit stop takes the arrows, like any list of choices. On the quantity
/// ↑/↓ step to the line above or below and ←/→ flip the unit without
/// stopping; inside the cost or expiry ↑/↓ go to the same field of the
/// neighbouring line, so a column of costs can be typed straight down.
///
/// Esc from anywhere in that walk returns to the search box, which is where
/// the next product comes from. Nothing in the walk is a dialog, so a scan
/// arriving mid-walk still lands as a scan (BarcodeScanListener restores the
/// field it burst into) and starts the walk of its own line.
///
/// [PurchaseLineEntryGuide] under the lines says which stop the keyboard is
/// on and what the keys do there.
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
  final ScrollController _scrollController = ScrollController();
  late final LineQuantityEntry _quantityEntry = LineQuantityEntry(
    clock: widget.clock,
  );

  /// One cost and one expiry node per line, so Enter can hand focus from one
  /// field to the next across the tile boundary.
  final Map<int, FocusNode> _costNodes = {};
  final Map<int, FocusNode> _expiryNodes = {};

  /// Each line's tile, so the line the keyboard moves to can be scrolled to.
  final Map<int, GlobalKey> _tileKeys = {};
  int? _focusedVariantId;

  /// The selected line is on its unit stop rather than its quantity. Both are
  /// keyed from [_focusNode]; neither is a text field.
  bool _onUnitStep = false;
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
    _scrollController.dispose();
    for (final node in [..._costNodes.values, ..._expiryNodes.values]) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _nodeFor(Map<int, FocusNode> nodes, int variantId, String label) =>
      nodes.putIfAbsent(
        variantId,
        () =>
            FocusNode(debugLabel: 'purchase_line_${label}_$variantId')
              ..addListener(_onFieldFocusChanged),
      );

  /// The line whose cost or expiry field holds the keyboard, if one does.
  int? _fieldFocusedVariantId() {
    for (final nodes in [_costNodes, _expiryNodes]) {
      for (final entry in nodes.entries) {
        if (entry.value.hasFocus) {
          return entry.key;
        }
      }
    }
    return null;
  }

  /// A cost or expiry field took or lost the keyboard. A field reached with
  /// the mouse makes its line the selected one, so the highlight, the guide
  /// and the function keys all follow the caret.
  void _onFieldFocusChanged() {
    if (!mounted) {
      return;
    }
    final id = _fieldFocusedVariantId();
    setState(() {
      if (id != null) {
        _focusedVariantId = id;
        _onUnitStep = false;
      }
    });
    if (id != null) {
      _viewModel.selectLine(id);
    }
  }

  /// Nodes of lines that have left the draft, disposed after the frame that
  /// stops building their fields.
  void _dropStaleNodes(Set<int> live) {
    _tileKeys.removeWhere((id, _) => !live.contains(id));
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
      _onUnitStep = false;
      _quantityEntry.clear();
    });
    // The function keys fire through the global scan listener, outside this
    // focus tree, so they read the selection off the view model. Publishing it
    // here is what keeps "the line I tapped" and "the line F4 deletes" the same
    // line.
    _viewModel.selectLine(line.variant.id);
    _focusNode.requestFocus();
    _revealLine(line.variant.id);
  }

  /// Scrolls the draft so [variantId]'s line is wholly on screen. A line far
  /// enough away has no tile yet (the list builds what is near the viewport):
  /// the list first jumps to the end it lives at, which builds it.
  void _revealLine(int variantId, {bool retry = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final tile = _tileKeys[variantId]?.currentContext;
      if (tile != null) {
        for (final policy in const [
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ]) {
          unawaited(Scrollable.ensureVisible(tile, alignmentPolicy: policy));
        }
        return;
      }
      if (!retry || !_scrollController.hasClients) {
        return;
      }
      final shown = _viewModel.draft.reversed.toList(growable: false);
      final index = shown.indexWhere((line) => line.variant.id == variantId);
      if (index == -1) {
        return;
      }
      final position = _scrollController.position;
      position.jumpTo(
        index < shown.length / 2
            ? position.minScrollExtent
            : position.maxScrollExtent,
      );
      _revealLine(variantId, retry: false);
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  /// After the quantity: the unit, where the product is bought in several.
  void _afterQuantity(PurchaseDraftLine line) {
    final l10n = AppLocalizations.of(context)!;
    if (purchaseLineUnitOptions(l10n, line).length > 1) {
      setState(() => _onUnitStep = true);
      return;
    }
    _focusCost(line.variant.id);
  }

  /// The walk's next step after the quantity and unit: the line's cost.
  void _focusCost(int variantId) {
    final node = _costNodes[variantId];
    if (node == null || node.context == null) {
      _finishEntry();
      return;
    }
    setState(() => _onUnitStep = false);
    node.requestFocus();
  }

  /// ↑/↓ inside a line's cost or expiry: the same field one line up or down,
  /// falling back to that line's cost where it shows no date. False at the
  /// first or last line, and when the keyboard is not in one of those fields.
  bool _moveFieldFocus({required bool forward}) {
    final primary = FocusManager.instance.primaryFocus;
    for (final nodes in [_costNodes, _expiryNodes]) {
      final id = nodes.entries
          .where((entry) => identical(entry.value, primary))
          .firstOrNull
          ?.key;
      if (id == null) {
        continue;
      }
      final shown = _viewModel.draft.reversed.toList(growable: false);
      final index = shown.indexWhere((line) => line.variant.id == id);
      final target = index + (forward ? 1 : -1);
      if (index == -1 || target < 0 || target >= shown.length) {
        return false;
      }
      final targetId = shown[target].variant.id;
      final node = [
        nodes[targetId],
        _costNodes[targetId],
      ].where((node) => node?.context != null).firstOrNull;
      if (node == null) {
        // Not built yet: select the line, which scrolls to it.
        _viewModel.requestLineEntry(targetId);
        return true;
      }
      node.requestFocus();
      _revealLine(targetId);
      return true;
    }
    return false;
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
      _onUnitStep = false;
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
    if (_viewModel.isSubmitting || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final chord =
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed;
    final vertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    final horizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    // Inside one of a line's own fields (cost, expiry): Esc leaves the walk
    // and ↑/↓ change line. A one-line field has no use for either; the rest
    // is the field's.
    if (!node.hasPrimaryFocus) {
      if (!node.hasFocus || chord) {
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.escape) {
        _finishEntry();
        return KeyEventResult.handled;
      }
      if (vertical &&
          !keyboard.isShiftPressed &&
          _moveFieldFocus(forward: key == LogicalKeyboardKey.arrowDown)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final line = _focusedLine();
    if (line == null) {
      return KeyEventResult.ignored;
    }
    if (!chord && (vertical || horizontal)) {
      final l10n = AppLocalizations.of(context)!;
      if (vertical && !_onUnitStep) {
        _quantityEntry.clear();
        _viewModel.selectAdjacentLine(
          forward: key == LogicalKeyboardKey.arrowDown,
        );
        return KeyEventResult.handled;
      }
      // On the unit stop ↓ is the next unit, as in any list of choices; the
      // shared cycle reads a bare call as "next" and ↓ as "previous".
      cyclePurchaseLineUnit(
        l10n,
        _viewModel,
        line,
        horizontal
            ? key
            : key == LogicalKeyboardKey.arrowDown
            ? null
            : LogicalKeyboardKey.arrowDown,
      );
      return KeyEventResult.handled;
    }
    if (_onUnitStep) {
      if (chord) {
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _focusCost(line.variant.id);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _finishEntry();
        return KeyEventResult.handled;
      }
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
          _afterQuantity(line);
        },
        onDismiss: _finishEntry,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
    final step = focusedLine == null ? null : _currentStep(focusedLine);

    // The arrows in here are this pane's own (lines, units); the region keeps
    // the screen's scan listener from spending them first.
    return ArrowKeyNavigationRegion(
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _handleKey,
        onFocusChange: (_) => setState(() {}),
        child: _body(context, visibleDraft, focusedLine, scopeFocused, step),
      ),
    );
  }

  /// Which stop of [line]'s walk holds the keyboard, or null when it is on
  /// something else (a button, the unit menu, another pane).
  PurchaseLineEntryStep? _currentStep(PurchaseDraftLine line) {
    final id = line.variant.id;
    if (_focusNode.hasPrimaryFocus) {
      return _onUnitStep
          ? PurchaseLineEntryStep.unit
          : PurchaseLineEntryStep.quantity;
    }
    if (_costNodes[id]?.hasFocus ?? false) {
      return PurchaseLineEntryStep.cost;
    }
    if (_expiryNodes[id]?.hasFocus ?? false) {
      return PurchaseLineEntryStep.expiry;
    }
    return null;
  }

  Widget _body(
    BuildContext context,
    List<PurchaseDraftLine> visibleDraft,
    PurchaseDraftLine? focusedLine,
    bool scopeFocused,
    PurchaseLineEntryStep? step,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final viewModel = _viewModel;
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scrollController,
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
                    step,
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
        if (step != null && focusedLine != null)
          PurchaseLineEntryGuide(
            steps: purchaseLineEntrySteps(l10n, focusedLine),
            current: step,
          ),
      ],
    );
  }

  Widget _lineTile(
    BuildContext context,
    PurchaseDraftLine line,
    int index,
    bool scopeFocused,
    PurchaseLineEntryStep? step,
  ) {
    final viewModel = _viewModel;
    final variant = line.variant;
    final enabled = !viewModel.isSubmitting;
    final selected = scopeFocused && _focusedVariantId == variant.id;
    return KeyedSubtree(
      key: _tileKeys.putIfAbsent(
        variant.id,
        () => GlobalKey(debugLabel: 'purchase_draft_tile_${variant.id}'),
      ),
      child: _tile(context, line, index, enabled, selected, step),
    );
  }

  Widget _tile(
    BuildContext context,
    PurchaseDraftLine line,
    int index,
    bool enabled,
    bool selected,
    PurchaseLineEntryStep? step,
  ) {
    final viewModel = _viewModel;
    final variant = line.variant;
    return PurchaseDraftLineTile(
      key: ValueKey('purchase_draft_line_${variant.id}'),
      line: line,
      previewLine: viewModel.discountPreviewLineForDraftIndex(
        viewModel.draft.length - index - 1,
      ),
      enabled: enabled,
      selected: selected,
      unitHighlighted: selected && step == PurchaseLineEntryStep.unit,
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
