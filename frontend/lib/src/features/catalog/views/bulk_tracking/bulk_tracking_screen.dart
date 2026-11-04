import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_price_rule.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/repositories/contact_repository.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../view_models/bulk_tracking_view_model.dart';
import '../bulk_price/bulk_price_condition_editor.dart';
import '../bulk_price/bulk_price_ref_picker.dart';
import 'bulk_tracking_options_section.dart';
import 'bulk_tracking_preview_panel.dart';
import 'bulk_tracking_progress.dart';

/// Opens the bulk tracking page. [selectedProducts] (from the products list's
/// multi-select) narrows it to those products to start with. [onChanged] runs
/// when an apply has changed products, so the list behind shows them.
Future<void> openBulkTracking(
  BuildContext context, {
  required CatalogRepository catalogRepository,
  ContactRepository? contactRepository,
  List<BulkPriceRef> selectedProducts = const [],
  VoidCallback? onChanged,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => BulkTrackingScreen(
        catalogRepository: catalogRepository,
        contactRepository: contactRepository,
        selectedProducts: selectedProducts,
        onChanged: onChanged,
      ),
    ),
  );
}

class BulkTrackingScreen extends StatefulWidget {
  const BulkTrackingScreen({
    super.key,
    required this.catalogRepository,
    this.contactRepository,
    this.selectedProducts = const [],
    this.onChanged,
    this.viewModel,
  });

  final CatalogRepository catalogRepository;
  final ContactRepository? contactRepository;
  final List<BulkPriceRef> selectedProducts;
  final VoidCallback? onChanged;

  /// For previews and tests; otherwise the screen makes its own.
  final BulkTrackingViewModel? viewModel;

  @override
  State<BulkTrackingScreen> createState() => _BulkTrackingScreenState();
}

class _BulkTrackingScreenState extends State<BulkTrackingScreen> {
  late final BulkTrackingViewModel _viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    _viewModel =
        widget.viewModel ??
        BulkTrackingViewModel(
          catalogRepository: widget.catalogRepository,
          selectedProducts: widget.selectedProducts,
          onChanged: widget.onChanged,
        );
  }

  @override
  void dispose() {
    if (_ownsViewModel) _viewModel.dispose();
    super.dispose();
  }

  /// Cost fields stay out: this page never learns whether the till may see
  /// costs, and the server refuses a cost condition from a user who may not.
  List<BulkPriceField> get _conditionFields => [
    for (final field in BulkPriceField.values)
      if (field.isPickable &&
          !field.needsCost &&
          (field != BulkPriceField.supplier ||
              widget.contactRepository != null))
        field,
  ];

  Future<void> _apply() async {
    final preview = _viewModel.preview;
    if (!_viewModel.canApply || preview == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmDialog(
        count: _viewModel.idsToApply.length,
        skipped: _viewModel.skippedEmptyShelf,
      ),
    );
    if (confirmed != true || !mounted) return;
    await _viewModel.apply();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.bulkTrackingTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _viewModel,
          builder: (context, _) => Column(
            children: [
              Expanded(
                child: AdaptiveMaxWidth(
                  width: AppContentWidth.detail,
                  child: _Body(
                    viewModel: _viewModel,
                    conditionFields: _conditionFields,
                    pickRefs: (context, field, current) => pickBulkPriceRefs(
                      context,
                      catalogRepository: widget.catalogRepository,
                      contactRepository: widget.contactRepository,
                      field: field,
                      current: current,
                    ),
                  ),
                ),
              ),
              BulkTrackingFooter(viewModel: _viewModel, onApply: _apply),
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.viewModel,
    required this.conditionFields,
    required this.pickRefs,
  });

  final BulkTrackingViewModel viewModel;
  final List<BulkPriceField> conditionFields;
  final BulkPriceRefPicker pickRefs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final preview = viewModel.preview;
    final fresh = viewModel.isPreviewFresh;
    final locked = viewModel.isApplying;
    final hint = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.mutedInk);

    final String? notice;
    if (viewModel.action.isNoop) {
      notice = l10n.bulkTrackingNothingChosen;
    } else if (!viewModel.isComplete) {
      notice = l10n.bulkTrackingIncomplete;
    } else {
      notice = null;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        IgnorePointer(
          ignoring: locked,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointyDetailSection(
                title: l10n.bulkPriceScopeTitle,
                icon: Icons.filter_alt_outlined,
                trailing: preview == null || !fresh
                    ? null
                    : PointyStatusPill(
                        label: l10n.bulkPriceMatchedCount(
                          preview.summary.matched,
                        ),
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SegmentedButton<bool>(
                        key: const ValueKey('bulk_tracking_scope'),
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: true,
                            icon: const Icon(Icons.select_all),
                            label: Text(l10n.bulkPriceScopeAll),
                          ),
                          ButtonSegment(
                            value: false,
                            icon: const Icon(Icons.filter_list),
                            label: Text(l10n.bulkPriceScopeFiltered),
                          ),
                        ],
                        selected: {viewModel.scopeAll},
                        onSelectionChanged: (selection) =>
                            viewModel.setScopeAll(selection.first),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (viewModel.scopeAll)
                      Text(l10n.bulkTrackingScopeAllHint, style: hint)
                    else
                      BulkPriceGroupEditor(
                        group: viewModel.filter,
                        viewModel: viewModel,
                        pickRefs: pickRefs,
                        availableFields: conditionFields,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              BulkTrackingOptionsSection(viewModel: viewModel),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PointyDetailSection(
          title: l10n.bulkTrackingPreviewTitle,
          icon: Icons.fact_check_outlined,
          trailing: viewModel.isPreviewing
              ? const SizedBox.square(
                  dimension: 16,
                  child: PointySpinner(strokeWidth: 2),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notice != null)
                PointyInlineMessage.warning(message: notice)
              else ...[
                if (viewModel.previewFailed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: PointyInlineMessage.error(
                      message: l10n.bulkTrackingPreviewFailed,
                    ),
                  )
                else if (preview != null && !fresh && !viewModel.isPreviewing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: PointyInlineMessage.warning(
                      message: l10n.bulkTrackingPreviewStale,
                    ),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('bulk_tracking_preview_button'),
                    onPressed: viewModel.isPreviewing || locked
                        ? null
                        : viewModel.refreshPreview,
                    icon: const Icon(Icons.search),
                    label: Text(
                      preview == null
                          ? l10n.bulkTrackingPreviewButton
                          : l10n.bulkTrackingPreviewRefresh,
                    ),
                  ),
                ),
              ],
              if (preview != null && fresh) ...[
                const SizedBox(height: 12),
                BulkTrackingPreviewPanel(
                  key: ValueKey(identityHashCode(preview)),
                  viewModel: viewModel,
                  preview: preview,
                ),
              ],
            ],
          ),
        ),
        if (viewModel.hasResult && !viewModel.isApplying) ...[
          const SizedBox(height: 12),
          BulkTrackingResultCard(viewModel: viewModel),
        ],
      ],
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.count, required this.skipped});

  final int count;
  final int skipped;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        icon: Icon(Icons.event_available_outlined, color: colors.warning),
        title: Text(l10n.bulkTrackingConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.bulkTrackingConfirmBody(count)),
            if (skipped > 0) ...[
              const SizedBox(height: 8),
              Text(l10n.bulkTrackingConfirmSkipped(skipped)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('bulk_tracking_confirm_apply'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.bulkTrackingConfirmAction),
          ),
        ],
      ),
    );
  }
}
