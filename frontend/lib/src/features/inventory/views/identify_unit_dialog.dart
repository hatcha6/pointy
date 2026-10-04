import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/stock_unit.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../view_models/tracked_stock_view_model.dart';

/// Give a placeholder article its number — scanned off the box or typed.
///
/// The field is a [ScanWedgeTarget]: an IMEI arriving at scanner speed is what
/// this dialog is for, and the burst guard would otherwise roll it back as a
/// mistyped quantity. The dialog stays open on a refusal — a code that already
/// names a live article is the common one — and says why in the server's words,
/// because the receiver is still holding the box.
///
/// True when the article was named.
Future<bool> showIdentifyUnitDialog(
  BuildContext context, {
  required TrackedStockViewModel viewModel,
  required StockUnit unit,
}) async {
  final named = await showDialog<bool>(
    context: context,
    builder: (context) => _IdentifyUnitDialog(viewModel: viewModel, unit: unit),
  );
  return named ?? false;
}

class _IdentifyUnitDialog extends StatefulWidget {
  const _IdentifyUnitDialog({required this.viewModel, required this.unit});

  final TrackedStockViewModel viewModel;
  final StockUnit unit;

  @override
  State<_IdentifyUnitDialog> createState() => _IdentifyUnitDialogState();
}

class _IdentifyUnitDialogState extends State<_IdentifyUnitDialog> {
  final _controller = TextEditingController();
  var _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _isSaving) {
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final failure = await widget.viewModel.identifyUnit(widget.unit.id, code);
    if (!mounted) {
      return;
    }
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSaving = false;
      _error = errorMessageFor(failure, AppLocalizations.of(context)!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final unit = widget.unit;
    final product = unit.productName.isNotEmpty
        ? unit.productName
        : unit.variantName;
    return AlertDialog(
      icon: const Icon(Icons.qr_code_scanner_outlined),
      title: Text(l10n.stockUnitIdentifyTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (product.isNotEmpty) ...[
            Text(product, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
          ],
          ScanWedgeTarget(
            child: TextField(
              key: const ValueKey('identify_unit_code_field'),
              controller: _controller,
              autofocus: true,
              enabled: !_isSaving,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: l10n.stockUnitIdentifyCodeLabel,
                hintText: l10n.unitCaptureHint,
                prefixIcon: const Icon(Icons.tag_outlined),
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('identify_unit_save'),
          onPressed: _isSaving ? null : _save,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
