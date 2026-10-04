import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/consignment.dart' show ConsignmentLiability;
import '../../../data/models/identified_stock_settings.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/shop_settings_view_model.dart';

/// Serials, lots and consignment, switched on and tuned in one place.
///
/// Both master switches are off for every shop that never asks, which is the
/// feature's contract: the product form, the drawer and the till show nothing
/// of it until a switch here is on. What a switch turns on is the *surfaces*;
/// each product still says for itself whether it is tracked.
///
/// One draft, saved with one button: the clauses and day counts are typed, and
/// a page where half the controls save on touch and half on a button is a page
/// where somebody leaves thinking a clause was saved.
class IdentifiedStockSettingsPage extends StatefulWidget {
  const IdentifiedStockSettingsPage({super.key, required this.viewModel});

  final ShopSettingsViewModel viewModel;

  @override
  State<IdentifiedStockSettingsPage> createState() =>
      _IdentifiedStockSettingsPageState();
}

class _IdentifiedStockSettingsPageState
    extends State<IdentifiedStockSettingsPage> {
  IdentifiedStockSettings? _stored;
  IdentifiedStockSettings? _draft;
  final _reminderDaysController = TextEditingController();
  final _clauseControllers = {
    for (final policy in _policies) policy: TextEditingController(),
  };

  static const _policies = [
    ConsignmentLiability.ownerRisk,
    ConsignmentLiability.shopLiableExceptForceMajeure,
    ConsignmentLiability.shopLiable,
  ];

  @override
  void initState() {
    super.initState();
    _adopt(widget.viewModel.settings?.identifiedStock);
    widget.viewModel.addListener(_onViewModelChanged);
    if (widget.viewModel.settings == null) {
      unawaited(widget.viewModel.loadSettings());
    }
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onViewModelChanged);
    _reminderDaysController.dispose();
    for (final controller in _clauseControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onViewModelChanged() {
    final loaded = widget.viewModel.settings?.identifiedStock;
    // A reload under an untouched draft takes the server's word; a draft with
    // edits in it is the owner's and is never overwritten by a refresh.
    if (loaded != null && (_draft == null || !_isDirty)) {
      _adopt(loaded);
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _adopt(IdentifiedStockSettings? settings) {
    if (settings == null) {
      return;
    }
    _stored = settings;
    _draft = settings;
    _reminderDaysController.text =
        '${settings.consignmentUnclaimedPayoutReminderDays}';
    for (final policy in _policies) {
      _clauseControllers[policy]!.text = settings.clauseFor(policy);
    }
  }

  /// The draft with whatever is typed into the text fields folded in.
  IdentifiedStockSettings? get _current {
    final draft = _draft;
    if (draft == null) {
      return null;
    }
    return draft.copyWith(
      consignmentUnclaimedPayoutReminderDays:
          int.tryParse(_reminderDaysController.text.trim()) ??
          draft.consignmentUnclaimedPayoutReminderDays,
      consignmentClauseOwnerRisk:
          _clauseControllers[ConsignmentLiability.ownerRisk]!.text,
      consignmentClauseShopLiableExceptForceMajeure:
          _clauseControllers[ConsignmentLiability.shopLiableExceptForceMajeure]!
              .text,
      consignmentClauseShopLiable:
          _clauseControllers[ConsignmentLiability.shopLiable]!.text,
    );
  }

  bool get _isDirty => _current != _stored;

  void _edit(IdentifiedStockSettings Function(IdentifiedStockSettings) change) {
    final draft = _draft;
    if (draft == null) {
      return;
    }
    setState(() => _draft = change(draft));
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final current = _current;
    final stored = _stored;
    if (current == null || stored == null) {
      return;
    }
    // Switching a trade off hides its screens; it does not untrack a single
    // product. Said before it happens, because the products that are still
    // serial keep asking for identifiers at the till and at receiving.
    final turnsOff =
        (stored.enableSerializedInventory &&
            !current.enableSerializedInventory) ||
        (stored.enableBatchTracking && !current.enableBatchTracking);
    if (turnsOff) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => PointyConfirmationDialog(
          title: l10n.identifiedStockTurnOffTitle,
          message: l10n.identifiedStockTurnOffBody,
          confirmLabel: l10n.identifiedStockTurnOffConfirm,
          icon: Icons.visibility_off_outlined,
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    final saved = await widget.viewModel.updateIdentifiedStockSettings(current);
    if (!mounted) {
      return;
    }
    if (saved) {
      _adopt(widget.viewModel.settings?.identifiedStock);
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            saved ? l10n.identifiedStockSaved : l10n.shopSettingsSaveError,
          ),
        ),
      );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final draft = _draft;
    final isSaving = widget.viewModel.isSaving;

    return PointyUnsavedChangesGuard(
      isDirty: () => _isDirty,
      child: PointyScaffold(
        appBar: PointyAppBar(
          title: Text(l10n.identifiedStockSettingsTitle),
          isLoading: widget.viewModel.isLoading || isSaving,
        ),
        body: draft == null
            ? (widget.viewModel.hasLoadError
                  ? PointyErrorState(
                      title: l10n.shopSettingsLoadError,
                      icon: Icons.cloud_off_outlined,
                    )
                  : const PointyLoadingArea())
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: spacing.pagePadding,
                      children: [
                        AdaptiveMaxWidth(
                          width: AppContentWidth.form,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _sections(
                              context,
                              l10n,
                              draft,
                              enabled: !isSaving,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PointyStickyActionFooter(
                    primaryAction: FilledButton.icon(
                      key: const ValueKey('identified_stock_save'),
                      onPressed: isSaving || !_isDirty ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        isSaving ? l10n.savingButton : l10n.saveSettingsButton,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _sections(
    BuildContext context,
    AppLocalizations l10n,
    IdentifiedStockSettings draft, {
    required bool enabled,
  }) {
    final spacing = AdaptiveSpacing.of(context);
    return [
      PointySectionHeader(
        title: l10n.identifiedStockModesTitle,
        subtitle: l10n.identifiedStockModesHint,
        leading: const Icon(Icons.qr_code_scanner_outlined),
      ),
      SizedBox(height: spacing.sm),
      PointySettingsSection(
        children: [
          SwitchListTile(
            key: const ValueKey('identified_stock_serial_switch'),
            secondary: const Icon(Icons.smartphone_outlined),
            title: Text(l10n.identifiedStockSerialTitle),
            subtitle: Text(l10n.identifiedStockSerialDescription),
            value: draft.enableSerializedInventory,
            onChanged: enabled
                ? (value) => _edit(
                    (settings) =>
                        settings.copyWith(enableSerializedInventory: value),
                  )
                : null,
          ),
          SwitchListTile(
            key: const ValueKey('identified_stock_batch_switch'),
            secondary: const Icon(Icons.event_available_outlined),
            title: Text(l10n.identifiedStockBatchTitle),
            subtitle: Text(l10n.identifiedStockBatchDescription),
            value: draft.enableBatchTracking,
            onChanged: enabled
                ? (value) => _edit(
                    (settings) => settings.copyWith(enableBatchTracking: value),
                  )
                : null,
          ),
        ],
      ),
      if (draft.enableSerializedInventory) ...[
        SizedBox(height: spacing.lg),
        PointySectionHeader(
          title: l10n.identifiedStockSerialSectionTitle,
          leading: const Icon(Icons.smartphone_outlined),
        ),
        SizedBox(height: spacing.sm),
        PointySettingsSection(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.schedule_outlined),
              title: Text(l10n.identifiedStockCaptureLaterTitle),
              subtitle: Text(l10n.identifiedStockCaptureLaterDescription),
              value: draft.captureLaterAllowed,
              onChanged: enabled
                  ? (value) => _edit(
                      (settings) =>
                          settings.copyWith(captureLaterAllowed: value),
                    )
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.person_pin_outlined),
              title: Text(l10n.identifiedStockAssetTitle),
              subtitle: Text(l10n.identifiedStockAssetDescription),
              value: draft.requireCustomerForAsset,
              onChanged: enabled
                  ? (value) => _edit(
                      (settings) =>
                          settings.copyWith(requireCustomerForAsset: value),
                    )
                  : null,
            ),
          ],
        ),
      ],
      // Goods held for somebody else are always identified articles — a
      // consignment is a handset, a watch, a camera — so its rules belong to
      // the serial side and stay out of a pharmacy's way.
      if (draft.enableSerializedInventory) ...[
        SizedBox(height: spacing.lg),
        PointySectionHeader(
          title: l10n.identifiedStockConsignmentTitle,
          subtitle: l10n.identifiedStockConsignmentHint,
          leading: const Icon(Icons.handshake_outlined),
        ),
        SizedBox(height: spacing.sm),
        PointySettingsSection(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.sms_outlined),
              title: Text(l10n.identifiedStockConsignmentSmsTitle),
              subtitle: Text(l10n.identifiedStockConsignmentSmsDescription),
              value: draft.consignmentAutoSmsOnSale,
              onChanged: enabled
                  ? (value) => _edit(
                      (settings) =>
                          settings.copyWith(consignmentAutoSmsOnSale: value),
                    )
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.price_check_outlined),
              title: Text(l10n.identifiedStockDeclaredValueTitle),
              subtitle: Text(l10n.identifiedStockDeclaredValueDescription),
              value: draft.consignmentRequireDeclaredValue,
              onChanged: enabled
                  ? (value) => _edit(
                      (settings) => settings.copyWith(
                        consignmentRequireDeclaredValue: value,
                      ),
                    )
                  : null,
            ),
            Padding(
              padding: EdgeInsets.all(spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DaysField(
                    controller: _reminderDaysController,
                    label: l10n.identifiedStockReminderDaysLabel,
                    helper: l10n.identifiedStockReminderDaysHelper,
                    icon: Icons.alarm_outlined,
                    enabled: enabled,
                    onChanged: () => setState(() {}),
                  ),
                  SizedBox(height: spacing.md),
                  PointyInlineMessage(
                    message: l10n.identifiedStockClausesHint,
                    icon: Icons.gavel_outlined,
                  ),
                  for (final policy in _policies) ...[
                    SizedBox(height: spacing.md),
                    TextField(
                      controller: _clauseControllers[policy],
                      enabled: enabled,
                      minLines: 2,
                      maxLines: 5,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.identifiedStockClauseLabel(
                          _policyLabel(l10n, policy),
                        ),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    ];
  }
}

String _policyLabel(AppLocalizations l10n, String policy) => switch (policy) {
  ConsignmentLiability.shopLiableExceptForceMajeure =>
    l10n.consignmentIntakeLiabilityExceptFm,
  ConsignmentLiability.shopLiable => l10n.consignmentIntakeLiabilityShop,
  _ => l10n.consignmentIntakeLiabilityOwner,
};

class _DaysField extends StatelessWidget {
  const _DaysField({
    required this.controller,
    required this.label,
    required this.helper,
    required this.icon,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String helper;
  final IconData icon;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        prefixIcon: Icon(icon),
      ),
    );
  }
}
