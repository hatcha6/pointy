import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_batch.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/stock_count_repository.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../companion/companion_scan_listener.dart';
import '../../companion/companion_scope.dart';
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
import 'stock_count_search_panel.dart';
import 'stock_count_scan_shelf.dart';
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
    this.trackedStockRepository,
  });

  final StockCount session;
  final StockCountRepository stockCountRepository;
  final CatalogRepository catalogRepository;
  final AuthorizationCapabilities capabilities;

  /// Only used to list a lot-tracked item's lots. Optional so the previews and
  /// the tests that count anonymous stock need not supply one.
  final TrackedStockRepository? trackedStockRepository;

  @override
  State<StockCountCountingScreen> createState() =>
      _StockCountCountingScreenState();
}

class _StockCountCountingScreenState extends State<StockCountCountingScreen> {
  late final StockCountSessionViewModel _viewModel;

  /// Owned here, not by the field, so the screen can put the caret back on the
  /// search after an item is saved or skipped — the same resting focus the
  /// till's catalog search keeps, and what makes a wedge scan land somewhere
  /// predictable between items.
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'stock_count_search',
  );

  @override
  void initState() {
    super.initState();
    _viewModel = StockCountSessionViewModel(
      widget.stockCountRepository,
      widget.catalogRepository,
      session: widget.session,
      trackedStockRepository: widget.trackedStockRepository,
    );
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  /// Whether to put the caret straight into a field.
  ///
  /// Yes on a till (a keyboard, and room for the list beside it) — that is the
  /// whole point of the loop: search, Enter, type, Enter. No on a phone, where
  /// the soft keyboard would cover the very keypad the thumb was reaching for.
  /// Same rule the POS catalog search uses.
  bool _prefersHardwareKeyboard(BuildContext context) =>
      AppBreakpoints.of(context).index >= AppBreakpoint.tablet.index;

  /// Back to the resting surface without counting the thing in hand.
  ///
  /// The counter picked the wrong item, or picked the right one and does not
  /// want to count it now — both are ordinary, and before this the only way out
  /// was to type a number they had not counted.
  void _backToSearch() {
    _viewModel.clearCurrent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        return;
      }
      if (AppBreakpoints.of(context).index < AppBreakpoint.tablet.index) {
        // Phones: do not pop the soft keyboard unbidden over the list.
        return;
      }
      _searchFocusNode.requestFocus();
    });
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
    await _handleUnknownScan();
  }

  /// A code nothing in the shop has ever answered to.
  ///
  /// It cannot name its own product, so the person holding the thing does.
  /// Dismissing is a legitimate answer too — the finding is already recorded
  /// and the reconciliation screen still lists it.
  Future<void> _handleUnknownScan() async {
    final code = _viewModel.unknownCode;
    if (code == null || !mounted) {
      return;
    }
    final pick = await showDialog<bool>(
      context: context,
      builder: (context) => StockCountUnknownScanPrompt(
        code: code,
        onPick: () => Navigator.of(context).pop(true),
        onDismiss: () => Navigator.of(context).pop(false),
      ),
    );
    if (!mounted) {
      return;
    }
    if (pick != true) {
      _viewModel.dismissUnknownScan();
      return;
    }
    final variant = await showStockCountItemSearchSheet(
      context,
      catalogRepository: widget.catalogRepository,
    );
    if (!mounted) {
      return;
    }
    if (variant == null) {
      _viewModel.dismissUnknownScan();
      return;
    }
    await _viewModel.attachUnknownScan(variant);
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

  /// Enter in the search field. The counter typed a name or a code and did not
  /// wait for the list — so resolve the term itself rather than trusting
  /// whatever happens to be on screen.
  Future<void> _onSearchSubmitted(String term) async {
    final picked = await _viewModel.selectTopSearchMatch(term);
    if (!mounted || picked) {
      return;
    }
    _showSnack(AppLocalizations.of(context)!.stockCountSearchEmpty);
  }

  Future<void> _onScanIdentifier(String code) async {
    await _viewModel.recordIdentifier(code);
    await _handleUnknownScan();
  }

  Future<void> _onSave() async {
    // Enter is the loop's whole point, so it must never be a silent no-op: say
    // what is missing instead of appearing to swallow the key.
    if (_viewModel.currentVariant != null && !_viewModel.isSaving) {
      final l10n = AppLocalizations.of(context)!;
      if (!_viewModel.hasValidInput) {
        _showSnack(l10n.stockCountInvalidQuantity);
        return;
      }
      if (_viewModel.countsByLot && _viewModel.selectedLotId == null) {
        _showSnack(l10n.stockCountLotRequired);
        return;
      }
    }
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

  /// Back out of the item in hand, asking first only when there is something
  /// to lose. Also what the app bar's back arrow means while an item is up:
  /// the first back leaves the item, the second leaves the count.
  Future<void> _requestBackToSearch() async {
    if (_viewModel.input.isNotEmpty) {
      final confirmed = await confirmDiscardUnsavedChanges(context);
      if (confirmed != true || !mounted) {
        return;
      }
    }
    _backToSearch();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final hasItem = _viewModel.currentVariant != null;
        return PopScope(
          // Always intercept: while an item is in hand, back means "put it
          // down", not "abandon the count". Leaving the count outright is the
          // next back — or the finish action.
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) {
              return;
            }
            final navigator = Navigator.of(context);
            if (_viewModel.currentVariant != null) {
              await _requestBackToSearch();
              return;
            }
            navigator.pop(result);
          },
          child: PointyScaffold(
            appBar: PointyAppBar(
              title: Text(l10n.stockCountCountingTitle),
              style: PointyAppBarStyle.highFocus,
              isLoading: _viewModel.isResolving || _viewModel.isSaving,
              actions: [
                if (hasItem)
                  IconButton(
                    tooltip: l10n.stockCountBackToSearch,
                    onPressed: _requestBackToSearch,
                    icon: const Icon(Icons.search),
                  ),
                IconButton(
                  tooltip: l10n.stockCountCameraScan,
                  onPressed: _openCamera,
                  icon: const Icon(Icons.document_scanner_outlined),
                ),
              ],
            ),
            body: CompanionScanListener(
              bridge: CompanionScope.bridgeOf(context),
              onScan: _onScan,
              child: BarcodeScanListener(
                onBarcodeScanned: _onScan,
                child: StockCountCountingBody(
                  session: _viewModel.session,
                  counted: _viewModel.countedCount,
                  total: _viewModel.expectedCount,
                  progress: _viewModel.progress,
                  variant: _viewModel.currentVariant,
                  input: _viewModel.input,
                  countsByScan: _viewModel.countsByScan,
                  countsByLot: _viewModel.countsByLot,
                  lots: _viewModel.lotsForCurrent,
                  selectedLotId: _viewModel.selectedLotId,
                  onLotSelected: _viewModel.selectLot,
                  scannedForCurrent: _viewModel.scannedForCurrent,
                  scans: _viewModel.scans,
                  lastScan: _viewModel.lastScan,
                  isBusy: _viewModel.isResolving || _viewModel.isSaving,
                  onScanIdentifier: _onScanIdentifier,
                  searchTerm: _viewModel.searchTerm,
                  searchResults: _viewModel.searchResults,
                  isSearching: _viewModel.isSearching,
                  searchError: _viewModel.searchError,
                  searchHasMore: _viewModel.searchHasMore,
                  onSearchChanged: _viewModel.search,
                  onSearchSubmitted: _onSearchSubmitted,
                  onLoadMoreSearchResults: _viewModel.loadMoreSearchResults,
                  onRetrySearch: _viewModel.retrySearch,
                  onPickVariant: _viewModel.selectVariant,
                  countedQuantityFor: _viewModel.countedQuantityFor,
                  searchFocusNode: _searchFocusNode,
                  onBackToSearch: _requestBackToSearch,
                  onCamera: _openCamera,
                  onDigit: _viewModel.appendDigit,
                  onDecimal: _viewModel.appendDecimal,
                  onBackspace: _viewModel.backspace,
                  onClear: _viewModel.clearInput,
                  onInputChanged: _viewModel.setInput,
                  onSubmitInput: _onSave,
                  countUnits: _viewModel.countUnitsForCurrent,
                  countUnitCode: _viewModel.countUnitCode,
                  onCountUnitSelected: _viewModel.selectCountUnit,
                  autofocusInput: _prefersHardwareKeyboard(context),
                  searchAutofocus: _prefersHardwareKeyboard(context),
                  footer: _CountingControls(
                    canSubmit: _viewModel.canSubmit,
                    hasItem: hasItem,
                    onSave: _onSave,
                    onBackToSearch: _requestBackToSearch,
                    onFinish: _finish,
                  ),
                ),
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
    required this.onSearchChanged,
    required this.onPickVariant,
    required this.onCamera,
    required this.onDigit,
    required this.onDecimal,
    required this.onBackspace,
    required this.onClear,
    required this.onInputChanged,
    required this.onSubmitInput,
    required this.footer,
    this.onSearchSubmitted,
    this.autofocusInput = false,
    this.searchTerm = '',
    this.searchResults = const [],
    this.isSearching = false,
    this.searchError = false,
    this.searchHasMore = false,
    this.onLoadMoreSearchResults,
    this.onRetrySearch,
    this.countedQuantityFor,
    this.searchFocusNode,
    this.searchAutofocus = true,
    this.onBackToSearch,
    this.countUnits = const [],
    this.countUnitCode = '',
    this.onCountUnitSelected,
    this.countsByScan = false,
    this.scannedForCurrent = 0,
    this.scans = const [],
    this.lastScan,
    this.onScanIdentifier,
    this.isBusy = false,
    this.countsByLot = false,
    this.lots = const [],
    this.selectedLotId,
    this.onLotSelected,
  });

  final StockCount session;
  final int counted;
  final int total;
  final double progress;
  final ProductVariant? variant;
  final String input;
  final VoidCallback onCamera;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimal;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  /// The count typed on a real keyboard, and Enter on it.
  final ValueChanged<String> onInputChanged;
  final VoidCallback onSubmitInput;

  /// Whether the quantity field takes focus the moment an item is picked.
  /// True where there is a keyboard and room for it; false on a phone, where
  /// it would bury the keypad under the soft keyboard.
  final bool autofocusInput;
  final Widget footer;

  // -- the resting surface (§ "we do not want to open a dialog to search") --
  // With nothing in hand the screen IS the item search, not a card with a
  // button that opens one.
  final String searchTerm;
  final List<ProductVariant> searchResults;
  final ValueChanged<String> onSearchChanged;

  /// Enter in the search field: take the best match without lifting a hand
  /// off the keyboard.
  final Future<void> Function(String term)? onSearchSubmitted;
  final ValueChanged<ProductVariant> onPickVariant;
  final bool isSearching;
  final bool searchError;
  final bool searchHasMore;
  final VoidCallback? onLoadMoreSearchResults;
  final VoidCallback? onRetrySearch;
  final double? Function(int variantId)? countedQuantityFor;
  final FocusNode? searchFocusNode;
  final bool searchAutofocus;

  /// Put the item down and go back to the list, having counted nothing.
  final VoidCallback? onBackToSearch;

  /// Packs this item can be counted in, beyond its base unit. Empty for a
  /// product that is only ever counted in ones, which is most of them.
  final List<ProductUnit> countUnits;
  final String countUnitCode;
  final ValueChanged<String>? onCountUnitSelected;

  /// Whether this item is counted by scanning its articles rather than by
  /// typing a number (§6.6). Decided by the product's tracking mode, never by
  /// a shop-wide setting: the same pharmacy counts serialised imports and
  /// anonymous local stock off the same shelf.
  final bool countsByScan;
  final int scannedForCurrent;
  final List<StockCountScanResult> scans;
  final StockCountScanResult? lastScan;
  final ValueChanged<String>? onScanIdentifier;
  final bool isBusy;

  /// Whether this item is counted one lot at a time.
  final bool countsByLot;
  final List<StockBatch> lots;
  final int? selectedLotId;
  final ValueChanged<int?>? onLotSelected;

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
        Expanded(child: _body(context)),
        footer,
      ],
    );
  }

  Widget _body(BuildContext context) {
    final current = variant;
    if (current == null) {
      return StockCountSearchPanel(
        term: searchTerm,
        results: searchResults,
        isLoading: isSearching,
        hasError: searchError,
        hasMore: searchHasMore,
        onSearch: onSearchChanged,
        onSubmit: onSearchSubmitted,
        onPick: onPickVariant,
        onLoadMore: onLoadMoreSearchResults,
        onRetry: onRetrySearch,
        onCamera: onCamera,
        countedQuantityFor: countedQuantityFor,
        autofocus: searchAutofocus,
        searchFocusNode: searchFocusNode,
      );
    }
    if (countsByScan) {
      return StockCountScanShelfPanel(
        variant: current,
        scannedForCurrent: scannedForCurrent,
        scans: scans,
        lastScan: lastScan,
        isBusy: isBusy,
        onScan: onScanIdentifier ?? (_) {},
      );
    }
    return _ItemAndKeypad(
      variant: current,
      input: input,
      onDigit: onDigit,
      onDecimal: onDecimal,
      onBackspace: onBackspace,
      onClear: onClear,
      onInputChanged: onInputChanged,
      onSubmitInput: onSubmitInput,
      autofocusInput: autofocusInput,
      onBackToSearch: onBackToSearch,
      countUnits: countUnits,
      countUnitCode: countUnitCode,
      onCountUnitSelected: onCountUnitSelected,
      countsByLot: countsByLot,
      lots: lots,
      selectedLotId: selectedLotId,
      onLotSelected: onLotSelected,
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
    required this.onInputChanged,
    required this.onSubmitInput,
    this.autofocusInput = false,
    this.onBackToSearch,
    this.countUnits = const [],
    this.countUnitCode = '',
    this.onCountUnitSelected,
    this.countsByLot = false,
    this.lots = const [],
    this.selectedLotId,
    this.onLotSelected,
  });

  final ProductVariant variant;
  final String input;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimal;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final ValueChanged<String> onInputChanged;
  final VoidCallback onSubmitInput;
  final bool autofocusInput;
  final VoidCallback? onBackToSearch;
  final List<ProductUnit> countUnits;
  final String countUnitCode;
  final ValueChanged<String>? onCountUnitSelected;
  final bool countsByLot;
  final List<StockBatch> lots;
  final int? selectedLotId;
  final ValueChanged<int?>? onLotSelected;

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ItemPanel(
                          variant: variant,
                          input: input,
                          onInputChanged: onInputChanged,
                          onSubmitInput: onSubmitInput,
                          autofocusInput: autofocusInput,
                          onBackToSearch: onBackToSearch,
                          countUnits: countUnits,
                          countUnitCode: countUnitCode,
                          onCountUnitSelected: onCountUnitSelected,
                        ),
                        if (countsByLot) ...[
                          SizedBox(height: spacing.lg),
                          _LotPicker(
                            lots: lots,
                            selectedLotId: selectedLotId,
                            onSelected: onLotSelected,
                          ),
                        ],
                      ],
                    ),
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
              _ItemPanel(
                variant: variant,
                input: input,
                onInputChanged: onInputChanged,
                onSubmitInput: onSubmitInput,
                autofocusInput: autofocusInput,
                onBackToSearch: onBackToSearch,
                countUnits: countUnits,
                countUnitCode: countUnitCode,
                onCountUnitSelected: onCountUnitSelected,
              ),
              if (countsByLot) ...[
                SizedBox(height: spacing.lg),
                _LotPicker(
                  lots: lots,
                  selectedLotId: selectedLotId,
                  onSelected: onLotSelected,
                ),
              ],
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

/// Which lot is being counted. §6.6: the variance is against **that lot's**
/// balance in this room, and the lot's stock elsewhere is neither shown nor
/// touched — so a line that does not name one is refused rather than guessed.
class _LotPicker extends StatelessWidget {
  const _LotPicker({
    required this.lots,
    required this.selectedLotId,
    required this.onSelected,
  });

  final List<StockBatch> lots;
  final int? selectedLotId;
  final ValueChanged<int?>? onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DropdownButtonFormField<int>(
      initialValue: selectedLotId,
      decoration: InputDecoration(
        labelText: l10n.stockCountLotPick,
        helperText: selectedLotId == null ? l10n.stockCountLotRequired : null,
        prefixIcon: const Icon(Icons.inventory_2_outlined),
      ),
      items: [
        for (final lot in lots)
          DropdownMenuItem(value: lot.id, child: Text(lot.displayCode)),
      ],
      onChanged: onSelected,
    );
  }
}

class _ItemPanel extends StatelessWidget {
  const _ItemPanel({
    required this.variant,
    required this.input,
    required this.onInputChanged,
    required this.onSubmitInput,
    this.autofocusInput = false,
    this.onBackToSearch,
    this.countUnits = const [],
    this.countUnitCode = '',
    this.onCountUnitSelected,
  });

  final ProductVariant variant;
  final String input;
  final ValueChanged<String> onInputChanged;
  final VoidCallback onSubmitInput;
  final bool autofocusInput;
  final VoidCallback? onBackToSearch;
  final List<ProductUnit> countUnits;
  final String countUnitCode;
  final ValueChanged<String>? onCountUnitSelected;

  /// The pack currently selected, or null when counting in base units.
  ProductUnit? get _activeUnit {
    if (countUnitCode.isEmpty) {
      return null;
    }
    for (final unit in countUnits) {
      if (unit.code == countUnitCode) {
        return unit;
      }
    }
    return null;
  }

  double get _activeFactor => _activeUnit?.factorToBase ?? 1;

  String _activeUnitLabel(AppLocalizations l10n, String baseLabel) =>
      _activeUnit?.label ?? baseLabel;

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
            if (onBackToSearch != null)
              IconButton(
                tooltip: l10n.stockCountBackToSearch,
                onPressed: onBackToSearch,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        SizedBox(height: spacing.lg),
        _CountField(
          input: input,
          unit: _activeUnitLabel(l10n, unit),
          autofocus: autofocusInput,
          onChanged: onInputChanged,
          onSubmitted: onSubmitInput,
        ),
        if (countUnits.isNotEmpty) ...[
          SizedBox(height: spacing.sm),
          _CountUnitStrip(
            baseLabel: unit,
            units: countUnits,
            selectedCode: countUnitCode,
            onSelected: onCountUnitSelected,
          ),
          _ConversionHint(
            input: input,
            baseUnitLabel: unit,
            factor: _activeFactor,
          ),
        ],
      ],
    );
  }
}

/// The count itself — a real text field, not a read-only readout.
///
/// The keypad stays (a phone in a store room has no keyboard), but a till does,
/// and the loop that matters is: search, Enter, type a number, Enter, next.
/// Making this a field is what closes that loop; leaving it a display forced a
/// counter to tap nine keys for "12".
class _CountField extends StatefulWidget {
  const _CountField({
    required this.input,
    required this.unit,
    required this.onChanged,
    required this.onSubmitted,
    this.autofocus = false,
  });

  final String input;
  final String unit;
  final ValueChanged<String> onChanged;

  /// Enter: save this count and move on.
  final VoidCallback onSubmitted;
  final bool autofocus;

  @override
  State<_CountField> createState() => _CountFieldState();
}

class _CountFieldState extends State<_CountField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.input,
  );

  /// True while WE are writing to the controller, so the echo back into the
  /// view model is skipped (it would notify during a build).
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    // Listening to the controller rather than using onChanged on purpose: a
    // barcode wedge burst that lands in this field is undone by
    // BarcodeScanListener writing straight to the controller, which fires no
    // onChanged — the view model has to hear that undo too, or it keeps the
    // scan's digits as a quantity.
    _controller.addListener(_pushToViewModel);
  }

  @override
  void didUpdateWidget(covariant _CountField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.input != _controller.text) {
      _syncing = true;
      _controller.value = TextEditingValue(
        text: widget.input,
        selection: TextSelection.collapsed(offset: widget.input.length),
      );
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_pushToViewModel)
      ..dispose();
    super.dispose();
  }

  void _pushToViewModel() {
    if (_syncing || _controller.text == widget.input) {
      return;
    }
    widget.onChanged(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: PointyColors.primary, width: 1.5),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: spacing.md,
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: TextField(
                    key: const ValueKey('stock_count_quantity_field'),
                    controller: _controller,
                    autofocus: widget.autofocus,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => widget.onSubmitted(),
                    style: PointyTypography.numeric(
                      textTheme.displaySmall ?? const TextStyle(fontSize: 40),
                    ).copyWith(fontWeight: FontWeight.w800, color: colors.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: '0',
                      hintStyle:
                          PointyTypography.numeric(
                            textTheme.displaySmall ??
                                const TextStyle(fontSize: 40),
                          ).copyWith(
                            fontWeight: FontWeight.w800,
                            color: colors.lineStrong,
                          ),
                    ),
                  ),
                ),
                SizedBox(width: spacing.sm),
                Padding(
                  padding: const EdgeInsetsDirectional.only(bottom: 6),
                  child: Text(
                    widget.unit,
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

/// "You are counting in: pieces | cartons of 24".
///
/// Only rendered for a product that is actually packed in something, so a shop
/// that sells everything by the piece never sees it.
class _CountUnitStrip extends StatelessWidget {
  const _CountUnitStrip({
    required this.baseLabel,
    required this.units,
    required this.selectedCode,
    required this.onSelected,
  });

  final String baseLabel;
  final List<ProductUnit> units;
  final String selectedCode;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          l10n.stockCountCountUnit,
          style: textTheme.labelMedium?.copyWith(
            color: colors.mutedInk,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(width: spacing.sm),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _UnitChip(
                  label: baseLabel,
                  selected: selectedCode.isEmpty,
                  onTap: onSelected == null ? null : () => onSelected!(''),
                ),
                for (final unit in units) ...[
                  SizedBox(width: spacing.xs),
                  _UnitChip(
                    label:
                        '${unit.label} · ${formatQuantity(unit.factorToBase)}',
                    selected: selectedCode == unit.code,
                    onTap: onSelected == null
                        ? null
                        : () => onSelected!(unit.code),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UnitChip extends StatelessWidget {
  const _UnitChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap!(),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// "= 72 قطعة" under the field, so the number that will reach the shelf is on
/// screen before anyone presses Enter. Nothing when counting in base units,
/// where the hint would only repeat the field.
class _ConversionHint extends StatelessWidget {
  const _ConversionHint({
    required this.input,
    required this.baseUnitLabel,
    required this.factor,
  });

  final String input;
  final String baseUnitLabel;
  final double factor;

  @override
  Widget build(BuildContext context) {
    final entered = double.tryParse(input.trim());
    if (factor == 1 || entered == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsetsDirectional.only(top: spacing.xs),
      child: Text(
        l10n.stockCountUnitEquals(
          formatQuantity(entered * factor),
          baseUnitLabel,
        ),
        style: PointyTypography.numeric(
          textTheme.bodyMedium ?? const TextStyle(),
        ).copyWith(color: colors.primaryStrong, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _CountingControls extends StatelessWidget {
  const _CountingControls({
    required this.canSubmit,
    required this.hasItem,
    required this.onSave,
    required this.onBackToSearch,
    required this.onFinish,
  });

  final bool canSubmit;

  /// Whether something is in hand. With nothing selected the primary action
  /// would be permanently disabled, so the footer offers the one action that
  /// still makes sense instead.
  final bool hasItem;
  final VoidCallback onSave;
  final VoidCallback onBackToSearch;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyStickyActionFooter(
      primaryAction: hasItem
          ? FilledButton.icon(
              onPressed: canSubmit ? onSave : null,
              icon: const Icon(Icons.check),
              label: Text(l10n.stockCountSaveAndNext),
            )
          : FilledButton.icon(
              onPressed: onFinish,
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(l10n.stockCountFinishButton),
            ),
      secondaryActions: [
        if (hasItem) ...[
          // The way out that does not require inventing a quantity.
          OutlinedButton.icon(
            onPressed: onBackToSearch,
            icon: const Icon(Icons.arrow_back),
            label: Text(l10n.stockCountSkipItem),
          ),
          OutlinedButton.icon(
            onPressed: onFinish,
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(l10n.stockCountFinishButton),
          ),
        ],
      ],
    );
  }
}
