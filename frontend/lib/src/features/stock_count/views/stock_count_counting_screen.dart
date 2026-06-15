import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/stock_count_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/units.dart';
import '../../pos/views/payment/pointy_keypad.dart';
import '../view_models/stock_count_session_view_model.dart';
import 'stock_count_add_replace_sheet.dart';
import 'stock_count_item_search_sheet.dart';
import 'stock_count_reconciliation_screen.dart';
import 'stock_count_variance_prompt.dart';

/// The focused scan -> count -> next loop. Returns `true` up the stack when the
/// session was applied so the sessions list can refresh.
class StockCountCountingScreen extends StatefulWidget {
  const StockCountCountingScreen({
    super.key,
    required this.session,
    required this.stockCountRepository,
    required this.catalogRepository,
    required this.capabilities,
  });

  final StockCount session;
  final StockCountRepository stockCountRepository;
  final CatalogRepository catalogRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<StockCountCountingScreen> createState() =>
      _StockCountCountingScreenState();
}

class _StockCountCountingScreenState extends State<StockCountCountingScreen> {
  late final StockCountSessionViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = StockCountSessionViewModel(
      widget.stockCountRepository,
      widget.catalogRepository,
      session: widget.session,
    );
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _onScan(String barcode) async {
    await _viewModel.onBarcodeScanned(barcode);
    if (!mounted) {
      return;
    }
    if (_viewModel.scanMiss) {
      _showSnack(AppLocalizations.of(context)!.stockCountScanMiss);
      _viewModel.acknowledgeScanMiss();
    }
  }

  Future<void> _openCamera() async {
    final entries = await showCameraBarcodeScannerSheet(
      context,
      mode: CameraBarcodeScannerMode.single,
      lookupVariant: (barcode) async {
        final result = await widget.catalogRepository
            .findProductVariantByBarcode(barcode);
        return result is Ok<ProductVariant?> ? result.value : null;
      },
    );
    if (!mounted || entries == null || entries.isEmpty) {
      return;
    }
    _viewModel.selectVariant(entries.first.variant);
  }

  Future<void> _openSearch() async {
    final variant = await showStockCountItemSearchSheet(
      context,
      catalogRepository: widget.catalogRepository,
    );
    if (!mounted || variant == null) {
      return;
    }
    _viewModel.selectVariant(variant);
  }

  Future<void> _onSave() async {
    await _viewModel.submit();
    await _handleReentry();
    await _handleVariance();
    _reportActionErrorIfAny();
  }

  Future<void> _handleReentry() async {
    final prompt = _viewModel.pendingReentry;
    if (prompt == null) {
      return;
    }
    final mode = await showStockCountReentrySheet(
      context,
      existing: formatQuantity(prompt.existingQuantity),
    );
    if (!mounted) {
      return;
    }
    if (mode == null) {
      _viewModel.cancelReentry();
      return;
    }
    await _viewModel.resolveReentry(mode);
  }

  Future<void> _handleVariance() async {
    final prompt = _viewModel.pendingVariance;
    if (prompt == null) {
      return;
    }
    final recount = await showStockCountVariancePrompt(
      context,
      expected: formatQuantity(prompt.expected),
      counted: formatQuantity(prompt.counted),
    );
    if (!mounted) {
      return;
    }
    if (recount == true) {
      _viewModel.recountVariance();
    } else {
      _viewModel.confirmVariance();
    }
  }

  void _reportActionErrorIfAny() {
    if (!mounted || !_viewModel.actionError) {
      return;
    }
    _showSnack(AppLocalizations.of(context)!.stockCountSaveError);
    _viewModel.acknowledgeActionError();
  }

  Future<void> _finish() async {
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => StockCountReconciliationScreen(
          session: _viewModel.session,
          stockCountRepository: widget.stockCountRepository,
          capabilities: widget.capabilities,
          onRecountVariant: _viewModel.selectVariant,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (applied == true) {
      Navigator.of(context).pop(true);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.stockCountCountingTitle),
            style: PointyAppBarStyle.highFocus,
            isLoading: _viewModel.isResolving || _viewModel.isSaving,
            actions: [
              IconButton(
                tooltip: l10n.stockCountSearchItem,
                onPressed: _openSearch,
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: l10n.stockCountBrowse,
                onPressed: _openCamera,
                icon: const Icon(Icons.document_scanner_outlined),
              ),
            ],
          ),
          body: BarcodeScanListener(
            onBarcodeScanned: _onScan,
            child: Column(
              children: [
                _ProgressHeader(
                  counted: _viewModel.countedCount,
                  total: _viewModel.expectedCount,
                  progress: _viewModel.progress,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: AdaptiveSpacing.of(context).pagePadding,
                    child: _viewModel.currentVariant == null
                        ? _ScanPrompt(onSearch: _openSearch)
                        : _CurrentItem(
                            variant: _viewModel.currentVariant!,
                            input: _viewModel.input,
                          ),
                  ),
                ),
                _CountingControls(
                  viewModel: _viewModel,
                  onSave: _onSave,
                  onFinish: _finish,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({
    required this.counted,
    required this.total,
    required this.progress,
  });

  final int counted;
  final int total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stockCountProgress(counted, total),
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: spacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: colors.surfaceSunken,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanPrompt extends StatelessWidget {
  const _ScanPrompt({required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: PointyEmptyState(
        icon: Icons.qr_code_scanner,
        title: l10n.stockCountScanPrompt,
        message: l10n.stockCountScanHint,
        action: OutlinedButton.icon(
          onPressed: onSearch,
          icon: const Icon(Icons.search),
          label: Text(l10n.stockCountSearchItem),
        ),
      ),
    );
  }
}

class _CurrentItem extends StatelessWidget {
  const _CurrentItem({required this.variant, required this.input});

  final ProductVariant variant;
  final String input;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ProductImageThumbnail(
            imageUrl: variant.primaryImage?.contentUrl,
            fallbackText: variant.displayLabel,
            size: 120,
            borderRadius: 16,
          ),
        ),
        SizedBox(height: spacing.md),
        Text(
          variant.displayLabel,
          textAlign: TextAlign.center,
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: spacing.xs),
        Text(
          l10n.stockCountItemUnit(unitLabel(l10n, variant.unit)),
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
        ),
        if (variant.sku.isNotEmpty)
          Text(
            variant.sku,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        SizedBox(height: spacing.lg),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceSunken,
            borderRadius: BorderRadius.circular(PointyRadii.input),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: spacing.md,
              horizontal: spacing.lg,
            ),
            child: Text(
              input.isEmpty ? '0' : input,
              textAlign: TextAlign.center,
              style: PointyTypography.numeric(
                textTheme.displaySmall ??
                    const TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _CountingControls extends StatelessWidget {
  const _CountingControls({
    required this.viewModel,
    required this.onSave,
    required this.onFinish,
  });

  final StockCountSessionViewModel viewModel;
  final VoidCallback onSave;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final hasItem = viewModel.currentVariant != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasItem)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.md,
              0,
              spacing.md,
              spacing.sm,
            ),
            // Bound the keypad width: its 3-column grid derives button height
            // from the cell width, so on a wide POS screen an unbounded keypad
            // grows tall enough to overflow the column. A phone-sized cap keeps
            // the buttons (and the keypad's height) sensible everywhere.
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: PointyKeypad(
                  label: l10n.stockCountCountLabel,
                  backspaceTooltip: l10n.stockCountRecount,
                  clearTooltip: l10n.stockCountCountLabel,
                  onDigit: viewModel.appendDigit,
                  onDecimal: viewModel.appendDecimal,
                  onBackspace: viewModel.backspace,
                  onClear: viewModel.clearInput,
                ),
              ),
            ),
          ),
        PointyStickyActionFooter(
          primaryAction: FilledButton(
            onPressed: viewModel.canSubmit ? onSave : null,
            child: Text(l10n.stockCountSaveAndNext),
          ),
          secondaryActions: [
            OutlinedButton(
              onPressed: onFinish,
              child: Text(l10n.stockCountFinishButton),
            ),
          ],
        ),
      ],
    );
  }
}
