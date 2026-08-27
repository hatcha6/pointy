import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/price_checker_device.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/price_checkers_view_model.dart';
import 'price_checker_device_details_screen.dart';
import 'price_checker_labels.dart';

/// Settings page that lists every price-checker device the shop has registered,
/// with a fleet roll-up, an on-demand network scan, and a tap-through to each
/// device's full details and recent scan activity.
class PriceCheckersPage extends StatefulWidget {
  const PriceCheckersPage({super.key, required this.viewModel});

  final PriceCheckersViewModel viewModel;

  @override
  State<PriceCheckersPage> createState() => _PriceCheckersPageState();
}

class _PriceCheckersPageState extends State<PriceCheckersPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.loadDevices());
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
            title: Text(l10n.priceCheckersSectionTitle),
            isLoading: viewModel.isBusy,
            actions: [
              IconButton(
                tooltip: l10n.priceCheckerScanTooltip,
                onPressed: viewModel.isScanning ? null : _runScan,
                icon: viewModel.isScanning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find_outlined),
              ),
              IconButton(
                tooltip: l10n.priceCheckerRefreshTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.loadDevices,
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

    if (viewModel.isLoading && !viewModel.hasDevices) {
      return const PointyLoadingArea();
    }

    if (viewModel.hasLoadError && !viewModel.hasDevices) {
      return PointyErrorState(
        title: l10n.priceCheckersLoadError,
        icon: Icons.price_check_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadDevices,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final spacing = AdaptiveSpacing.of(context);

    return RefreshIndicator(
      onRefresh: viewModel.loadDevices,
      child: ListView(
        padding: spacing.pagePadding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHero(context, l10n),
                if (viewModel.hasDevices) ...[
                  SizedBox(height: spacing.md),
                  _buildMetrics(context, l10n),
                  SizedBox(height: spacing.lg),
                  PointySectionHeader(
                    title: l10n.priceCheckerDevicesListTitle,
                    subtitle: l10n.priceCheckerDevicesCountSubtitle(
                      viewModel.totalCount,
                    ),
                    leading: const Icon(Icons.devices_other_outlined),
                  ),
                  for (final device in viewModel.devices) ...[
                    _PriceCheckerDeviceCard(
                      device: device,
                      onTap: () => _openDevice(device),
                    ),
                    SizedBox(height: spacing.sm),
                  ],
                ] else ...[
                  SizedBox(height: spacing.xl),
                  PointyEmptyState(
                    icon: Icons.price_check_outlined,
                    title: l10n.priceCheckersEmptyTitle,
                    message: l10n.priceCheckersEmptyMessage,
                    action: FilledButton.icon(
                      onPressed: viewModel.isScanning ? null : _runScan,
                      icon: const Icon(Icons.wifi_find_outlined),
                      label: Text(l10n.priceCheckerScanButton),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    return PointyDetailHero(
      icon: Icons.price_check_outlined,
      title: l10n.priceCheckersSectionTitle,
      value: '${viewModel.totalCount}',
      valueSubtitle: l10n.priceCheckerDevicesUnit,
      description: l10n.priceCheckersHeroDescription,
      pills: [
        if (viewModel.hasDevices)
          PointyHeroPill(
            label: l10n.priceCheckerServingPillLabel(viewModel.servingCount),
            icon: Icons.wifi_tethering,
          ),
        if (viewModel.discoveredCount > 0)
          PointyHeroPill(
            label: l10n.priceCheckerDiscoveredPillLabel(
              viewModel.discoveredCount,
            ),
            icon: Icons.travel_explore_outlined,
          ),
      ],
    );
  }

  Widget _buildMetrics(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    final viewModel = widget.viewModel;
    return PointyMetricGrid(
      minTileWidth: 170,
      maxColumns: 3,
      gap: PointyMetricGridGap.compact,
      metrics: [
        PointyMetricGridItem(
          label: l10n.priceCheckerStatusActive,
          value: '${viewModel.activeCount}',
          icon: Icons.check_circle_outline,
          accentColor: colors.success,
        ),
        PointyMetricGridItem(
          label: l10n.priceCheckerStatusDiscovered,
          value: '${viewModel.discoveredCount}',
          icon: Icons.travel_explore_outlined,
          accentColor: colors.warning,
        ),
        PointyMetricGridItem(
          label: l10n.priceCheckerStatusDisabled,
          value: '${viewModel.disabledCount}',
          icon: Icons.do_not_disturb_on_outlined,
          accentColor: colors.mutedInk,
        ),
      ],
    );
  }

  Future<void> _openDevice(PriceCheckerDevice device) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => PriceCheckerDeviceDetailsScreen(
          device: device,
          loadEvents: widget.viewModel.loadEventsForDevice,
        ),
      ),
    );
  }

  Future<void> _runScan() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final summary = await widget.viewModel.runScan();
    if (!mounted) {
      return;
    }
    final String message;
    if (summary == null) {
      message = l10n.priceCheckerScanError;
    } else if (summary.found == 0) {
      message = l10n.priceCheckerScanNone;
    } else {
      message = l10n.priceCheckerScanSuccess(
        summary.found,
        summary.registeredCount,
      );
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PriceCheckerDeviceCard extends StatelessWidget {
  const _PriceCheckerDeviceCard({required this.device, required this.onTap});

  final PriceCheckerDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final statusColor = priceCheckerStatusColor(colors, device);
    final endpoint = device.endpointLabel;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(spacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DeviceAvatar(device: device, statusColor: statusColor),
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
                          device.displayName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        PointyStatusPill(
                          label: priceCheckerStatusLabel(l10n, device),
                          icon: priceCheckerStatusIcon(device),
                          color: statusColor,
                        ),
                      ],
                    ),
                    SizedBox(height: spacing.xs),
                    Text(
                      '${priceCheckerHardwareLabel(device)} · '
                      '${priceCheckerTransportLabel(l10n, device)}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                    ),
                    if (endpoint.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: spacing.xs),
                        child: _IconLine(
                          icon: Icons.lan_outlined,
                          child: Text(
                            endpoint,
                            textDirection: TextDirection.ltr,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.mutedInk),
                          ),
                        ),
                      ),
                    if (device.location.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: spacing.xs),
                        child: _IconLine(
                          icon: Icons.place_outlined,
                          child: Text(
                            device.location.trim(),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.mutedInk),
                          ),
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.only(top: spacing.xs),
                      child: _IconLine(
                        icon: Icons.schedule_outlined,
                        child: Text(
                          device.lastSeenAt == null
                              ? l10n.priceCheckerNeverSeen
                              : l10n.priceCheckerLastSeen(
                                  formatDateTime(device.lastSeenAt!),
                                ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.mutedInk),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              PointyDisclosureChevron(color: colors.mutedInk),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({required this.device, required this.statusColor});

  final PriceCheckerDevice device;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          statusColor.withValues(alpha: 0.12),
          colors.surface,
        ),
        shape: BoxShape.circle,
        border: Border.all(color: statusColor.withValues(alpha: 0.22)),
      ),
      child: Icon(priceCheckerTransportIcon(device), color: statusColor),
    );
  }
}

/// A muted icon + content row used for the secondary lines on a device card.
class _IconLine extends StatelessWidget {
  const _IconLine({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: colors.mutedInk),
        const SizedBox(width: 6),
        Expanded(child: child),
      ],
    );
  }
}
