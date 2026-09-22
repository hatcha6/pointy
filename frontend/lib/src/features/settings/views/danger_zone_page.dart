import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/factory_reset.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/factory_reset_view_model.dart';

/// The one screen in the app that can empty a shop.
///
/// Built as a page rather than a button on the settings list because the
/// decision needs room: how much there is to lose, when the last backup was,
/// and what survives. A dialog can carry a warning; only a page can carry the
/// numbers, and the numbers are what make this a decision rather than a dare.
///
/// The order down the page is the order the thinking should go: what goes,
/// what stays, is there a copy — and only then the button.
class DangerZonePage extends StatefulWidget {
  const DangerZonePage({
    super.key,
    required this.viewModel,
    required this.onResetComplete,
  });

  final FactoryResetViewModel viewModel;

  /// Called after the shop has been emptied. The caller signs the app out:
  /// every till's local cache — catalogue, held invoices, prices — describes
  /// rows that no longer exist, and the login screen is the shortest path to a
  /// client that has forgotten all of it.
  final void Function(BuildContext context) onResetComplete;

  @override
  State<DangerZonePage> createState() => _DangerZonePageState();
}

class _DangerZonePageState extends State<DangerZonePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.viewModel.loadPreview());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.dangerZoneTitle),
            isLoading: widget.viewModel.isLoading,
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.hasLoadError) {
      return PointyErrorState(
        title: l10n.dangerZoneLoadError,
        icon: Icons.warning_amber_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadPreview,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final preview = viewModel.preview;
    if (preview == null) {
      return const Center(child: PointySpinner());
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointyDetailCallout(
                icon: Icons.warning_amber_outlined,
                title: l10n.factoryResetCalloutTitle,
                message: l10n.factoryResetCalloutMessage,
                tone: PointyCalloutTone.danger,
              ),
              SizedBox(height: spacing.lg),
              _WhatGoesSection(preview: preview),
              SizedBox(height: spacing.lg),
              _WhatStaysSection(preview: preview),
              SizedBox(height: spacing.lg),
              _BackupSection(preview: preview),
              SizedBox(height: spacing.lg),
              _ResetAction(
                preview: preview,
                viewModel: viewModel,
                onResetComplete: widget.onResetComplete,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The counts. Everything else on the page is words; this is the shop.
class _WhatGoesSection extends StatelessWidget {
  const _WhatGoesSection({required this.preview});

  final FactoryResetPreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    String label(String key) => switch (key) {
      'products' => l10n.factoryResetCountProducts,
      'categories' => l10n.factoryResetCountCategories,
      'customers' => l10n.factoryResetCountCustomers,
      'suppliers' => l10n.factoryResetCountSuppliers,
      'orders' => l10n.factoryResetCountOrders,
      'purchase_orders' => l10n.factoryResetCountPurchaseOrders,
      'payments' => l10n.factoryResetCountPayments,
      'stock_movements' => l10n.factoryResetCountStockMovements,
      'expenses' => l10n.factoryResetCountExpenses,
      'employees' => l10n.factoryResetCountEmployees,
      'jobs' => l10n.factoryResetCountJobs,
      'imports' => l10n.factoryResetCountImports,
      // A server that starts counting something this build has no word for
      // still gets a row: an unnamed number is better than a silent omission
      // on a screen whose whole job is to leave nothing out.
      _ => key,
    };

    final rows = <PointySummaryRow>[
      for (final entry in preview.counts.entries)
        if (entry.value > 0)
          PointySummaryRow(
            label: label(entry.key),
            value: '${entry.value}',
            valueColor: colors.danger,
          ),
      PointySummaryRow(
        label: l10n.factoryResetCountUsers,
        value: '${preview.usersRemoved}',
        valueColor: colors.danger,
        dividerAbove: true,
      ),
    ];

    return PointyDetailSection(
      icon: Icons.delete_forever_outlined,
      title: l10n.factoryResetWhatGoesTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.factoryResetWhatGoesDescription,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: AdaptiveSpacing.of(context).md),
          if (preview.totalCounted == 0)
            Text(l10n.factoryResetNothingToRemove)
          else
            PointySummaryList(rows: rows),
        ],
      ),
    );
  }
}

/// Says out loud what a reset does *not* touch.
///
/// Not reassurance for its own sake: an owner who thinks the licence and the
/// printers go too will not press this button, and will ask for a rebuild
/// instead — which is the expensive thing this feature exists to avoid.
class _WhatStaysSection extends StatelessWidget {
  const _WhatStaysSection({required this.preview});

  final FactoryResetPreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    final items = [
      l10n.factoryResetKeepsAdmin(preview.adminUsername),
      l10n.factoryResetKeepsSettings,
      l10n.factoryResetKeepsDevices,
      l10n.factoryResetKeepsLicense,
    ];

    return PointyDetailSection(
      icon: Icons.verified_outlined,
      title: l10n.factoryResetWhatStaysTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            Padding(
              padding: EdgeInsets.only(bottom: spacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check, size: 18, color: colors.success),
                  SizedBox(width: spacing.sm),
                  Expanded(child: Text(item)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The last honest chance to stop.
class _BackupSection extends StatelessWidget {
  const _BackupSection({required this.preview});

  final FactoryResetPreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final backupAt = preview.lastVerifiedBackupAt;

    return PointyDetailCallout(
      icon: backupAt == null
          ? Icons.report_gmailerrorred_outlined
          : Icons.backup_outlined,
      title: backupAt == null
          ? l10n.factoryResetNoBackupTitle
          : l10n.factoryResetBackupTitle(formatDateTime(backupAt)),
      message: backupAt == null
          ? l10n.factoryResetNoBackupMessage
          : l10n.factoryResetBackupMessage,
      tone: backupAt == null
          ? PointyCalloutTone.danger
          : PointyCalloutTone.warning,
    );
  }
}

class _ResetAction extends StatelessWidget {
  const _ResetAction({
    required this.preview,
    required this.viewModel,
    required this.onResetComplete,
  });

  final FactoryResetPreview preview;
  final FactoryResetViewModel viewModel;
  final void Function(BuildContext context) onResetComplete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return FilledButton.icon(
      key: const ValueKey('factory_reset_button'),
      onPressed: viewModel.isResetting ? null : () => _confirm(context),
      style: FilledButton.styleFrom(
        backgroundColor: colors.danger,
        foregroundColor: colors.surface,
      ),
      icon: viewModel.isResetting
          ? const SizedBox.square(
              dimension: 18,
              child: PointySpinner(strokeWidth: 2),
            )
          : const Icon(Icons.delete_forever_outlined),
      label: Text(
        viewModel.isResetting
            ? l10n.factoryResetRunningButton
            : l10n.factoryResetButton,
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _FactoryResetDialog(preview: preview, viewModel: viewModel),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.factoryResetDoneMessage)),
    );
    onResetComplete(context);
  }
}

/// Two fields, and neither is optional.
///
/// The password answers *who is asking* — an unlocked till at the counter is
/// the realistic way this gets pressed by the wrong person. The shop name
/// answers *which shop they think this is*, which matters most for the owner
/// who runs a second backend in the back office and has both apps open. The
/// confirm button stays dead until the name matches exactly, so the last thing
/// between a shop and an empty database is not a reflex.
class _FactoryResetDialog extends StatefulWidget {
  const _FactoryResetDialog({required this.preview, required this.viewModel});

  final FactoryResetPreview preview;
  final FactoryResetViewModel viewModel;

  @override
  State<_FactoryResetDialog> createState() => _FactoryResetDialogState();
}

class _FactoryResetDialogState extends State<_FactoryResetDialog> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  bool get _nameMatches =>
      _confirmationController.text.trim() == widget.preview.shopName.trim();

  bool get _canSubmit =>
      _nameMatches &&
      _passwordController.text.isNotEmpty &&
      !widget.viewModel.isResetting;

  Future<void> _submit() async {
    final ok = await widget.viewModel.reset(
      password: _passwordController.text,
      confirmation: _confirmationController.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      // Stays open on a refusal, with the server's reason under the fields.
      // Closing would make the owner walk the whole page again to retry a
      // mistyped password.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final failure = widget.viewModel.failureMessage;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) => AlertDialog(
        icon: Icon(Icons.delete_forever_outlined, color: colors.danger),
        title: Text(l10n.factoryResetDialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.factoryResetDialogMessage(widget.preview.shopName)),
              SizedBox(height: spacing.md),
              PointyPasswordField(
                key: const ValueKey('factory_reset_password'),
                controller: _passwordController,
                labelText: l10n.factoryResetPasswordLabel,
                enabled: !widget.viewModel.isResetting,
                textDirection: TextDirection.ltr,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: spacing.sm),
              TextField(
                key: const ValueKey('factory_reset_confirmation'),
                controller: _confirmationController,
                enabled: !widget.viewModel.isResetting,
                decoration: InputDecoration(
                  labelText: l10n.factoryResetConfirmationLabel,
                  helperText: l10n.factoryResetConfirmationHelper(
                    widget.preview.shopName,
                  ),
                  prefixIcon: const Icon(Icons.storefront_outlined),
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (failure != null) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage(
                  message: failure,
                  tone: PointyInlineMessageTone.error,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: widget.viewModel.isResetting
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('factory_reset_confirm'),
            onPressed: _canSubmit ? _submit : null,
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.surface,
            ),
            child: Text(l10n.factoryResetDialogConfirm),
          ),
        ],
      ),
    );
  }
}
