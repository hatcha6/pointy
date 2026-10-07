import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/error_messages.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/models/unit_photo.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/printing/print_paper_mismatch_message.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/product_image_viewer.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/tracking/tracking_labels.dart';
import '../../../shared/tracking/unit_details_sheet.dart';
import '../../../shared/tracking/unit_sale_band.dart';
import '../../catalog/views/barcode_label_print_action.dart';
import '../view_models/stock_unit_detail_view_model.dart';
import '../view_models/tracked_stock_view_model.dart';
import 'consignment_incident_sheet.dart';
import 'identify_unit_dialog.dart';
import 'stock_unit_actions.dart';
import 'stock_unit_timeline_section.dart';
import 'unit_attributes_section.dart';
import 'unit_photo_picker.dart';
import 'unit_photos_section.dart';

/// One article of stock, and what became of it.
///
/// The page a warranty claim, an insurance claim or a police question is
/// answered from: what it is, what it looked like (its photos), what condition
/// it was in (its checklist), until when it is covered, and its whole life —
/// movements and the edits that moved nothing (§8.1, §6.9).
class StockUnitDetailScreen extends StatefulWidget {
  const StockUnitDetailScreen({
    super.key,
    required this.viewModel,
    required this.unit,
    required this.capabilities,
    this.detailViewModel,
    this.onOpenRecord,
    this.printingRepository,
  });

  final TrackedStockViewModel viewModel;

  /// Where its own label goes. Null hides the print button.
  final PrintingRepository? printingRepository;
  final StockUnit unit;
  final AuthorizationCapabilities capabilities;

  /// Opens the invoice a sold article went out on, or its buyer, through the
  /// shell's capability-gated deep links (`order`, `customer`). Null shows
  /// them as plain text.
  final Future<bool> Function(BuildContext context, String type, int id)?
  onOpenRecord;

  /// Injected by previews and tests; built from [viewModel] otherwise.
  final StockUnitDetailViewModel? detailViewModel;

  @override
  State<StockUnitDetailScreen> createState() => _StockUnitDetailScreenState();
}

class _StockUnitDetailScreenState extends State<StockUnitDetailScreen> {
  late final StockUnitDetailViewModel _detail =
      widget.detailViewModel ??
      StockUnitDetailViewModel(
        repository: widget.viewModel.repository,
        unit: widget.unit,
        onUnitChanged: widget.viewModel.unitChanged,
      );

  AuthorizationCapabilities get _can => widget.capabilities;

  /// Two columns once there is room for both to be read side by side.
  static const double _twoColumnMinWidth = 1000;

  @override
  void initState() {
    super.initState();
    unawaited(_detail.load());
  }

  @override
  void dispose() {
    if (widget.detailViewModel == null) {
      _detail.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return ListenableBuilder(
      listenable: _detail,
      builder: (context, _) {
        final unit = _detail.unit;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(
              unit.isIdentified ? unit.code : l10n.stockUnitsAwaitingIdentifier,
            ),
            isLoading: _detail.isLoading || _detail.isUploading,
            actions: [
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: _detail.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final primary = _primarySections(context, l10n);
              final secondary = _secondarySections(context, l10n);
              if (constraints.maxWidth < _twoColumnMinWidth) {
                return ListView(
                  padding: spacing.pagePadding,
                  children: _spaced([...primary, ...secondary]),
                );
              }
              return SingleChildScrollView(
                padding: spacing.pagePadding,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _spaced(primary),
                      ),
                    ),
                    SizedBox(width: spacing.lg),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _spaced(secondary),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _spaced(List<Widget> sections) => [
    for (var index = 0; index < sections.length; index++) ...[
      if (index > 0) const SizedBox(height: 16),
      sections[index],
    ],
  ];

  List<Widget> _primarySections(BuildContext context, AppLocalizations l10n) {
    final unit = _detail.unit;
    return [
      _hero(context, l10n),
      // Who bought it and on which invoice — the question an IMEI typed into
      // the products search usually came with, answered first.
      if (unit.status == StockUnitStatus.sold) _saleBand(),
      if (unit.isConsignment) _consignmentPanel(context, l10n),
      _facts(context, l10n),
      UnitAttributesSection(
        values: unit.attributeDisplay,
        onEdit: _can.canEditStockUnitAttributes && unit.assetTypeId != null
            ? _editAttributes
            : null,
      ),
      _photos(context),
    ];
  }

  List<Widget> _secondarySections(BuildContext context, AppLocalizations l10n) {
    return [
      StockUnitActionBar(
        unit: _detail.unit,
        capabilities: _can,
        onIdentify: _identify,
        onReprice: _reprice,
        onWriteOff: _writeOff,
        onReportIncident: _reportIncident,
        onEditWarranty: _editWarranty,
        onPrintLabel: widget.printingRepository == null ? null : _printLabel,
      ),
      if (_detail.incidents.isNotEmpty) _incidentsSection(context, l10n),
      StockUnitTimelineSection(
        history: _detail.history,
        timeline: _detail.timeline,
      ),
    ];
  }

  Widget _hero(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    final unit = _detail.unit;
    final cover = _detail.cover;
    final sold = unit.status == StockUnitStatus.sold && unit.soldPrice != null;
    return PointyDetailHero(
      icon: unit.isConsignment
          ? Icons.handshake_outlined
          : Icons.qr_code_2_outlined,
      leading: cover == null
          ? null
          : _HeroCover(cover: cover, onTap: _openCover),
      // The variant, not just the product: «آيفون 13» is four different
      // phones in a shop that sells four of them.
      title: _name(unit),
      // Gone: what it went for. On the shelf: what it would go for.
      value: formatMoney(
        sold
            ? (unit.soldPrice ?? 0)
            : (unit.listPrice ?? unit.askingPrice ?? unit.soldPrice ?? 0),
      ),
      valueSubtitle: sold
          ? l10n.stockUnitSoldFor
          : unit.listPrice != null
          ? l10n.stockUnitOwnPrice
          : l10n.stockUnitVariantPrice,
      description: unit.isIdentified ? unit.code : null,
      pills: [
        PointyHeroPill(label: stockUnitStatusLabel(l10n, unit.status)),
        if (unit.isConsignment)
          PointyHeroPill(label: l10n.stockUnitConsignmentBadge),
        if (unit.isUnderWarranty && unit.warrantyExpiresOn != null)
          PointyHeroPill(
            icon: Icons.verified_user_outlined,
            label: l10n.stockUnitWarrantyUntil(
              formatDate(unit.warrantyExpiresOn!),
            ),
          ),
        if (unit.batchCode.isNotEmpty)
          PointyHeroPill(label: l10n.posCartLineBatchBadge(unit.batchCode)),
      ],
      gradientColors: unit.isConsignment
          ? [colors.accentAmber, colors.primaryDark]
          : null,
    );
  }

  Widget _saleBand() {
    final openRecord = widget.onOpenRecord;
    return UnitSaleBand(
      unit: _detail.unit,
      onOpenInvoice: openRecord != null && _can.canViewInvoices
          ? (id) => _openRecord(openRecord, 'order', id)
          : null,
      onOpenCustomer: openRecord != null && _can.canManageContacts
          ? (id) => _openRecord(openRecord, 'customer', id)
          : null,
    );
  }

  Future<void> _openRecord(
    Future<bool> Function(BuildContext, String, int) open,
    String type,
    int id,
  ) async {
    final message = AppLocalizations.of(context)!.aiAssistantLinkUnavailable;
    final opened = await open(context, type, id);
    if (!opened && mounted) _snack(message);
  }

  void _openCover() {
    final photos = _detail.photos;
    final cover = _detail.cover;
    if (cover == null) return;
    final urls = photos.isEmpty
        ? [cover.contentUrl]
        : [for (final photo in photos) photo.contentUrl];
    showProductImageViewer(
      context,
      imageUrls: urls,
      initialIndex: photos
          .indexWhere((photo) => photo.id == cover.id)
          .clamp(0, urls.length - 1),
      title: _name(_detail.unit),
    );
  }

  Widget _consignmentPanel(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    final unit = _detail.unit;
    // What is owed comes as its own figures, to whoever may see what the shop
    // owes consignors — never from the unit's cost, which is masked from the
    // very counter staff who pay the owner out. Absent means "not told".
    final owed = unit.awaitsPayout ? unit.netDue : null;
    final advance = unit.consignorAdvance ?? 0;
    final rows = <PointySummaryRow>[
      PointySummaryRow(
        label: l10n.stockUnitConsignor,
        value: unit.consignorName.isEmpty ? '—' : unit.consignorName,
      ),
      if (unit.declaredValue != null)
        PointySummaryRow(
          label: l10n.stockUnitDeclaredValue,
          value: formatMoney(unit.declaredValue!),
        ),
      if (owed != null) ...[
        if (advance > 0) ...[
          PointySummaryRow(
            label: l10n.stockUnitPayoutFromSale,
            value: formatMoney(unit.payoutDue ?? 0),
            dividerAbove: true,
          ),
          PointySummaryRow(
            label: l10n.stockUnitPayoutAdvance,
            value: '- ${formatMoney(advance)}',
            valueColor: colors.danger,
          ),
        ],
        PointySummaryRow(
          label: l10n.stockUnitPayoutOwed,
          value: formatMoney(owed),
          emphasized: true,
          dividerAbove: true,
        ),
      ],
      if (unit.consignorPaidAt != null)
        PointySummaryRow(
          label: l10n.stockUnitPayoutPaidOn,
          value: formatDate(unit.consignorPaidAt!),
        ),
    ];
    return PointyDetailSection(
      title: l10n.stockUnitConsignmentSection,
      icon: Icons.handshake_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySummaryList(rows: rows),
          if (unit.awaitsPayout)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _resendSms,
                icon: const Icon(Icons.sms_outlined),
                label: Text(l10n.consignmentResendSms),
              ),
            ),
        ],
      ),
    );
  }

  Widget _facts(BuildContext context, AppLocalizations l10n) {
    final unit = _detail.unit;
    return PointyDetailSection(
      title: l10n.stockUnitFactsSection,
      icon: Icons.info_outline,
      child: PointySummaryList(
        rows: [
          PointySummaryRow(
            label: l10n.stockUnitWarehouse,
            value: unit.warehouseName.isEmpty ? '—' : unit.warehouseName,
          ),
          if (unit.daysInStock != null && unit.isOnHand)
            PointySummaryRow(
              label: l10n.stockUnitDaysHeld,
              value: '${unit.daysInStock}',
            ),
          PointySummaryRow(
            label: l10n.unitWarrantyRowLabel,
            value: _warrantyText(l10n, unit),
          ),
          // Cost is absent, not null, for a reader without the permission — so
          // the rows simply are not built rather than showing a blank.
          if (unit.showsCost)
            PointySummaryRow(
              label: l10n.stockUnitCost,
              value: formatMoney(unit.incomingRate ?? 0),
            ),
          if (unit.showsCost && (unit.refurbCost ?? 0) > 0)
            PointySummaryRow(
              label: l10n.stockUnitRefurbCost,
              value: formatMoney(unit.refurbCost!),
            ),
          if (unit.showsCost)
            PointySummaryRow(
              label: l10n.stockUnitTotalCost,
              value: formatMoney(unit.totalCost ?? 0),
              emphasized: true,
              dividerAbove: true,
            ),
          if (unit.soldAt != null)
            PointySummaryRow(
              label: l10n.stockUnitSoldOn,
              value: formatDate(unit.soldAt!),
            ),
          if (unit.soldPrice != null)
            PointySummaryRow(
              label: l10n.stockUnitSoldFor,
              value: formatMoney(unit.soldPrice!),
            ),
        ],
      ),
    );
  }

  /// Sold: the date the sale stamped (which is this article's own date when
  /// it has one). On the shelf: what the next sale will stamp.
  static String _warrantyText(AppLocalizations l10n, StockUnit unit) {
    if (unit.status == StockUnitStatus.sold) {
      final expires = unit.warrantyExpiresOn;
      if (expires == null) return l10n.unitWarrantyNone;
      return unit.isUnderWarranty
          ? l10n.stockUnitWarrantyUntil(formatDate(expires))
          : l10n.unitWarrantyExpiredOn(formatDate(expires));
    }
    final override = unit.warrantyOverrideExpiresOn;
    return override == null
        ? l10n.unitWarrantyFromProduct
        : l10n.unitWarrantyOwnDate(formatDate(override));
  }

  Widget _photos(BuildContext context) {
    if (_detail.isLoading && _detail.photos.isEmpty) {
      return const _PhotoStripSkeleton();
    }
    return UnitPhotosSection(
      photos: _detail.photos,
      title: _name(_detail.unit),
      canManage: _can.canManageStockUnitPhotos,
      loadFailed: _detail.photosFailed,
      isUploading: _detail.isUploading,
      uploadDone: _detail.uploadDone,
      uploadTotal: _detail.uploadTotal,
      uploadProgress: _detail.uploadProgress,
      onAddFiles: () => _addPhotos(pickUnitPhotoFiles),
      onCapture: unitCameraSupported
          ? () => _addPhotos(() async {
              final photo = await captureUnitPhoto();
              return photo == null ? const <UnitPhotoUpload>[] : [photo];
            })
          : null,
      onMakeCover: (photo) => _photoAction(() => _detail.makeCover(photo)),
      onDelete: _deletePhoto,
    );
  }

  Widget _incidentsSection(BuildContext context, AppLocalizations l10n) {
    return PointyDetailSection(
      title: l10n.custodyIncidentsTitle,
      icon: Icons.report_gmailerrorred_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final incident in _detail.incidents)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined, size: 18),
              title: Text(
                '${incident.number} · '
                '${consignmentIncidentKindLabel(l10n, incident.kind)}',
              ),
              subtitle: Text(
                [
                  consignmentResponsibilityLabel(l10n, incident.responsibility),
                  consignmentResolutionLabel(l10n, incident.resolution),
                  if (!incident.isAssessed && incident.isOpen)
                    l10n.custodyIncidentUnassessed,
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }

  // -- edits ---------------------------------------------------------------

  Future<void> _editAttributes() async {
    final l10n = AppLocalizations.of(context)!;
    final ready = await _detail.ensureDefinitions();
    if (!mounted) return;
    if (!ready) {
      _snack(l10n.unitAttributesLoadFailed);
      return;
    }
    final unit = _detail.unit;
    await showUnitDetailsSheet(
      context,
      title: l10n.stockUnitAttributesSection,
      definitions: _detail.definitions,
      attributes: unit.attributes,
      onSave: (draft) async {
        final outcome = await _detail.saveAttributes(draft.attributes);
        return outcome.isSaved || outcome.fieldErrors.isNotEmpty
            ? outcome
            : UnitDetailsSaveOutcome.refused(
                message: outcome.message.isEmpty
                    ? l10n.unitAttributesSaveFailed
                    : outcome.message,
              );
      },
    );
  }

  Future<void> _editWarranty() async {
    final l10n = AppLocalizations.of(context)!;
    await showUnitDetailsSheet(
      context,
      title: l10n.unitWarrantyEditTitle,
      editAttributes: false,
      editWarranty: true,
      warrantyOverride: _detail.unit.warrantyOverrideExpiresOn,
      onSave: (draft) async {
        final outcome = await _detail.setWarrantyOverride(
          draft.warrantyOverride,
        );
        return outcome.isSaved || outcome.fieldErrors.isNotEmpty
            ? outcome
            : UnitDetailsSaveOutcome.refused(
                message: outcome.message.isEmpty
                    ? l10n.unitWarrantySaveFailed
                    : outcome.message,
              );
      },
    );
  }

  Future<void> _addPhotos(Future<List<UnitPhotoUpload>> Function() pick) async {
    final l10n = AppLocalizations.of(context)!;
    List<UnitPhotoUpload> picked;
    try {
      picked = await pick();
    } on Exception {
      // No camera on this device or browser, or permission was refused.
      _snack(l10n.productImageCameraUnavailable);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final failed = await _detail.uploadPhotos(picked);
    if (!mounted || failed.isEmpty) return;
    _snack(l10n.unitPhotoUploadFailed(failed.join('، ')));
  }

  Future<void> _deletePhoto(UnitPhoto photo) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PointyDestructiveConfirmationDialog(
        title: l10n.unitPhotoDeleteConfirmTitle,
        message: l10n.unitPhotoDeleteConfirmBody,
        confirmLabel: l10n.unitPhotoDelete,
        icon: Icons.hide_image_outlined,
      ),
    );
    if (confirmed != true || !mounted) return;
    await _photoAction(() => _detail.deletePhoto(photo));
  }

  Future<void> _photoAction(Future<bool> Function() action) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await action();
    if (!ok && mounted) _snack(l10n.unitPhotoActionFailed);
  }

  Future<void> _reportIncident() async {
    final l10n = AppLocalizations.of(context)!;
    final draft = await showConsignmentIncidentSheet(context);
    if (draft == null || !mounted) return;
    final error = await widget.viewModel.reportIncident(_detail.unit.id, draft);
    if (!mounted) return;
    if (error != null) {
      _snack(errorMessageFor(error, l10n));
      return;
    }
    await _detail.load();
  }

  Future<void> _identify() async {
    final named = await showIdentifyUnitDialog(
      context,
      viewModel: widget.viewModel,
      unit: _detail.unit,
    );
    if (named && mounted) await _detail.load();
  }

  Future<void> _reprice() async {
    final l10n = AppLocalizations.of(context)!;
    final price = await showUnitRepriceDialog(
      context,
      current: _detail.unit.listPrice,
    );
    if (price == null || !mounted) return;
    final updated = await widget.viewModel.reprice(_detail.unit.id, price);
    if (!mounted) return;
    if (updated == null) {
      _snack(l10n.stockUnitRepriceFailed);
      return;
    }
    _detail.replaceUnit(updated);
  }

  static String _name(StockUnit unit) =>
      unit.variantName.isNotEmpty ? unit.variantName : unit.productName;

  /// This article's own sticker — its number and its own price — so the till's
  /// scan selects exactly this handset. A serial-in-lot pack carries its
  /// lot's date as well.
  Future<void> _printLabel() async {
    final printing = widget.printingRepository;
    if (printing == null) return;
    final unit = _detail.unit;
    final draft = BarcodeLabelDraft.fromStockUnit(unit);
    final options = await showBarcodeLabelPrintDialog(
      context: context,
      label: draft,
      tracksExpiry: unit.batchExpiryDate != null,
      initialExpiry: unit.batchExpiryDate,
    );
    if (options == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await printing.printBarcodeLabels([
      options.toPrintLine(draft),
    ]);
    if (!mounted) return;
    final mismatch = result.paperMismatch;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            mismatch != null
                ? printPaperMismatchMessage(l10n, mismatch)
                : result.isSuccess
                ? l10n.barcodeLabelPrintSuccess(options.copies)
                : result.unassignedRole != null
                ? l10n.barcodeLabelNoPrinter
                : l10n.barcodeLabelPrintError,
          ),
        ),
      );
  }

  Future<void> _writeOff() async {
    final l10n = AppLocalizations.of(context)!;
    final reason = await showUnitWriteOffDialog(context);
    if (reason == null || !mounted) return;
    final updated = await widget.viewModel.writeOff(_detail.unit.id, reason);
    if (!mounted) return;
    if (updated == null) {
      _snack(l10n.stockUnitWriteOffFailed);
      return;
    }
    _detail.replaceUnit(updated);
  }

  Future<void> _resendSms() async {
    final l10n = AppLocalizations.of(context)!;
    final queued = await widget.viewModel.resendConsignorSms(_detail.unit.id);
    if (!mounted) return;
    _snack(queued ? l10n.consignmentSmsQueued : l10n.consignmentSmsFailed);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The article's face in the hero: its cover photo, framed against the
/// gradient, opening the photos full screen.
class _HeroCover extends StatelessWidget {
  const _HeroCover({required this.cover, required this.onTap});

  final UnitPhoto cover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.unitPhotoOpenTooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PointyRadii.card),
            border: Border.all(
              color: PointyColors.surface.withValues(alpha: 0.7),
              width: 2,
            ),
          ),
          child: ProductImageThumbnail(
            imageUrl: cover.previewUrl,
            fallbackText: '',
            size: 64,
            borderRadius: PointyRadii.card,
          ),
        ),
      ),
    );
  }
}

/// The strip's shape while the photos load, so the page does not jump.
class _PhotoStripSkeleton extends StatelessWidget {
  const _PhotoStripSkeleton();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.unitPhotosSection,
      icon: Icons.photo_library_outlined,
      child: PointySkeleton(
        child: Row(
          children: [
            for (var index = 0; index < 3; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              const PointySkeletonBox(
                width: UnitPhotosSection.tileSize,
                height: UnitPhotosSection.tileSize,
                borderRadius: PointyRadii.card,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
