import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/moamalat.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/moamalat_link_view_model.dart';
import 'moamalat_link_form.dart';
import 'moamalat_presentation.dart';

/// التحقق من البطاقات: the shop's Moamalat link for live card verification.
///
/// The supervisor links the merchant account with an OTP; both the shop's
/// server and Daftar's relay then keep it warm. Nothing here can block a sale:
/// a payment that cannot be checked waits as "pending verification".
class MoamalatPage extends StatefulWidget {
  const MoamalatPage({super.key, required this.viewModel, this.navigation});

  final MoamalatLinkViewModel viewModel;
  final AppNavigation? navigation;

  @override
  State<MoamalatPage> createState() => _MoamalatPageState();
}

class _MoamalatPageState extends State<MoamalatPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.viewModel.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final navigation = widget.navigation;
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        return PointyScaffold(
          drawer: navigation == null
              ? null
              : AppNavigationDrawer(
                  selectedDestination:
                      AppNavigationDestination.cardVerification,
                  navigation: navigation,
                ),
          appBar: PointyAppBar(
            leading: navigation == null
                ? null
                : const PointyNavigationMenuButton(),
            title: Text(l10n.moamalatTitle),
            isLoading: viewModel.isLoading || viewModel.isBusy,
            actions: [
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _body(context, l10n, viewModel),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    MoamalatLinkViewModel viewModel,
  ) {
    final status = viewModel.status;
    if (status == null) {
      if (viewModel.hasLoadError) {
        return PointyErrorState(
          title: l10n.moamalatTitle,
          icon: Icons.credit_score_outlined,
          action: FilledButton.icon(
            onPressed: viewModel.load,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return const PointyLoadingArea();
    }
    final spacing = AdaptiveSpacing.of(context);
    final presentation = moamalatStatePresentation(context, status);
    final needsLink =
        !status.switchedOff && status.state != MoamalatLinkState.alive;
    return ListView(
      padding: spacing.pagePadding,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PointyDetailCallout(
                  icon: presentation.icon,
                  title: presentation.label,
                  message: _stateMessage(l10n, status),
                  tone: switch (status.state) {
                    _ when status.switchedOff => PointyCalloutTone.neutral,
                    MoamalatLinkState.alive when status.atRisk =>
                      PointyCalloutTone.warning,
                    MoamalatLinkState.alive => PointyCalloutTone.success,
                    MoamalatLinkState.needsReauth => PointyCalloutTone.danger,
                    MoamalatLinkState.unlinked => PointyCalloutTone.neutral,
                  },
                ),
                if (status.isLinked) ...[
                  SizedBox(height: spacing.lg),
                  _AccountSection(status: status),
                ],
                if (viewModel.merchants.length > 1 &&
                    status.state == MoamalatLinkState.alive) ...[
                  SizedBox(height: spacing.lg),
                  _MerchantChoice(viewModel: viewModel, status: status),
                ],
                if (needsLink) ...[
                  SizedBox(height: spacing.lg),
                  PointyDetailSection(
                    title: status.state == MoamalatLinkState.needsReauth
                        ? l10n.moamalatRelinkTitle
                        : l10n.moamalatLinkTitle,
                    icon: Icons.link,
                    child: MoamalatLinkForm(
                      viewModel: viewModel,
                      initialUsername: status.username,
                    ),
                  ),
                ],
                SizedBox(height: spacing.lg),
                PointyInlineMessage(
                  message: l10n.moamalatNeverBlocksNote,
                  icon: Icons.info_outline,
                ),
                if (status.isLinked) ...[
                  SizedBox(height: spacing.lg),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: viewModel.isBusy ? null : _confirmUnlink,
                      icon: const Icon(Icons.link_off),
                      label: Text(l10n.moamalatUnlinkAction),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _stateMessage(AppLocalizations l10n, MoamalatStatus status) {
    if (status.switchedOff) return l10n.moamalatSwitchedOffMessage;
    return switch (status.state) {
      MoamalatLinkState.alive when status.atRisk => l10n.moamalatAtRiskMessage,
      MoamalatLinkState.alive => l10n.moamalatAliveMessage,
      MoamalatLinkState.needsReauth => l10n.moamalatNeedsReauthMessage(
        status.pendingCount,
      ),
      MoamalatLinkState.unlinked => l10n.moamalatUnlinkedMessage,
    };
  }

  Future<void> _confirmUnlink() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        title: l10n.moamalatUnlinkConfirmTitle,
        message: l10n.moamalatUnlinkConfirmMessage,
        confirmLabel: l10n.moamalatUnlinkAction,
        icon: Icons.link_off,
      ),
    );
    if (confirmed == true) {
      await widget.viewModel.unlink();
    }
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.status});

  final MoamalatStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String when(DateTime? at) =>
        at == null ? '—' : ltrIsolated(formatDateTime(at.toLocal()));
    final relay = status.relay;
    return PointyDetailSection(
      title: l10n.moamalatAccountTitle,
      icon: Icons.storefront_outlined,
      child: Column(
        children: [
          PointyDetailRow(
            label: l10n.moamalatMerchantLabel,
            value: status.merchantName.isEmpty ? '—' : status.merchantName,
          ),
          PointyDetailRow(
            label: l10n.moamalatMidLabel,
            value: ltrIsolated(status.mid),
          ),
          PointyDetailRow(
            label: l10n.moamalatUsernameLabel,
            value: ltrIsolated(status.username),
          ),
          PointyDetailRow(
            label: l10n.moamalatLinkedAtLabel,
            value: status.linkedBy.isEmpty
                ? when(status.linkedAt)
                : '${when(status.linkedAt)} · ${status.linkedBy}',
          ),
          PointyDetailRow(
            label: l10n.moamalatLastOkLabel,
            value: when(status.lastOkAt),
          ),
          PointyDetailRow(
            label: l10n.moamalatRelayLabel,
            value: relay.inStep && relay.state == 'alive'
                ? l10n.moamalatRelayInStep
                : (relay.holdsCopy
                      ? l10n.moamalatRelayOutOfStep
                      : l10n.moamalatRelayNone),
          ),
          PointyDetailRow(
            label: l10n.moamalatPendingLabel,
            value: status.pendingOverdueCount > 0
                ? l10n.moamalatPendingWithOverdue(
                    status.pendingCount,
                    status.pendingOverdueCount,
                  )
                : '${status.pendingCount}',
          ),
        ],
      ),
    );
  }
}

class _MerchantChoice extends StatelessWidget {
  const _MerchantChoice({required this.viewModel, required this.status});

  final MoamalatLinkViewModel viewModel;
  final MoamalatStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.moamalatMerchantChoiceTitle,
      icon: Icons.store_mall_directory_outlined,
      child: Column(
        children: [
          for (final merchant in viewModel.merchants)
            ListTile(
              selected: merchant.mid == status.mid,
              leading: Icon(
                merchant.mid == status.mid
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(merchant.name.isEmpty ? merchant.mid : merchant.name),
              subtitle: Text(ltrIsolated(merchant.mid)),
              onTap: viewModel.isBusy || merchant.mid == status.mid
                  ? null
                  : () => viewModel.chooseMerchant(merchant.mid),
            ),
        ],
      ),
    );
  }
}
