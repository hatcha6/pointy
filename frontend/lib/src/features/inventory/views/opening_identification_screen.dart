import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';

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
  bool _isLoading = true;
  bool _isSaving = false;

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
      }
    });
  }

  void _addCode(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty || _codes.contains(trimmed)) {
      return;
    }
    final current = _current;
    if (current == null || _codes.length >= current.outstanding.round()) {
      return;
    }
    setState(() => _codes.add(trimmed));
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
        for (final code in _codes) <String, Object?>{'code': code},
      ],
      captureLater: captureLater,
    );
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      _codes.clear();
    });
    if (result is Ok<int>) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.openingIdentifyDone(result.value))),
      );
    } else if (result is Error<int>) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.exception.toString())),
      );
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
                            trailing: Text(
                              '${_codes.length} / '
                              '${current.outstanding.round()}',
                            ),
                          ),
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
                          SizedBox(height: spacing.lg),
                          FilledButton(
                            onPressed:
                                _isSaving ||
                                    _codes.length != current.outstanding.round()
                                ? null
                                : () => _submit(captureLater: false),
                            child: Text(l10n.saveButton),
                          ),
                          SizedBox(height: spacing.sm),
                          // "Identify later" is allowed, and visible: the
                          // articles land on the missing-identifier worklist
                          // and the till refuses to sell one until somebody
                          // scans it (§6.1).
                          OutlinedButton(
                            onPressed: _isSaving || _codes.isEmpty
                                ? null
                                : () => _submit(captureLater: true),
                            child: Text(l10n.openingIdentifyLater),
                          ),
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
