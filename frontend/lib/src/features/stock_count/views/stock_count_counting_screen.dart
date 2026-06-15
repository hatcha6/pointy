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
import 'stock_count_ui.dart';
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
                tooltip: l10n.stockCountCameraScan,
                onPressed: _openCamera,
                icon: const Icon(Icons.document_scanner_outlined),
              ),
            ],
          ),
          body: BarcodeScanListener(
            onBarcodeScanned: _onScan,
            child: StockCountCountingBody(
              session: _viewModel.session,
              counted: _viewModel.countedCount,
              total: _viewModel.expectedCount,
              progress: _viewModel.progress,
              variant: _viewModel.currentVariant,
              input: _viewModel.input,
              onSearch: _openSearch,
              onCamera: _openCamera,
              onDigit: _viewModel.appendDigit,
              onDecimal: _viewModel.appendDecimal,
              onBackspace: _viewModel.backspace,
              onClear: _viewModel.clearInput,
              footer: _CountingControls(
                canSubmit: _viewModel.canSubmit,
                onSave: _onSave,
                onFinish: _finish,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Presentational body for the counting loop: a focused header, the scan prompt
/// or the current-item count panel, the keypad, and the sticky footer. Pure
/// (no view model) so it renders identically in previews and tests.
class StockCountCountingBody extends StatelessWidget {
  const StockCountCountingBody({
    super.key,
    required this.session,
    required this.counted,
    required this.total,
    required this.progress,
    required this.variant,
    required this.input,
    required this.onSearch,
    required this.onCamera,
    required this.onDigit,
    required this.onDecimal,
    required this.onBackspace,
    required this.onClear,
    required this.footer,
  });

  final StockCount session;
  final int counted;
  final int total;
  final double progress;
  final ProductVariant? variant;
  final String input;
  final VoidCallback onSearch;
  final VoidCallback onCamera;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimal;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CountingHeader(
          session: session,
          counted: counted,
          total: total,
          progress: progress,
        ),
        Expanded(
          child: variant == null
              ? _ScanPanel(onSearch: onSearch, onCamera: onCamera)
              : _ItemAndKeypad(
                  variant: variant!,
                  input: input,
                  onDigit: onDigit,
                  onDecimal: onDecimal,
                  onBackspace: onBackspace,
                  onClear: onClear,
                ),
        ),
        footer,
      ],
    );
  }
}

/// The dark focus band beneath the app bar: count context + progress.
class _CountingHeader extends StatelessWidget {
  const _CountingHeader({
    required this.session,
    required this.counted,
    required this.total,
    required this.progress,
  });

  final StockCount session;
  final int counted;
  final int total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(color: colors.darkTopBar),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.lg,
          0,
          spacing.lg,
          spacing.md,
        ),
        child: AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      session.countNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          PointyTypography.numeric(
                            textTheme.titleSmall ?? const TextStyle(),
                          ).copyWith(
                            color: colors.surface.withValues(alpha: 0.82),
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  StockCountScopeChip(session: session, onDark: true),
                ],
              ),
              SizedBox(height: spacing.md),
              StockCountProgressBar(
                counted: counted,
                total: total,
                progress: progress,
                onDark: true,
                compact: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Welcoming empty state: a scan target plus the two manual fallbacks.
class _ScanPanel extends StatelessWidget {
  const _ScanPanel({required this.onSearch, required this.onCamera});

  final VoidCallback onSearch;
  final VoidCallback onCamera;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: spacing.pagePadding,
        child: AdaptiveMaxWidth(
          width: AppContentWidth.compact,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    color: colors.primaryStrong.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: colors.primaryStrong.withValues(alpha: 0.20),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    Icons.qr_code_scanner_rounded,
                    size: 60,
                    color: colors.primaryStrong,
                  ),
                ),
              ),
              SizedBox(height: spacing.lg),
              Text(
                l10n.stockCountScanPrompt,
                textAlign: TextAlign.center,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: spacing.sm),
              Text(
                l10n.stockCountScanHint,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
              SizedBox(height: spacing.xl),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: onSearch,
                  icon: const Icon(Icons.search),
                  label: Text(l10n.stockCountSearchItem),
                ),
              ),
              SizedBox(height: spacing.sm),
              SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: onCamera,
                  icon: const Icon(Icons.document_scanner_outlined),
                  label: Text(l10n.stockCountCameraScan),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The current-item count panel + keypad. Stacks on phones, splits into two
/// panes (item | keypad) once there is room.
class _ItemAndKeypad extends StatelessWidget {
  const _ItemAndKeypad({
    required this.variant,
    required this.input,
    required this.onDigit,
    required this.onDecimal,
    required this.onBackspace,
    required this.onClear,
  });

  final ProductVariant variant;
  final String input;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimal;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    final keypad = PointyKeypad(
      label: l10n.stockCountCountLabel,
      backspaceTooltip: l10n.stockCountRecount,
      clearTooltip: l10n.stockCountCountLabel,
      onDigit: onDigit,
      onDecimal: onDecimal,
      onBackspace: onBackspace,
      onClear: onClear,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppBreakpoints.tabletMin;

        if (isWide) {
          return Padding(
            padding: spacing.pagePadding,
            child: AdaptiveMaxWidth(
              width: AppContentWidth.detail,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _ItemPanel(variant: variant, input: input),
                  ),
                  SizedBox(width: spacing.xl),
                  SizedBox(width: 360, child: keypad),
                ],
              ),
            ),
          );
        }

        return SingleChildScrollView(
          padding: spacing.pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ItemPanel(variant: variant, input: input),
              SizedBox(height: spacing.lg),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: keypad,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ItemPanel extends StatelessWidget {
  const _ItemPanel({required this.variant, required this.input});

  final ProductVariant variant;
  final String input;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final unit = unitLabel(l10n, variant.unit);
    final subtitle = variant.sku.isEmpty
        ? l10n.stockCountItemUnit(unit)
        : '${l10n.stockCountItemUnit(unit)} · ${variant.sku}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ProductImageThumbnail(
              imageUrl: variant.primaryImage?.contentUrl,
              fallbackText: variant.displayLabel,
              size: 64,
              borderRadius: 14,
            ),
            SizedBox(width: spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    variant.displayLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: spacing.lg),
        _CountDisplay(input: input, unit: unit),
      ],
    );
  }
}

/// The large numeric readout of the entered count, framed like a focused field.
class _CountDisplay extends StatelessWidget {
  const _CountDisplay({required this.input, required this.unit});

  final String input;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final hasInput = input.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: PointyColors.primary, width: 1.5),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: spacing.lg,
          horizontal: spacing.lg,
        ),
        child: Column(
          children: [
            Text(
              l10n.stockCountCountLabel,
              style: textTheme.labelMedium?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: spacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  hasInput ? input : '0',
                  style:
                      PointyTypography.numeric(
                        textTheme.displaySmall ?? const TextStyle(fontSize: 40),
                      ).copyWith(
                        fontWeight: FontWeight.w800,
                        color: hasInput ? colors.ink : colors.lineStrong,
                      ),
                ),
                SizedBox(width: spacing.sm),
                Padding(
                  padding: const EdgeInsetsDirectional.only(bottom: 6),
                  child: Text(
                    unit,
                    style: textTheme.titleMedium?.copyWith(
                      color: colors.mutedInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CountingControls extends StatelessWidget {
  const _CountingControls({
    required this.canSubmit,
    required this.onSave,
    required this.onFinish,
  });

  final bool canSubmit;
  final VoidCallback onSave;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyStickyActionFooter(
      primaryAction: FilledButton.icon(
        onPressed: canSubmit ? onSave : null,
        icon: const Icon(Icons.check),
        label: Text(l10n.stockCountSaveAndNext),
      ),
      secondaryActions: [
        OutlinedButton.icon(
          onPressed: onFinish,
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(l10n.stockCountFinishButton),
        ),
      ],
    );
  }
}
