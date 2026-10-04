import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../core/result.dart';
import '../../../data/models/receipt_capture.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/models/tracking_mode.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/units.dart';
import 'batch_capture_sheet.dart';

/// Turning stock a shop already has into stock it can name (§6.10).
///
/// A shop with forty anonymous iPhones cannot flip the switch and lose them,
/// and it cannot invent forty IMEIs either — the only honest way to identify
/// forty handsets is for somebody to pick each one up. **Nothing moves.** The
/// articles are created at the rate the ledger already decided, so the bin is
/// unchanged by construction and the shelf is worth exactly what it was worth
/// a moment ago.
class OpeningIdentificationScreen extends StatefulWidget {
  const OpeningIdentificationScreen({super.key, required this.repository});

  final TrackedStockRepository repository;

  @override
  State<OpeningIdentificationScreen> createState() =>
      _OpeningIdentificationScreenState();
}

class _OpeningIdentificationScreenState
    extends State<OpeningIdentificationScreen> {
  List<OpeningIdentificationRow> _rows = const [];
  OpeningIdentificationRow? _current;
  final List<String> _codes = [];

  /// The lots the stock on the shelf belongs to, for a product that tracks
  /// them — read off the cartons, the same sheet receiving uses.
  List<ReceiptBatchCapture> _lots = const [];
  bool _isLoading = true;
  bool _isSaving = false;

  TrackingMode get _mode => TrackingMode.fromWire(_current?.trackingMode);

  /// Lot quantities name the whole outstanding quantity — the server refuses
  /// a lot split that does not add up, so the button waits for it too.
  bool get _lotsComplete {
    final current = _current;
    if (current == null || !_mode.tracksLots) {
      return true;
    }
    final captured = _lots.fold<double>(0, (sum, lot) => sum + lot.quantity);
    return _lots.isNotEmpty && (captured - current.outstanding).abs() < 0.0005;
  }

  bool get _unitsComplete {
    final current = _current;
    if (current == null || !_mode.tracksUnits) {
      return true;
    }
    return _codes.length == current.outstanding.round();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final result = await widget.repository.loadOpeningWorklist();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _rows = result is Ok<List<OpeningIdentificationRow>>
          ? result.value
          : const [];
      // Keep the selection if it is still outstanding; a run that reset to the
      // top of the list after every save would be unusable on a long shelf.
      final current = _current;
      if (current != null &&
          !_rows.any((row) => row.variantId == current.variantId)) {
        _current = null;
        _codes.clear();
        _lots = const [];
      }
    });
  }

  void _addCode(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty || _codes.contains(trimmed)) {
      return;
    }
    final current = _current;
    if (current == null ||
        !_mode.tracksUnits ||
        _codes.length >= current.outstanding.round()) {
      return;
    }
    setState(() => _codes.add(trimmed));
  }

  Future<void> _captureLots() async {
    final current = _current;
    if (current == null) {
      return;
    }
    final captured = await showBatchCaptureSheet(
      context,
      productLabel: current.variantName,
      expectedQuantity: current.outstanding,
      initial: _lots,
      // A serialised pack's lot is one header over its scan loop.
      singleLot: _mode.tracksUnits,
    );
    if (captured == null || !mounted) {
      return;
    }
    setState(() => _lots = captured);
  }

  Future<void> _submit({required bool captureLater}) async {
    final current = _current;
    if (current == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSaving = true);
    final result = await widget.repository.identifyOpeningStock(
      variantId: current.variantId,
      units: [
        if (_mode.tracksUnits)
          for (final code in _codes) <String, Object?>{'code': code},
      ],
      batches: [
        if (_mode.tracksLots)
          for (final lot in _lots) lot.toJson(),
      ],
      captureLater: captureLater,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    switch (result) {
      case Ok<int>(:final value):
        setState(() {
          _codes.clear();
          _lots = const [];
        });
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.openingIdentifyDone(value))),
        );
      case Error<int>(:final exception):
        // The scans stay: the refusal is usually one code already in stock,
        // and making somebody scan forty boxes again over it would be cruel.
        messenger.showSnackBar(
          SnackBar(content: Text(errorMessageFor(exception, l10n))),
        );
        return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final current = _current;

    return PointyScaffold(
      appBar: PointyAppBar(
        title: Text(l10n.openingIdentifyTitle),
        isLoading: _isSaving,
      ),
      body: BarcodeScanListener(
        onBarcodeScanned: _addCode,
        child: _isLoading
            ? const Center(child: PointySpinner())
            : ListView(
                padding: spacing.pagePadding,
                children: [
                  AdaptiveMaxWidth(
                    width: AppContentWidth.detail,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        PointyDetailCallout(
                          icon: Icons.playlist_add_check_outlined,
                          title: l10n.openingIdentifyTitle,
                          message: l10n.openingIdentifyBody,
                        ),
                        SizedBox(height: spacing.lg),
                        if (_rows.isEmpty)
                          PointyEmptyState(
                            icon: Icons.check_circle_outline,
                            title: l10n.openingIdentifyEmpty,
                          )
                        else
                          for (final row in _rows)
                            RadioListTile<int>(
                              value: row.variantId,
                              // ignore: deprecated_member_use
                              groupValue: current?.variantId,
                              // ignore: deprecated_member_use
                              onChanged: (_) => setState(() {
                                _current = row;
                                _codes.clear();
                                _lots = const [];
                              }),
                              title: Text(row.variantName),
                              subtitle: Text(
                                l10n.openingIdentifyOutstanding(
                                  row.outstanding.toStringAsFixed(
                                    row.outstanding.truncateToDouble() ==
                                            row.outstanding
                                        ? 0
                                        : 3,
                                  ),
                                ),
                              ),
                            ),
                        if (current != null) ...[
                          SizedBox(height: spacing.lg),
                          PointySectionHeader(
                            title: current.variantName,
                            trailing: _mode.tracksUnits
                                ? Text(
                                    '${_codes.length} / '
                                    '${current.outstanding.round()}',
                                  )
                                : null,
                          ),
                          if (_mode.tracksLots)
                            _LotsRow(
                              lots: _lots,
                              expected: current.outstanding,
                              complete: _lotsComplete,
                              onCapture: _isSaving ? null : _captureLots,
                            ),
                          if (_mode.tracksUnits) ...[
                            _CodeField(onSubmit: _addCode),
                            for (final code in _codes)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.qr_code_2_outlined),
                                title: Text(code),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () =>
                                      setState(() => _codes.remove(code)),
                                ),
                              ),
                          ],
                          SizedBox(height: spacing.lg),
                          FilledButton(
                            onPressed:
                                _isSaving || !_unitsComplete || !_lotsComplete
                                ? null
                                : () => _submit(captureLater: false),
                            child: Text(l10n.saveButton),
                          ),
                          // "Identify later" is allowed, and visible: the
                          // articles land on the missing-identifier worklist
                          // and the till refuses to sell one until somebody
                          // scans it (§6.1). Articles only — a lot the server
                          // invented would have no number to recall by.
                          if (_mode.tracksUnits) ...[
                            SizedBox(height: spacing.sm),
                            OutlinedButton(
                              onPressed:
                                  _isSaving || _codes.isEmpty || !_lotsComplete
                                  ? null
                                  : () => _submit(captureLater: true),
                              child: Text(l10n.openingIdentifyLater),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _CodeField extends StatefulWidget {
  const _CodeField({required this.onSubmit});

  final ValueChanged<String> onSubmit;

  @override
  State<_CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<_CodeField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _controller,
      focusNode: _focus,
      autofocus: true,
      decoration: InputDecoration(
        labelText: l10n.stockCountScanIdentifierHint,
        prefixIcon: const Icon(Icons.qr_code_scanner_outlined),
      ),
      onSubmitted: (value) {
        widget.onSubmit(value);
        _controller.clear();
        _focus.requestFocus();
      },
    );
  }
}

/// The lots the shelf's stock belongs to, and the button that records them.
class _LotsRow extends StatelessWidget {
  const _LotsRow({
    required this.lots,
    required this.expected,
    required this.complete,
    required this.onCapture,
  });

  final List<ReceiptBatchCapture> lots;
  final double expected;
  final bool complete;
  final VoidCallback? onCapture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final captured = lots.fold<double>(0, (sum, lot) => sum + lot.quantity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            complete ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: complete ? colors.primaryStrong : colors.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l10n.purchaseReceiveLotsCaptured(
                formatQuantity(captured),
                formatQuantity(expected),
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: complete ? colors.primaryStrong : colors.warning,
              ),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('opening_identify_capture_lots'),
            onPressed: onCapture,
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: Text(l10n.purchaseReceiveCaptureLots),
          ),
        ],
      ),
    );
  }
}
