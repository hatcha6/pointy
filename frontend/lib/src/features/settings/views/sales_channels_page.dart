import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sales_channel.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/sales_channels_view_model.dart';

class SalesChannelsPage extends StatefulWidget {
  const SalesChannelsPage({super.key, required this.viewModel});

  final SalesChannelsViewModel viewModel;

  @override
  State<SalesChannelsPage> createState() => _SalesChannelsPageState();
}

class _SalesChannelsPageState extends State<SalesChannelsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.loadChannels());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.salesChannelsSectionTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.salesChannelAddButton,
                onPressed: viewModel.isMutating
                    ? null
                    : () => _openCreateChannelDialog(context),
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.loadChannels,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.channels.isEmpty) {
      return const PointyLoadingArea();
    }

    if (viewModel.hasLoadError && viewModel.channels.isEmpty) {
      return PointyErrorState(
        title: l10n.salesChannelsLoadError,
        icon: Icons.hub_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadChannels,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final channels = viewModel.channels;
    final hasExternalChannels = channels.any((channel) => !channel.isSystem);

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySettingsSection(
                children: [
                  for (final channel in channels)
                    _SalesChannelTile(
                      channel: channel,
                      isBusy: viewModel.isMutating,
                      onToggleActive: () => _confirmToggleActive(channel),
                      onRotateKey: () => _confirmRotateKey(channel),
                      onDelete: () => _confirmDelete(channel),
                    ),
                ],
              ),
              if (!hasExternalChannels) ...[
                SizedBox(height: spacing.lg),
                PointyEmptyState(
                  icon: Icons.hub_outlined,
                  title: l10n.salesChannelsEmptyMessage,
                  action: FilledButton.icon(
                    onPressed: () => _openCreateChannelDialog(context),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.salesChannelAddButton),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openCreateChannelDialog(BuildContext context) async {
    final draft = await showDialog<SalesChannelDraft>(
      context: context,
      builder: (dialogContext) => const _SalesChannelCreateDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }

    final grant = await widget.viewModel.createChannel(draft);
    if (!mounted) {
      return;
    }
    if (grant == null) {
      _showActionError();
      return;
    }
    await _showApiKeyDialog(grant);
  }

  Future<void> _confirmToggleActive(SalesChannel channel) async {
    final l10n = AppLocalizations.of(context)!;
    if (channel.isActive) {
      final confirmed = await _confirm(
        title: l10n.salesChannelDeauthorizeConfirmTitle,
        message: l10n.salesChannelDeauthorizeConfirmMessage(channel.name),
        confirmLabel: l10n.salesChannelDeauthorizeAction,
        icon: Icons.block_outlined,
      );
      if (!confirmed) {
        return;
      }
    }

    final updated = await widget.viewModel.setChannelActive(
      channel,
      isActive: !channel.isActive,
    );
    if (mounted && !updated) {
      _showActionError();
    }
  }

  Future<void> _confirmRotateKey(SalesChannel channel) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.salesChannelRotateKeyConfirmTitle,
      message: l10n.salesChannelRotateKeyConfirmMessage,
      confirmLabel: l10n.salesChannelRotateKeyAction,
      icon: Icons.key_outlined,
    );
    if (!confirmed || !mounted) {
      return;
    }

    final grant = await widget.viewModel.rotateChannelKey(channel);
    if (!mounted) {
      return;
    }
    if (grant == null) {
      _showActionError();
      return;
    }
    await _showApiKeyDialog(grant);
  }

  Future<void> _confirmDelete(SalesChannel channel) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.salesChannelDeleteConfirmTitle,
      message: l10n.salesChannelDeleteConfirmMessage(channel.name),
      confirmLabel: l10n.salesChannelDeleteAction,
      icon: Icons.delete_outline,
    );
    if (!confirmed || !mounted) {
      return;
    }

    final deleted = await widget.viewModel.deleteChannel(channel);
    if (mounted && !deleted) {
      _showActionError();
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required IconData icon,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PointyDestructiveConfirmationDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        icon: icon,
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _showApiKeyDialog(SalesChannelKeyGrant grant) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _SalesChannelApiKeyDialog(grant: grant),
    );
  }

  void _showActionError() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.salesChannelActionError)));
  }
}

class _SalesChannelTile extends StatelessWidget {
  const _SalesChannelTile({
    required this.channel,
    required this.isBusy,
    required this.onToggleActive,
    required this.onRotateKey,
    required this.onDelete,
  });

  final SalesChannel channel;
  final bool isBusy;
  final VoidCallback onToggleActive;
  final VoidCallback onRotateKey;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm,
      ),
      child: Row(
        children: [
          Icon(_channelIcon(channel.type), color: colors.primaryStrong),
          SizedBox(width: spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: spacing.sm,
                  runSpacing: spacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      channel.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    PointyStatusPill(
                      label: channel.isActive
                          ? l10n.salesChannelStatusActive
                          : l10n.salesChannelStatusInactive,
                      icon: channel.isActive
                          ? Icons.verified_outlined
                          : Icons.block_outlined,
                      color: channel.isActive
                          ? colors.primaryStrong
                          : colors.danger,
                    ),
                    if (channel.isSystem)
                      PointyStatusPill(
                        label: l10n.salesChannelSystemBadge,
                        icon: Icons.point_of_sale_outlined,
                      ),
                  ],
                ),
                SizedBox(height: spacing.xs),
                Text(
                  _subtitle(l10n),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (!channel.isSystem)
            PopupMenuButton<_SalesChannelAction>(
              enabled: !isBusy,
              onSelected: (action) => switch (action) {
                _SalesChannelAction.toggleActive => onToggleActive(),
                _SalesChannelAction.rotateKey => onRotateKey(),
                _SalesChannelAction.delete => onDelete(),
              },
              itemBuilder: (menuContext) => [
                PopupMenuItem(
                  value: _SalesChannelAction.toggleActive,
                  child: Text(
                    channel.isActive
                        ? l10n.salesChannelDeauthorizeAction
                        : l10n.salesChannelAuthorizeAction,
                  ),
                ),
                PopupMenuItem(
                  value: _SalesChannelAction.rotateKey,
                  child: Text(l10n.salesChannelRotateKeyAction),
                ),
                PopupMenuItem(
                  value: _SalesChannelAction.delete,
                  child: Text(l10n.salesChannelDeleteAction),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _subtitle(AppLocalizations l10n) {
    if (channel.isSystem) {
      return l10n.salesChannelPosSubtitle;
    }
    final parts = [
      salesChannelTypeLabel(l10n, channel.type),
      if (channel.apiKeyPrefix.isNotEmpty)
        l10n.salesChannelKeyPrefixLabel(channel.apiKeyPrefix),
    ];
    return parts.join(' · ');
  }

  IconData _channelIcon(SalesChannelType type) {
    return switch (type) {
      SalesChannelType.pos => Icons.point_of_sale_outlined,
      SalesChannelType.delivery => Icons.delivery_dining_outlined,
      SalesChannelType.ecommerce => Icons.storefront_outlined,
      SalesChannelType.marketplace => Icons.shopping_bag_outlined,
      SalesChannelType.other => Icons.hub_outlined,
    };
  }
}

enum _SalesChannelAction { toggleActive, rotateKey, delete }

String salesChannelTypeLabel(AppLocalizations l10n, SalesChannelType type) {
  return switch (type) {
    SalesChannelType.pos => l10n.salesChannelTypePos,
    SalesChannelType.delivery => l10n.salesChannelTypeDelivery,
    SalesChannelType.ecommerce => l10n.salesChannelTypeEcommerce,
    SalesChannelType.marketplace => l10n.salesChannelTypeMarketplace,
    SalesChannelType.other => l10n.salesChannelTypeOther,
  };
}

class _SalesChannelCreateDialog extends StatefulWidget {
  const _SalesChannelCreateDialog();

  @override
  State<_SalesChannelCreateDialog> createState() =>
      _SalesChannelCreateDialogState();
}

class _SalesChannelCreateDialogState extends State<_SalesChannelCreateDialog> {
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();
  SalesChannelType _type = SalesChannelType.delivery;
  bool _showValidationError = false;

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AlertDialog(
      icon: const Icon(Icons.hub_outlined),
      title: Text(l10n.salesChannelCreateTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.salesChannelNameLabel,
                errorText:
                    _showValidationError && _nameController.text.trim().isEmpty
                    ? l10n.salesChannelNameRequired
                    : null,
              ),
            ),
            SizedBox(height: spacing.md),
            DropdownButtonFormField<SalesChannelType>(
              initialValue: _type,
              decoration: InputDecoration(
                labelText: l10n.salesChannelTypeLabel,
              ),
              items: [
                for (final type in SalesChannelType.values)
                  if (type != SalesChannelType.pos)
                    DropdownMenuItem(
                      value: type,
                      child: Text(salesChannelTypeLabel(l10n, type)),
                    ),
              ],
              onChanged: (type) {
                if (type != null) {
                  setState(() => _type = type);
                }
              },
            ),
            SizedBox(height: spacing.md),
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: l10n.salesChannelNotesLabel,
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
          onPressed: _submit,
          child: Text(l10n.salesChannelCreateSubmit),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _showValidationError = true);
      return;
    }
    Navigator.of(context).pop(
      SalesChannelDraft(
        name: name,
        type: _type,
        notes: _notesController.text.trim(),
      ),
    );
  }
}

class _SalesChannelApiKeyDialog extends StatelessWidget {
  const _SalesChannelApiKeyDialog({required this.grant});

  final SalesChannelKeyGrant grant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AlertDialog(
      icon: const Icon(Icons.key_outlined),
      title: Text(l10n.salesChannelApiKeyDialogTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.salesChannelApiKeyDialogMessage),
            SizedBox(height: spacing.md),
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.pointyColors.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: EdgeInsets.all(spacing.md),
                child: SelectableText(
                  grant.apiKey,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: grant.apiKey));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.salesChannelApiKeyCopiedMessage)),
              );
            }
          },
          icon: const Icon(Icons.copy_outlined),
          label: Text(l10n.salesChannelApiKeyCopyButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.closeButton),
        ),
      ],
    );
  }
}
