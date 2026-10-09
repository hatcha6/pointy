import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_credentials_sheet.dart';
import 'integration_enable_switch.dart';
import 'integration_float_sheet.dart';
import 'integration_prices_sheet.dart';
import 'integration_presentation.dart';
import 'integration_profile_sheet.dart';
import 'integration_verification_sheet.dart';
import 'voucher_pricing_screen.dart';

/// Shop Settings → Integrations.
///
/// Lists every outside service a Pointy shop can resell, whether or not it can
/// be connected yet: an owner who resells HD Box today and LNET next year is
/// better served by seeing both than by a screen that hides the roadmap.
class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key, required this.viewModel});

  final IntegrationsViewModel viewModel;

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_onViewModelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.load();
    });
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onViewModelChanged);
    super.dispose();
  }

  void _onViewModelChanged() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;

    final exception = viewModel.actionException;
    if (exception != null) {
      _showSnack(errorMessageFor(exception, l10n), isError: true);
      viewModel.acknowledgeResult();
      return;
    }

    final probe = viewModel.lastProbe;
    if (probe != null) {
      _showSnack(_probeMessage(probe, l10n), isError: !probe.ok);
      viewModel.acknowledgeResult();
    }
  }

  String _probeMessage(IntegrationProbeResult probe, AppLocalizations l10n) {
    if (!probe.ok) {
      return integrationErrorText(probe.errorCode, l10n);
    }
    final balance = probe.provider?.account?.balance;
    if (balance == null) {
      return l10n.integrationProbeSuccess;
    }
    return l10n.integrationProbeSuccessWithBalance(formatMoney(balance));
  }

  void _showSnack(String message, {required bool isError}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? context.pointyColors.danger : null,
        ),
      );
  }

  Future<void> _edit(IntegrationProvider provider) async {
    final saved = await showIntegrationCredentialsSheet(
      context: context,
      provider: provider,
      viewModel: widget.viewModel,
    );
    if (saved != true || !mounted) return;
    _showSnack(AppLocalizations.of(context)!.integrationSaved, isError: false);
    // A provider that needs this device confirmed says so on the first real
    // login, so check at once rather than leaving the owner to find the Test
    // button — and walk straight into the confirmation if it is needed.
    if (!provider.sellsVouchers) return;
    await widget.viewModel.probe(provider.key);
    if (!mounted) return;
    final refreshed = widget.viewModel.providerFor(provider.key);
    if (refreshed?.account?.needsDeviceVerification ?? false) {
      widget.viewModel.acknowledgeResult();
      await _verify(refreshed!);
    }
  }

  Future<void> _verify(IntegrationProvider provider) async {
    final verified = await showIntegrationVerificationSheet(
      context: context,
      provider: provider,
      viewModel: widget.viewModel,
    );
    if (verified == true && mounted) {
      _showSnack(
        AppLocalizations.of(context)!.integrationVerifyDone,
        isError: false,
      );
    }
  }

  Future<void> _profile(IntegrationProvider provider) async {
    final saved = await showIntegrationProfileSheet(
      context: context,
      provider: provider,
      viewModel: widget.viewModel,
    );
    if (saved == true && mounted) {
      _showSnack(
        AppLocalizations.of(context)!.integrationProfileSaved,
        isError: false,
      );
    }
  }

  Future<void> _prices(IntegrationProvider provider) async {
    final saved = await showIntegrationPricesSheet(
      context: context,
      providerKey: provider.key,
      viewModel: widget.viewModel,
    );
    if (saved == true && mounted) {
      _showSnack(
        AppLocalizations.of(context)!.integrationPricesSaved,
        isError: false,
      );
    }
  }

  Future<void> _float(IntegrationProvider provider) async {
    final saved = await showIntegrationFloatSheet(
      context: context,
      providerKey: provider.key,
      viewModel: widget.viewModel,
    );
    if (saved == true && mounted) {
      _showSnack(
        AppLocalizations.of(context)!.integrationTopUpSaved,
        isError: false,
      );
    }
  }

  /// A provider that asks for no credential is switched on and off, not
  /// connected: «كروت دفتر».
  Future<void> _setEnabled(IntegrationProvider provider, bool enabled) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await widget.viewModel.setEnabled(provider.key, enabled);
    if (ok && mounted) {
      _showSnack(
        enabled ? l10n.integrationEnabledToast : l10n.integrationDisabledToast,
        isError: false,
      );
    }
  }

  Future<void> _disconnect(IntegrationProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PointyDestructiveConfirmationDialog(
        title: l10n.integrationDisconnectConfirmTitle,
        message: l10n.integrationDisconnectConfirmBody,
        confirmLabel: l10n.integrationDisconnectConfirmAction,
        icon: Icons.link_off,
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.viewModel.disconnect(provider.key);
    if (ok && mounted) {
      _showSnack(l10n.integrationDisconnected, isError: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.integrationsTitle)),
      body: AnimatedBuilder(
        animation: widget.viewModel,
        builder: (context, _) => _buildBody(context, l10n),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    if (viewModel.isLoading && viewModel.providers.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.providers.isEmpty) {
      return PointyErrorState(
        title: l10n.integrationsLoadError,
        icon: Icons.extension_off_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.integrationsRetry),
        ),
      );
    }
    if (viewModel.providers.isEmpty) {
      return PointyEmptyState(
        title: l10n.integrationsEmpty,
        icon: Icons.extension_outlined,
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    return ListView(
      padding: spacing.pagePadding,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.integrationsPageIntro,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
              SizedBox(height: spacing.md),
              Card(
                child: ListTile(
                  key: const ValueKey('integrations_voucher_pricing'),
                  leading: const Icon(Icons.tune_rounded),
                  title: Text(l10n.voucherPricingTitle),
                  subtitle: Text(l10n.voucherPricingTileSubtitle),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () =>
                      showVoucherPricingScreen(context, viewModel.repository),
                ),
              ),
              SizedBox(height: spacing.md),
              for (final provider in viewModel.providers) ...[
                IntegrationProviderCard(
                  provider: provider,
                  isBusy: viewModel.isBusy(provider.key),
                  busyKind: viewModel.busyKind,
                  onEdit: () => _edit(provider),
                  onTest: () => viewModel.probe(provider.key),
                  onDisconnect: () => _disconnect(provider),
                  onPrices: () => _prices(provider),
                  onFloat: () => _float(provider),
                  onVerify: () => _verify(provider),
                  onProfile: () => _profile(provider),
                  onEnabledChanged: (value) => _setEnabled(provider, value),
                ),
                SizedBox(height: spacing.md),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One provider, in whatever state it is in. Public so the preview harness and
/// widget tests can render a single card without a view model behind it.
class IntegrationProviderCard extends StatelessWidget {
  const IntegrationProviderCard({
    super.key,
    required this.provider,
    this.isBusy = false,
    this.busyKind = IntegrationBusyKind.none,
    this.onEdit,
    this.onTest,
    this.onDisconnect,
    this.onPrices,
    this.onFloat,
    this.onVerify,
    this.onProfile,
    this.onEnabledChanged,
  });

  final IntegrationProvider provider;
  final bool isBusy;
  final IntegrationBusyKind busyKind;
  final VoidCallback? onEdit;
  final VoidCallback? onTest;
  final VoidCallback? onDisconnect;

  /// Opens the shop's retail price list. Only meaningful once connected —
  /// the list is learned from real lookups, so there is nothing to price
  /// before then.
  final VoidCallback? onPrices;

  /// Opens the provider float — what the shop has paid in, what has been
  /// drawn, and recording another top-up.
  final VoidCallback? onFloat;

  /// Confirms this device with a provider that refuses unknown devices.
  final VoidCallback? onVerify;

  /// Chooses which of the login's profiles (shops) Pointy buys as.
  final VoidCallback? onProfile;

  /// Switches on or off a provider that asks for no credential.
  final ValueChanged<bool>? onEnabledChanged;

  bool get _isPlanned =>
      provider.availability == IntegrationAvailability.planned;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, l10n, spacing),
            if (provider.capabilities.isNotEmpty) ...[
              SizedBox(height: spacing.sm),
              _buildCapabilities(context, l10n, spacing),
            ],
            ..._buildDetail(context, l10n, spacing),
            ..._buildActions(context, l10n, spacing),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntegrationProviderLogo(providerKey: provider.key),
        SizedBox(width: spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                integrationProviderName(provider.key, l10n),
                style: theme.textTheme.titleMedium,
              ),
              SizedBox(height: spacing.xs),
              Text(
                integrationProviderTagline(provider.key, l10n),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: spacing.sm),
        _buildStatusPill(context, l10n),
      ],
    );
  }

  Widget _buildStatusPill(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    if (_isPlanned) {
      return PointyStatusPill(
        label: l10n.integrationAvailabilityPlanned,
        icon: Icons.schedule_outlined,
        color: colors.mutedInk,
      );
    }
    if (provider.switchedOff) {
      return PointyStatusPill(
        label: l10n.integrationStatusSwitchedOff,
        icon: Icons.block_outlined,
        color: colors.warning,
      );
    }
    final account = provider.account;
    // No login to be missing: it is on, or it is not.
    if (provider.needsNoCredentials &&
        (account == null || !account.isConfigured || !account.isActive)) {
      return PointyStatusPill(
        label: l10n.integrationStatusNotEnabled,
        icon: Icons.toggle_off_outlined,
        color: colors.mutedInk,
      );
    }
    if (account == null || !account.isConfigured) {
      return PointyStatusPill(
        label: l10n.integrationStatusNotConfigured,
        icon: Icons.link_off_outlined,
        color: colors.mutedInk,
      );
    }
    if (!account.isActive) {
      return PointyStatusPill(
        label: l10n.integrationStatusDisabled,
        icon: Icons.pause_circle_outline,
        color: colors.warning,
      );
    }
    if (account.hasFailed) {
      return PointyStatusPill(
        label: l10n.integrationStatusFailed,
        icon: Icons.error_outline,
        color: colors.danger,
      );
    }
    return PointyStatusPill(
      label: provider.needsNoCredentials
          ? l10n.integrationStatusEnabled
          : l10n.integrationStatusConnected,
      icon: Icons.check_circle_outline,
      color: colors.success,
    );
  }

  Widget _buildCapabilities(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final colors = context.pointyColors;
    return Wrap(
      spacing: spacing.xs,
      runSpacing: spacing.xs,
      children: [
        for (final capability in provider.capabilities)
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.subtleFill,
              borderRadius: BorderRadius.circular(PointyRadii.pill),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.sm,
                vertical: spacing.xs / 2,
              ),
              child: Text(
                integrationCapabilityLabel(capability, l10n),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: colors.mutedInk),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildDetail(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    if (_isPlanned) {
      return [
        SizedBox(height: spacing.sm),
        PointyInlineMessage(
          message: integrationBlockedReasonText(provider.blockedReason, l10n),
          icon: Icons.schedule_outlined,
          compact: true,
        ),
      ];
    }

    // Said before anything else on the card: the owner did nothing wrong, and
    // nothing here will make it work until it is switched back on.
    final switchedOff = [
      if (provider.switchedOff) ...[
        SizedBox(height: spacing.sm),
        // Not compact: its two-line clamp would cut off the part that says
        // the shop's record is safe.
        PointyInlineMessage.warning(
          message: l10n.integrationSwitchedOffMessage,
          icon: Icons.block_outlined,
        ),
      ],
    ];

    // The switch is the whole setup of a provider that asks for no login.
    final enableSwitch = [
      if (provider.needsNoCredentials && provider.isConfigurable) ...[
        SizedBox(height: spacing.sm),
        IntegrationEnableSwitch(
          provider: provider,
          isBusy: isBusy && busyKind == IntegrationBusyKind.saving,
          onChanged: provider.switchedOff ? null : onEnabledChanged,
        ),
      ],
    ];

    final account = provider.account;
    if (account == null || !account.isConfigured || !provider.isEnabled) {
      if (provider.needsNoCredentials) {
        return [...switchedOff, ...enableSwitch];
      }
    }
    if (account == null || !account.isConfigured) {
      return switchedOff;
    }

    final widgets = <Widget>[
      ...switchedOff,
      ...enableSwitch,
      SizedBox(height: spacing.sm),
    ];

    // A switched-off provider is not asked anything, so its last error is old
    // news beside the reason above.
    if (account.hasFailed && !provider.switchedOff) {
      widgets.add(
        PointyInlineMessage.error(
          message: integrationErrorText(account.lastErrorCode, l10n),
          compact: true,
        ),
      );
      widgets.add(SizedBox(height: spacing.sm));
    }

    widgets.add(
      PointySummaryList(
        rows: [
          PointySummaryRow(
            label: integrationBalanceLabel(provider.key, l10n),
            value: account.balance == null
                ? l10n.integrationBalanceUnknown
                : formatMoney(account.balance!),
            emphasized: true,
          ),
          if (account.accountLabel.isNotEmpty)
            PointySummaryRow(
              label: l10n.integrationFieldUsername,
              value: account.accountLabel,
            ),
          if (provider.hasProfiles && account.profileName.isNotEmpty)
            PointySummaryRow(
              label: l10n.integrationProfileLabel,
              value: account.profileName,
            ),
        ],
      ),
    );

    // The service address gets its own wrapping line rather than a summary
    // row: PointySummaryList lays its value out at natural width, and a URL
    // overflows that on anything narrower than a desk. A provider with no
    // login has no address of the shop's to show.
    final address = account.baseUrl.isEmpty
        ? provider.defaultBaseUrl
        : account.baseUrl;
    if (address.isNotEmpty) {
      widgets
        ..add(SizedBox(height: spacing.xs))
        ..add(
          Text(
            ltrIsolated(address),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        );
    }

    widgets
      ..add(SizedBox(height: spacing.xs))
      ..add(
        Text(
          account.lastCheckedAt == null
              ? l10n.integrationNeverChecked
              : l10n.integrationBalanceCheckedAt(
                  _formatTime(account.lastCheckedAt!),
                ),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.pointyColors.mutedInk),
        ),
      );

    return widgets;
  }

  List<Widget> _buildActions(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    if (!provider.isConfigurable) {
      return const [];
    }
    if (provider.needsNoCredentials) {
      return _buildSwitchedActions(context, l10n, spacing);
    }
    final isConfigured = provider.isConfigured;
    // Switched off for every shop: only what never reaches the provider stays
    // — the float ledger, and letting go of the stored login.
    final live = !provider.switchedOff;
    if (!live && !isConfigured) {
      return const [];
    }
    final needsVerification =
        live &&
        isConfigured &&
        (provider.account?.needsDeviceVerification ?? false);
    return [
      SizedBox(height: spacing.md),
      Wrap(
        spacing: spacing.sm,
        runSpacing: spacing.sm,
        children: [
          // The one thing standing between this shop and a working provider,
          // so it leads the row while it is needed.
          if (needsVerification)
            FilledButton.icon(
              onPressed: isBusy ? null : onVerify,
              icon: const Icon(Icons.verified_user_outlined),
              label: Text(l10n.integrationVerifyAction),
            ),
          if (live)
            FilledButton.icon(
              onPressed: isBusy ? null : onEdit,
              icon: Icon(isConfigured ? Icons.edit_outlined : Icons.link),
              label: Text(
                isConfigured ? l10n.integrationEdit : l10n.integrationConnect,
              ),
            ),
          if (live && isConfigured)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onTest,
              icon: isBusy && busyKind == IntegrationBusyKind.probing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: Text(l10n.integrationTest),
            ),
          if (isConfigured)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onFloat,
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: Text(l10n.integrationFloatAction),
            ),
          if (live && isConfigured && provider.hasProfiles)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onProfile,
              icon: const Icon(Icons.storefront_outlined),
              label: Text(l10n.integrationProfileAction),
            ),
          // A provider's cards are priced by the provider and sold from the
          // catalog; there is no price list of the shop's own to edit.
          if (live && isConfigured && !provider.sellsVouchers)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onPrices,
              icon: const Icon(Icons.price_change_outlined),
              label: Text(l10n.integrationPricesAction),
            ),
          if (isConfigured)
            TextButton.icon(
              onPressed: isBusy ? null : onDisconnect,
              icon: const Icon(Icons.link_off),
              label: Text(l10n.integrationDisconnect),
            ),
        ],
      ),
    ];
  }

  /// What a provider with no login offers once it is on: re-reading its
  /// balance, and its settings (the low-balance alert). No float to record
  /// into — its balance is filled from the Daftar wallet — and nothing to
  /// disconnect: the switch above turns it off.
  List<Widget> _buildSwitchedActions(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    if (!provider.isEnabled || provider.switchedOff) {
      return const [];
    }
    return [
      SizedBox(height: spacing.md),
      Wrap(
        spacing: spacing.sm,
        runSpacing: spacing.sm,
        children: [
          OutlinedButton.icon(
            onPressed: isBusy ? null : onTest,
            icon: isBusy && busyKind == IntegrationBusyKind.probing
                ? const SizedBox.square(
                    dimension: 16,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(l10n.integrationRefreshBalance),
          ),
          if (provider.settings.isNotEmpty)
            OutlinedButton.icon(
              onPressed: isBusy ? null : onEdit,
              icon: const Icon(Icons.tune_outlined),
              label: Text(l10n.integrationSettingsAction),
            ),
        ],
      ),
    ];
  }

  static String _formatTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return ltrIsolated(
      '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}',
    );
  }
}
