import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/barcode/camera_text_barcode_scanner_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'variant_identity_watcher.dart';

/// A variant's further barcodes, held by the form that edits it.
///
/// Like a [TextEditingController] for a list: the form owns it, reads
/// [codesForSave] when it saves, and hands it a rejected save's conflicts.
class ExtraBarcodesController extends ChangeNotifier {
  ExtraBarcodesController([List<String> initial = const []])
    : _codes = List.of(initial),
      _initial = List.of(initial);

  /// The code being typed or scanned, before it becomes a chip.
  final input = TextEditingController();

  List<String> _codes;
  List<String> _initial;
  Map<String, CatalogIdentityConflict> _conflicts = const {};
  var _generation = 0;

  List<String> get codes => List.unmodifiable(_codes);

  /// Bumped by [reset], so the field folds back up for the next product.
  int get generation => _generation;

  /// Whether the list differs from what the form opened with.
  bool get isDirty =>
      input.text.trim().isNotEmpty || !_sameCodes(_codes, _initial);

  /// What the server said about each code of a rejected save, by value.
  CatalogIdentityConflict? conflictFor(String code) => _conflicts[code];

  bool get hasConflict => _codes.any(_conflicts.containsKey);

  /// The list to save. A code still sitting in the input counts — pressing
  /// save is as clear an "add it" as pressing the add button.
  List<String> codesForSave({required String primary}) {
    final pending = input.text.trim();
    final primaryCode = primary.trim();
    return [
      for (final code in _codes)
        if (code != primaryCode) code,
      if (pending.isNotEmpty &&
          pending != primaryCode &&
          !_codes.contains(pending))
        pending,
    ];
  }

  void add(String code) {
    if (code.isEmpty || _codes.contains(code)) {
      return;
    }
    _codes = [..._codes, code];
    notifyListeners();
  }

  void remove(String code) {
    _codes = [
      for (final existing in _codes)
        if (existing != code) existing,
    ];
    notifyListeners();
  }

  /// Starts over with [codes] (none for a fresh product).
  void reset([List<String> codes = const []]) {
    _codes = List.of(codes);
    _initial = List.of(codes);
    _conflicts = const {};
    input.clear();
    _generation += 1;
    notifyListeners();
  }

  /// Keeps the extra-barcode conflicts of a rejected save.
  void applyConflicts(Iterable<CatalogIdentityConflict> conflicts) {
    _conflicts = {
      for (final conflict in conflicts)
        if (conflict.field == CatalogIdentityField.extraBarcodes)
          conflict.value: conflict,
    };
    notifyListeners();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}

bool _sameCodes(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// The extra barcodes under a variant's barcode field.
///
/// Folded to one «إضافة باركود آخر» action until there is something to show —
/// most products have one code, and the form should not grow for the few that
/// have more. Each code is checked against the catalogue before it becomes a
/// chip, so a code another product owns is caught while the owner is still
/// holding the pack, not after save.
class VariantExtraBarcodesField extends StatefulWidget {
  const VariantExtraBarcodesField({
    super.key,
    required this.controller,
    required this.primaryBarcode,
    required this.catalogRepository,
    this.excludeVariantId,
    this.enabled = true,
  });

  final ExtraBarcodesController controller;

  /// The variant's main barcode field — an extra must not repeat it, and the
  /// action only appears once there is a first code to add "another" to.
  final TextEditingController primaryBarcode;
  final CatalogRepository catalogRepository;

  /// The variant being edited: its own codes are not a clash.
  final int? excludeVariantId;
  final bool enabled;

  @override
  State<VariantExtraBarcodesField> createState() =>
      _VariantExtraBarcodesFieldState();
}

class _VariantExtraBarcodesFieldState extends State<VariantExtraBarcodesField> {
  final _focusNode = FocusNode(debugLabel: 'variant_extra_barcode_input');
  var _open = false;
  var _checking = false;
  var _generation = 0;
  String? _inputError;
  String _lastInput = '';

  ExtraBarcodesController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _generation = _controller.generation;
    _controller.addListener(_onControllerChanged);
    _controller.input.addListener(_onInputChanged);
  }

  @override
  void didUpdateWidget(covariant VariantExtraBarcodesField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.input.removeListener(_onInputChanged);
      widget.controller.addListener(_onControllerChanged);
      widget.controller.input.addListener(_onInputChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.input.removeListener(_onInputChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {
      if (_controller.generation != _generation) {
        _generation = _controller.generation;
        _open = false;
        _inputError = null;
      }
    });
  }

  void _onInputChanged() {
    // The controller also reports a cursor that merely moved.
    final text = _controller.input.text;
    if (text == _lastInput) {
      return;
    }
    _lastInput = text;
    if (_inputError != null && mounted) {
      setState(() => _inputError = null);
    }
  }

  void _openField() {
    setState(() => _open = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  Future<void> _submit([String? raw]) async {
    final l10n = AppLocalizations.of(context)!;
    final code = (raw ?? _controller.input.text).trim();
    if (code.isEmpty || _checking) {
      return;
    }
    if (code == widget.primaryBarcode.text.trim()) {
      setState(() => _inputError = l10n.variantExtraBarcodeIsPrimary);
      return;
    }
    if (_controller.codes.contains(code)) {
      setState(() => _inputError = l10n.variantExtraBarcodeDuplicate);
      return;
    }
    setState(() {
      _checking = true;
      _inputError = null;
    });
    final result = await widget.catalogRepository.checkVariantIdentity(
      barcode: code,
      excludeVariantId: widget.excludeVariantId,
    );
    if (!mounted) {
      return;
    }
    // A failed lookup never blocks: the server checks the save again.
    final conflict = switch (result) {
      Ok<CatalogIdentityCheck>(:final value) => value.barcode,
      Error<CatalogIdentityCheck>() => null,
    };
    setState(() {
      _checking = false;
      if (conflict != null) {
        _inputError = identityConflictMessage(l10n, conflict);
        if (raw != null) {
          _controller.input.text = code;
        }
        return;
      }
      _controller.add(code);
      if (_controller.input.text.trim() == code) {
        _controller.input.clear();
      }
    });
    // Ready for the next scan.
    _focusNode.requestFocus();
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context)!;
    final code = await showCameraTextBarcodeScannerSheet(
      context,
      title: l10n.variantExtraBarcodeScanTitle,
    );
    final trimmed = code?.trim() ?? '';
    if (trimmed.isNotEmpty && mounted) {
      await _submit(trimmed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final codes = _controller.codes;
    if (!_open && codes.isEmpty) {
      return ListenableBuilder(
        listenable: widget.primaryBarcode,
        builder: (context, _) {
          if (widget.primaryBarcode.text.trim().isEmpty) {
            return const SizedBox.shrink();
          }
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('variant_extra_barcodes_add_button'),
              onPressed: widget.enabled ? _openField : null,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.variantExtraBarcodesAddButton),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          );
        },
      );
    }
    return _buildOpen(context, l10n, codes);
  }

  Widget _buildOpen(
    BuildContext context,
    AppLocalizations l10n,
    List<String> codes,
  ) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final enabled = widget.enabled;
    final conflictMessages = [
      for (final code in codes)
        if (_controller.conflictFor(code) case final conflict?)
          identityConflictMessage(l10n, conflict),
    ];

    return FormField<void>(
      // Blocks Form.validate() while a code the server refused is still here.
      validator: (_) => _controller.hasConflict ? conflictMessages.first : null,
      builder: (field) => Column(
        key: const ValueKey('variant_extra_barcodes_field'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: spacing.xs),
          Text(
            l10n.variantExtraBarcodesLabel,
            style: theme.textTheme.labelLarge,
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.variantExtraBarcodesHelper,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          if (codes.isNotEmpty) ...[
            SizedBox(height: spacing.xs),
            Wrap(
              spacing: spacing.xs,
              runSpacing: spacing.xs,
              children: [
                for (final code in codes)
                  _ExtraBarcodeChip(
                    code: code,
                    hasConflict: _controller.conflictFor(code) != null,
                    enabled: enabled,
                    onDeleted: () => _controller.remove(code),
                  ),
              ],
            ),
          ],
          SizedBox(height: spacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // Scanned into on purpose: a scan here is an extra code, not
                // the product's main barcode the form sends stray scans to.
                child: ScanWedgeTarget(
                  child: TextField(
                    key: const ValueKey('variant_extra_barcode_input'),
                    controller: _controller.input,
                    focusNode: _focusNode,
                    enabled: enabled,
                    textInputAction: TextInputAction.done,
                    onSubmitted: enabled ? (_) => _submit() : null,
                    decoration: InputDecoration(
                      labelText: l10n.variantExtraBarcodeInputLabel,
                      isDense: true,
                      prefixIcon: const Icon(Icons.document_scanner_outlined),
                      suffixIcon: _checking
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(
                                dimension: 16,
                                child: PointySpinner(strokeWidth: 2),
                              ),
                            )
                          : null,
                      errorText: _inputError,
                      errorMaxLines: 2,
                    ),
                  ),
                ),
              ),
              SizedBox(width: spacing.xs),
              IconButton(
                tooltip: l10n.variantExtraBarcodeScanTooltip,
                onPressed: enabled ? _scan : null,
                icon: const Icon(Icons.photo_camera_outlined),
              ),
              IconButton(
                key: const ValueKey('variant_extra_barcode_add'),
                tooltip: l10n.variantExtraBarcodeAddTooltip,
                onPressed: enabled && !_checking ? () => _submit() : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          for (final message in conflictMessages)
            Padding(
              padding: EdgeInsets.only(top: spacing.xs),
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.danger,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExtraBarcodeChip extends StatelessWidget {
  const _ExtraBarcodeChip({
    required this.code,
    required this.hasConflict,
    required this.enabled,
    required this.onDeleted,
  });

  final String code;
  final bool hasConflict;
  final bool enabled;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return InputChip(
      avatar: Icon(
        hasConflict ? Icons.error_outline : Icons.qr_code_2,
        size: 16,
        color: hasConflict ? colors.danger : null,
      ),
      // A code reads left to right inside the Arabic form.
      label: Text(
        code,
        textDirection: TextDirection.ltr,
        style: hasConflict ? TextStyle(color: colors.danger) : null,
      ),
      isEnabled: enabled,
      onDeleted: enabled ? onDeleted : null,
      deleteButtonTooltipMessage: l10n.variantExtraBarcodeRemoveTooltip,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
