import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_bulk_action.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/product_category_picker.dart';

typedef BulkRepriceChoice = ({ProductBulkRepriceMode mode, double value});
typedef BulkCategorizeChoice = ({
  List<int> categoryIds,
  ProductBulkCategorizeMode mode,
});
typedef BulkFlagsChoice = ({
  bool? isActive,
  bool? tracksExpiry,
  bool? isService,
  bool? isPrepared,
});

Future<BulkRepriceChoice?> showBulkRepriceSheet(BuildContext context) {
  return showDialog<BulkRepriceChoice>(
    context: context,
    builder: (context) => const _BulkRepriceDialog(),
  );
}

Future<BulkCategorizeChoice?> showBulkCategorizeSheet(
  BuildContext context, {
  required CatalogRepository catalogRepository,
}) {
  return showDialog<BulkCategorizeChoice>(
    context: context,
    builder: (context) =>
        _BulkCategorizeDialog(catalogRepository: catalogRepository),
  );
}

Future<BulkFlagsChoice?> showBulkFlagsSheet(BuildContext context) {
  return showDialog<BulkFlagsChoice>(
    context: context,
    builder: (context) => const _BulkFlagsDialog(),
  );
}

class _BulkRepriceDialog extends StatefulWidget {
  const _BulkRepriceDialog();

  @override
  State<_BulkRepriceDialog> createState() => _BulkRepriceDialogState();
}

class _BulkRepriceDialogState extends State<_BulkRepriceDialog> {
  ProductBulkRepriceMode _mode = ProductBulkRepriceMode.increasePercent;
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _modeLabel(AppLocalizations l10n, ProductBulkRepriceMode mode) {
    return switch (mode) {
      ProductBulkRepriceMode.set => l10n.bulkRepriceModeSet,
      ProductBulkRepriceMode.increasePercent => l10n.bulkRepriceModeIncreasePercent,
      ProductBulkRepriceMode.decreasePercent => l10n.bulkRepriceModeDecreasePercent,
      ProductBulkRepriceMode.increaseAmount => l10n.bulkRepriceModeIncreaseAmount,
      ProductBulkRepriceMode.decreaseAmount => l10n.bulkRepriceModeDecreaseAmount,
    };
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;
    final value = double.tryParse(_controller.text.trim());
    if (value == null || value < 0) {
      setState(() => _error = l10n.bulkRepriceValueRequired);
      return;
    }
    if (_mode.isPercent && value > 100 && _mode == ProductBulkRepriceMode.decreasePercent) {
      setState(() => _error = l10n.bulkRepriceValueRequired);
      return;
    }
    Navigator.of(context).pop((mode: _mode, value: value));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.sell_outlined),
      title: Text(l10n.bulkRepriceTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<ProductBulkRepriceMode>(
              initialValue: _mode,
              decoration: InputDecoration(labelText: l10n.bulkRepriceModeLabel),
              items: [
                for (final mode in ProductBulkRepriceMode.values)
                  DropdownMenuItem(value: mode, child: Text(_modeLabel(l10n, mode))),
              ],
              onChanged: (mode) {
                if (mode != null) {
                  setState(() => _mode = mode);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: _mode.isPercent
                    ? l10n.bulkRepricePercentLabel
                    : l10n.bulkRepriceAmountLabel,
                errorText: _error,
                suffixText: _mode.isPercent ? '%' : null,
              ),
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) {
                  setState(() => _error = null);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.applyButton)),
      ],
    );
  }
}

class _BulkCategorizeDialog extends StatefulWidget {
  const _BulkCategorizeDialog({required this.catalogRepository});

  final CatalogRepository catalogRepository;

  @override
  State<_BulkCategorizeDialog> createState() => _BulkCategorizeDialogState();
}

class _BulkCategorizeDialogState extends State<_BulkCategorizeDialog> {
  ProductBulkCategorizeMode _mode = ProductBulkCategorizeMode.add;
  List<AsyncSelectionOption<int>> _selected = const [];

  String _modeLabel(AppLocalizations l10n, ProductBulkCategorizeMode mode) {
    return switch (mode) {
      ProductBulkCategorizeMode.add => l10n.bulkCategorizeModeAdd,
      ProductBulkCategorizeMode.replace => l10n.bulkCategorizeModeReplace,
      ProductBulkCategorizeMode.remove => l10n.bulkCategorizeModeRemove,
    };
  }

  Future<void> _pickCategories() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: _selected,
      loadPage: (search, page) => loadProductCategorySelectionPage(
        catalogRepository: widget.catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selected = picked);
  }

  void _submit() {
    Navigator.of(context).pop((
      categoryIds: _selected.map((option) => option.id).toList(),
      mode: _mode,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canSubmit = _selected.isNotEmpty;
    return AlertDialog(
      icon: const Icon(Icons.category_outlined),
      title: Text(l10n.bulkCategorizeTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<ProductBulkCategorizeMode>(
              initialValue: _mode,
              decoration: InputDecoration(labelText: l10n.bulkCategorizeModeLabel),
              items: [
                for (final mode in ProductBulkCategorizeMode.values)
                  DropdownMenuItem(value: mode, child: Text(_modeLabel(l10n, mode))),
              ],
              onChanged: (mode) {
                if (mode != null) {
                  setState(() => _mode = mode);
                }
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickCategories,
              icon: const Icon(Icons.checklist_outlined),
              label: Text(
                _selected.isEmpty
                    ? l10n.bulkCategorizePickButton
                    : l10n.bulkCategorizePickedCount(_selected.length),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: Text(l10n.applyButton),
        ),
      ],
    );
  }
}

class _BulkFlagsDialog extends StatefulWidget {
  const _BulkFlagsDialog();

  @override
  State<_BulkFlagsDialog> createState() => _BulkFlagsDialogState();
}

class _BulkFlagsDialogState extends State<_BulkFlagsDialog> {
  bool? _isActive;
  bool? _tracksExpiry;
  bool? _isService;
  bool? _isPrepared;

  bool get _hasAny =>
      _isActive != null ||
      _tracksExpiry != null ||
      _isService != null ||
      _isPrepared != null;

  void _submit() {
    Navigator.of(context).pop((
      isActive: _isActive,
      tracksExpiry: _tracksExpiry,
      isService: _isService,
      isPrepared: _isPrepared,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.flag_outlined),
      title: Text(l10n.bulkFlagsTitle),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FlagRow(
              label: l10n.activeProductLabel,
              value: _isActive,
              onChanged: (v) => setState(() => _isActive = v),
            ),
            _FlagRow(
              label: l10n.productTracksExpiryLabel,
              value: _tracksExpiry,
              onChanged: (v) => setState(() => _tracksExpiry = v),
            ),
            _FlagRow(
              label: l10n.productIsServiceTitle,
              value: _isService,
              onChanged: (v) => setState(() => _isService = v),
            ),
            _FlagRow(
              label: l10n.productIsPreparedTitle,
              value: _isPrepared,
              onChanged: (v) => setState(() => _isPrepared = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _hasAny ? _submit : null,
          child: Text(l10n.applyButton),
        ),
      ],
    );
  }
}

class _FlagRow extends StatelessWidget {
  const _FlagRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          SegmentedButton<bool?>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: null, label: Text(l10n.bulkFlagNoChange)),
              ButtonSegment(value: true, label: Text(l10n.bulkFlagOn)),
              ButtonSegment(value: false, label: Text(l10n.bulkFlagOff)),
            ],
            selected: {value},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ],
      ),
    );
  }
}
