part of 'purchase_order_details_screen.dart';

/// The receiving dialog, for a caller outside the order's own screen — the
/// purchasing workspace, right after it created an order whose goods have to
/// be scanned before they can be received.
///
/// Returns what the receiver confirmed, ready to send, or null when they
/// closed it: the order then simply waits, submitted, for its receipt.
Future<PurchaseReceiveDraft?> showPurchaseReceiveCaptureDialog(
  BuildContext context, {
  required PurchaseOrder order,
  UnitIntakePermissions permissions = UnitIntakePermissions.none,
}) async {
  final result = await showDialog<_PurchaseReceiveDialogResult>(
    context: context,
    builder: (context) =>
        _PurchaseReceiveDialog(order: order, permissions: permissions),
  );
  if (result == null || result.lines.isEmpty) {
    return null;
  }
  return PurchaseReceiveDraft(lines: result.lines, note: result.note);
}

class _PurchaseReceiveDialog extends StatefulWidget {
  const _PurchaseReceiveDialog({
    required this.order,
    this.permissions = UnitIntakePermissions.none,
  });

  final PurchaseOrder order;
  final UnitIntakePermissions permissions;

  @override
  State<_PurchaseReceiveDialog> createState() => _PurchaseReceiveDialogState();
}

class _PurchaseReceiveDialogState extends State<_PurchaseReceiveDialog> {
  late final List<PurchaseOrderLine> _receivableLines = widget.order.lines
      .where((line) => line.receivableQuantity > 0)
      .toList(growable: false);
  late final Map<int, TextEditingController> _receivedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(
        text: formatQuantity(line.receivableQuantity),
      ),
  };
  late final Map<int, TextEditingController> _damagedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  late final Map<int, TextEditingController> _rejectedControllers = {
    for (final line in _receivableLines)
      line.id: TextEditingController(text: '0'),
  };
  final TextEditingController _noteController = TextEditingController();

  /// What the receiver captured per line, with the goods in front of them.
  /// Empty for every delivery of everything a shop counts rather than names.
  final Map<int, ReceiptLineCapture> _captures = {};
  bool _showQuantityError = false;
  bool _showCaptureError = false;

  @override
  void dispose() {
    for (final controller in _receivedControllers.values) {
      controller.dispose();
    }
    for (final controller in _damagedControllers.values) {
      controller.dispose();
    }
    for (final controller in _rejectedControllers.values) {
      controller.dispose();
    }
    _noteController.dispose();
    super.dispose();
  }

  double _quantity(Map<int, TextEditingController> controllers, int lineId) =>
      double.tryParse(controllers[lineId]!.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final compact = MediaQuery.sizeOf(context).width < 600;

    return AlertDialog(
      // A phone gives the three quantity boxes every pixel it has: the
      // default 40-point inset cut their labels to «مستلم…» and «مرفو…».
      insetPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      contentPadding: compact
          ? const EdgeInsets.fromLTRB(16, 16, 16, 0)
          : const EdgeInsets.fromLTRB(24, 16, 24, 0),
      icon: const Icon(Icons.inventory_2_outlined),
      title: Text(l10n.purchaseReceiveTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_receivableLines.isEmpty)
                Text(l10n.purchaseReceiveNoOpenLines)
              else
                for (final line in _receivableLines)
                  _PurchaseReceiveLineInput(
                    line: line,
                    stackQuantities: compact,
                    receivedController: _receivedControllers[line.id]!,
                    damagedController: _damagedControllers[line.id]!,
                    rejectedController: _rejectedControllers[line.id]!,
                    capture: _captures[line.id],
                    onCapture: line.trackingMode.isTracked
                        ? () => _captureFor(line)
                        : null,
                    onChanged: () => setState(() {
                      _showQuantityError = false;
                      _showCaptureError = false;
                    }),
                  ),
              if (_showQuantityError) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.purchaseReceiveInvalidQuantityError,
                    style: TextStyle(color: colors.danger),
                  ),
                ),
              ],
              if (_showCaptureError) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.purchaseReceiveCaptureRequired,
                    key: const ValueKey('purchase-receive-capture-error'),
                    style: TextStyle(color: colors.danger),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _noteController,
                decoration: InputDecoration(
                  labelText: l10n.purchaseReceiveNoteLabel,
                  hintText: l10n.purchaseReceiveNoteHint,
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        TutorTarget(
          anchor: TutorAnchor.purchaseReceiveConfirmButton,
          child: FilledButton(
            onPressed: _receivableLines.isEmpty ? null : _submit,
            child: Text(l10n.confirmButton),
          ),
        ),
      ],
    );
  }

  /// Open the right capture sheet for this line's mode.
  ///
  /// ``serial_batch`` asks for both, in the order a receiver actually works: the
  /// lot header once — it is printed once on the carton — then the scan loop for
  /// each pack beneath it, which names that lot above its scan field.
  Future<void> _captureFor(PurchaseOrderLine line) async {
    final mode = line.trackingMode;
    final received = _quantity(_receivedControllers, line.id);
    final damaged = _quantity(_damagedControllers, line.id);
    if (received + damaged <= 0) {
      return;
    }
    final existing = _captures[line.id];
    final label = line.displayName.isEmpty
        ? AppLocalizations.of(context)!.purchaseOrderUnknownProduct
        : line.displayName;

    // Identifiers count articles, not packs. A box of three handsets is three
    // IMEIs and a carton of twelve boxes is twelve lot quantities, and the
    // backend validates the capture against exactly that — so a sheet seeded
    // with the purchase-unit count can never be completed on any line bought
    // in anything but the base unit.
    final receivedBase = line.toBaseQuantity(received);
    final damagedBase = line.toBaseQuantity(damaged);

    var batches = existing?.batches ?? const <ReceiptBatchCapture>[];
    if (mode.tracksLots) {
      final captured = await showBatchCaptureSheet(
        context,
        productLabel: label,
        expectedQuantity: receivedBase,
        initial: batches,
        suggestedExpiry: line.expiryDate,
        // A serialised pack's lot is one header over the whole scan loop.
        singleLot: mode.tracksUnits,
        // `tracks_expiry` on a purchase line is the product's
        // `expiry_required`: these lots must each say when they go off.
        expiryRequired: line.tracksExpiry,
      );
      if (captured == null || !mounted) {
        return;
      }
      batches = captured;
    }

    var units = existing?.units ?? const <ReceiptUnitCapture>[];
    if (mode.tracksUnits) {
      final captured = await showUnitCaptureSheet(
        context,
        productLabel: label,
        // Damaged goods are units too, in the same table and in the same
        // capture — two disjoint sets, neither overwriting the other.
        expectedCount: (receivedBase + damagedBase).round(),
        lineUnitCost: line.baseUnitCost,
        initial: units,
        // The shop's own answer to "a truck at six in the evening": receive
        // now, scan later. The articles not scanned wait, unsellable, on the
        // missing-identifier list.
        allowCaptureLater: TrackingFeaturesScope.of(context).captureLater,
        assetTypeId: line.assetTypeId,
        identifierKind: line.identifierKind,
        lot: batches.isEmpty ? null : batches.first,
        canSetPrice: widget.permissions.canSetPrice,
        canSetWarranty: widget.permissions.canSetWarranty,
      );
      if (captured == null || !mounted) {
        return;
      }
      units = captured;
    }

    setState(() {
      _captures[line.id] = ReceiptLineCapture(units: units, batches: batches);
      _showCaptureError = false;
    });
  }

  /// Whether this line's identifiers cover exactly what is being received —
  /// rechecked at confirm, because the quantities can change after a capture.
  bool _captureCovers(PurchaseOrderLine line, double received, double damaged) {
    final mode = line.trackingMode;
    final capture = _captures[line.id];
    if (mode.tracksLots) {
      final expected = line.toBaseQuantity(received);
      final captured = capture?.capturedBatchQuantity ?? 0;
      if (expected > 0 && (captured - expected).abs() >= 0.0005) {
        return false;
      }
    }
    if (mode.tracksUnits) {
      final expected = line.toBaseQuantity(received + damaged).round();
      final captured = capture?.units.length ?? 0;
      final captureLater = TrackingFeaturesScope.of(context).captureLater;
      if (captured > expected || (!captureLater && captured != expected)) {
        return false;
      }
    }
    return true;
  }

  void _submit() {
    final lines = <PurchaseReceiveLineDraft>[];
    for (final line in _receivableLines) {
      final received = double.tryParse(
        _receivedControllers[line.id]!.text.trim(),
      );
      final damaged = double.tryParse(
        _damagedControllers[line.id]!.text.trim(),
      );
      final rejected = double.tryParse(
        _rejectedControllers[line.id]!.text.trim(),
      );
      if (received == null ||
          damaged == null ||
          rejected == null ||
          received < 0 ||
          damaged < 0 ||
          rejected < 0) {
        setState(() => _showQuantityError = true);
        return;
      }
      if (received > 0 || damaged > 0 || rejected > 0) {
        final capture = _captures[line.id];
        // Identifiers are captured where the goods physically are. A line that
        // needs them and has not got them is refused here rather than by the
        // backend, so the receiver finds out while the boxes are still open —
        // unless the shop receives articles first and names them later. A lot
        // is never left to later: one the server invents has no number to
        // recall by.
        if (line.trackingMode.isTracked &&
            (received > 0 || damaged > 0) &&
            !_captureCovers(line, received, damaged)) {
          setState(() => _showCaptureError = true);
          return;
        }
        lines.add(
          PurchaseReceiveLineDraft(
            purchaseLineId: line.id,
            quantityReceived: received,
            quantityDamaged: damaged,
            quantityRejected: rejected,
            // Dates belong to lots: the line records the first of them to
            // expire, and a line without lots records none.
            expiryDate: earliestLotExpiry(capture?.batches ?? const []),
            capture: capture,
          ),
        );
      }
    }
    if (lines.isEmpty) {
      setState(() => _showQuantityError = true);
      return;
    }
    _showQuantityError = false;
    _showCaptureError = false;
    Navigator.of(context).pop(
      _PurchaseReceiveDialogResult(
        lines: lines,
        note: _noteController.text.trim(),
      ),
    );
  }
}

class _PurchaseReceiveLineInput extends StatelessWidget {
  const _PurchaseReceiveLineInput({
    required this.line,
    required this.receivedController,
    required this.damagedController,
    required this.rejectedController,
    this.capture,
    this.onCapture,
    required this.onChanged,
    this.stackQuantities = false,
  });

  final PurchaseOrderLine line;

  /// What arrived on its own row, the other two beneath it. Decided from the
  /// screen, not a LayoutBuilder: an AlertDialog sizes its content by asking
  /// for its intrinsic width, which a LayoutBuilder cannot answer.
  final bool stackQuantities;
  final TextEditingController receivedController;
  final TextEditingController damagedController;
  final TextEditingController rejectedController;

  /// What has been captured for this line so far, so the row can say whether
  /// the identifiers are still owed. Null for an untracked line.
  final ReceiptLineCapture? capture;

  /// Opens the capture sheet. Null when this line's goods have no identity.
  final VoidCallback? onCapture;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final received = double.tryParse(receivedController.text.trim()) ?? 0;
    final damaged = double.tryParse(damagedController.text.trim()) ?? 0;
    final rejected = double.tryParse(rejectedController.text.trim()) ?? 0;
    final afterDelivered =
        line.receivedQuantity + line.damagedQuantity + received + damaged;
    final afterOpen = line.receivableQuantity - received - damaged - rejected;
    final afterVariance = afterDelivered - line.quantity;

    Widget quantityField(
      TextEditingController controller,
      String label, {
      bool tutor = false,
    }) {
      final field = TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, isDense: true),
        onChanged: (_) => onChanged(),
      );
      if (!tutor) return field;
      return TutorTarget(
        anchor: TutorAnchor.purchaseReceiveQuantityField,
        // A delivery that came up short is the point of the lesson, so the
        // step has to name the line that is short.
        id: line.variantSku,
        child: field,
      );
    }

    final receivedField = quantityField(
      receivedController,
      l10n.purchaseReceiveReceivedLabel,
      tutor: true,
    );
    final damagedField = quantityField(
      damagedController,
      l10n.purchaseReceiveDamagedLabel,
    );
    final rejectedField = quantityField(
      rejectedController,
      l10n.purchaseReceiveRejectedLabel,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            line.displayName.isEmpty
                ? l10n.purchaseOrderUnknownProduct
                : line.displayName,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (line.variantSku != null && line.variantSku!.isNotEmpty)
                line.variantSku!,
              l10n.purchaseReceiveExpectedValue(formatQuantity(line.quantity)),
              l10n.purchaseReceiveAlreadyValue(
                formatQuantity(line.receivedQuantity),
              ),
              l10n.purchaseReceiveOpenValue(
                formatQuantity(line.receivableQuantity),
              ),
              if (line.damagedQuantity > 0)
                l10n.purchaseLineDamagedQuantity(
                  formatQuantity(line.damagedQuantity),
                ),
              if (line.rejectedQuantity > 0)
                l10n.purchaseLineRejectedQuantity(
                  formatQuantity(line.rejectedQuantity),
                ),
              l10n.purchaseReceiveOpenAfterValue(
                formatQuantity(afterOpen < 0 ? 0 : afterOpen),
              ),
              l10n.purchaseReceiveAfterVarianceValue(
                _formatSignedQuantityValue(afterVariance),
              ),
            ].join(' • '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          // Three boxes side by side need ~130 points each before their
          // labels fit; on a phone, what arrived gets its own row.
          if (stackQuantities) ...[
            receivedField,
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: damagedField),
                const SizedBox(width: 8),
                Expanded(child: rejectedField),
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(child: receivedField),
                const SizedBox(width: 8),
                Expanded(child: damagedField),
                const SizedBox(width: 8),
                Expanded(child: rejectedField),
              ],
            ),
          if (onCapture != null) ...[
            const SizedBox(height: 8),
            _CaptureRow(
              line: line,
              capture: capture,
              // Base units, because that is what the sheet captures and what
              // the backend counts — the row must read «12 من 12», not
              // «1 من 12», for a carton of twelve.
              unitCount: line.toBaseQuantity(received + damaged),
              lotQuantity: line.toBaseQuantity(received),
              onCapture: onCapture!,
            ),
          ],
        ],
      ),
    );
  }
}

/// Whether this line still owes its identifiers, and the button that captures
/// them.
///
/// Reads as a residual rather than a tick, because that is the question the
/// receiver is actually answering: *how many of these forty boxes have I
/// scanned?* Then what else is known: how many handsets are described, the
/// first lot to expire — the dates the line used to ask for separately.
class _CaptureRow extends StatelessWidget {
  const _CaptureRow({
    required this.line,
    required this.capture,
    required this.unitCount,
    required this.lotQuantity,
    required this.onCapture,
  });

  final PurchaseOrderLine line;
  final ReceiptLineCapture? capture;
  final double unitCount;
  final double lotQuantity;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final mode = line.trackingMode;
    final captured = capture;
    final units = captured?.units ?? const <ReceiptUnitCapture>[];
    final lotsDone =
        !mode.tracksLots ||
        ((captured?.capturedBatchQuantity ?? 0) - lotQuantity).abs() < 0.0005;
    final unitsDone = !mode.tracksUnits || units.length >= unitCount.round();
    final done = lotsDone && unitsDone && unitCount > 0;
    final earliest = earliestLotExpiry(captured?.batches ?? const []);
    final described = units.where((unit) => unit.attributes.isNotEmpty).length;

    final status = [
      mode.tracksUnits
          ? l10n.purchaseReceiveUnitsCaptured(units.length, unitCount.round())
          : l10n.purchaseReceiveLotsCaptured(
              formatQuantity(captured?.capturedBatchQuantity ?? 0),
              formatQuantity(lotQuantity),
            ),
      if (mode.tracksUnits && line.assetTypeId != null && units.isNotEmpty)
        l10n.purchaseReceiveDetailsCaptured(described, units.length),
      if (earliest != null)
        l10n.purchaseReceiveEarliestExpiry(formatDate(earliest)),
    ].join(' · ');

    final hasCapture = captured != null && !captured.isEmpty;
    final buttonLabel = mode.tracksUnits
        ? (hasCapture
              ? l10n.purchaseReceiveCaptureUnitsEdit
              : l10n.purchaseReceiveCaptureUnits)
        : (hasCapture
              ? l10n.purchaseReceiveCaptureLotsEdit
              : l10n.purchaseReceiveCaptureLots);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              done ? Icons.check_circle_outline : Icons.error_outline,
              size: 18,
              color: done ? colors.primaryStrong : colors.warning,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: done ? colors.primaryStrong : colors.warning,
                ),
              ),
            ),
            TextButton.icon(
              key: ValueKey('purchase-receive-capture-${line.id}'),
              onPressed: unitCount > 0 ? onCapture : null,
              icon: const Icon(Icons.qr_code_scanner_outlined, size: 18),
              label: Text(buttonLabel),
            ),
          ],
        ),
        // The line used to ask for one date beside the lots' own; a delivery
        // of two lots has two, so they are typed where the lots are.
        if (mode.tracksLots && line.tracksExpiry && earliest == null)
          Text(
            l10n.purchaseReceiveExpiryOnLots,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    );
  }
}

class _PurchaseReceiveDialogResult {
  const _PurchaseReceiveDialogResult({required this.lines, required this.note});

  final List<PurchaseReceiveLineDraft> lines;
  final String note;
}
