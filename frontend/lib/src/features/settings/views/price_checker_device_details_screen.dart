import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/price_check_event.dart';
import '../../../data/models/price_checker_device.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import 'price_checker_labels.dart';
import '../../../shared/formatters.dart';

/// Loads a single device's recent scan events. Supplied by the list page so
/// this screen needs no repository of its own.
typedef PriceCheckEventLoader =
    Future<List<PriceCheckEvent>?> Function(int deviceId);

/// Full read-only profile for one price-checker device: a status callout, its
/// network + display specs, and its most recent scan activity.
class PriceCheckerDeviceDetailsScreen extends StatefulWidget {
  const PriceCheckerDeviceDetailsScreen({
    super.key,
    required this.device,
    required this.loadEvents,
  });

  final PriceCheckerDevice device;
  final PriceCheckEventLoader loadEvents;

  @override
  State<PriceCheckerDeviceDetailsScreen> createState() =>
      _PriceCheckerDeviceDetailsScreenState();
}

class _PriceCheckerDeviceDetailsScreenState
    extends State<PriceCheckerDeviceDetailsScreen> {
  List<PriceCheckEvent> _events = const [];
  bool _isLoadingEvents = true;
  bool _hasEventsError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEvents());
  }

  Future<void> _loadEvents() async {
    setState(() {
      _isLoadingEvents = true;
      _hasEventsError = false;
    });
    final events = await widget.loadEvents(widget.device.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoadingEvents = false;
      if (events == null) {
        _hasEventsError = true;
      } else {
        _events = events;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final device = widget.device;

    return PointyScaffold(
      appBar: PointyAppBar(
        title: Text(device.displayName),
        isLoading: _isLoadingEvents,
      ),
      body: ListView(
        padding: spacing.pagePadding,
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHero(context, l10n, device),
                SizedBox(height: spacing.md),
                _buildConnectionCallout(context, l10n, device),
                SizedBox(height: spacing.md),
                _buildNetworkSection(context, l10n, device),
                SizedBox(height: spacing.md),
                _buildDisplaySection(context, l10n, device),
                SizedBox(height: spacing.md),
                _buildActivitySection(context, l10n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(
    BuildContext context,
    AppLocalizations l10n,
    PriceCheckerDevice device,
  ) {
    return PointyDetailHero(
      icon: priceCheckerTransportIcon(device),
      title: device.displayName,
      description: device.location.trim().isEmpty
          ? null
          : device.location.trim(),
      pills: [
        PointyHeroPill(
          label: priceCheckerStatusLabel(l10n, device),
          icon: priceCheckerStatusIcon(device),
        ),
        PointyHeroPill(
          label: priceCheckerTransportLabel(l10n, device),
          icon: priceCheckerTransportIcon(device),
        ),
        PointyHeroPill(
          label: priceCheckerDiscoveryLabel(l10n, device),
          icon: Icons.travel_explore_outlined,
        ),
      ],
    );
  }

  Widget _buildConnectionCallout(
    BuildContext context,
    AppLocalizations l10n,
    PriceCheckerDevice device,
  ) {
    final colors = context.pointyColors;
    final (PointyCalloutTone tone, String title) = switch (device.status) {
      PriceCheckerStatus.active => (
        PointyCalloutTone.success,
        l10n.priceCheckerConnectionServing,
      ),
      PriceCheckerStatus.discovered => (
        PointyCalloutTone.warning,
        l10n.priceCheckerConnectionDiscovered,
      ),
      PriceCheckerStatus.disabled => (
        PointyCalloutTone.neutral,
        l10n.priceCheckerConnectionDisabled,
      ),
      PriceCheckerStatus.unknown => (
        PointyCalloutTone.neutral,
        priceCheckerStatusLabel(l10n, device),
      ),
    };

    return PointyDetailCallout(
      icon: priceCheckerStatusIcon(device),
      title: title,
      message: device.lastSeenAt == null
          ? l10n.priceCheckerNeverSeen
          : l10n.priceCheckerLastSeen(formatDateTime(device.lastSeenAt!)),
      tone: tone,
      trailing: PointyStatusPill(
        label: priceCheckerStatusLabel(l10n, device),
        color: priceCheckerStatusColor(colors, device),
      ),
    );
  }

  Widget _buildNetworkSection(
    BuildContext context,
    AppLocalizations l10n,
    PriceCheckerDevice device,
  ) {
    final endpoint = device.endpointLabel;
    return PointyDetailSection(
      title: l10n.priceCheckerNetworkSection,
      icon: Icons.lan_outlined,
      child: PointyMetricGrid(
        minTileWidth: 200,
        maxColumns: 2,
        gap: PointyMetricGridGap.compact,
        metrics: [
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldIdentifier,
            value: device.identifier.isEmpty
                ? priceCheckerEmptyValue
                : device.identifier,
            icon: Icons.tag_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldTransport,
            value: priceCheckerTransportLabel(l10n, device),
            icon: priceCheckerTransportIcon(device),
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldAddress,
            value: endpoint.isEmpty ? priceCheckerEmptyValue : endpoint,
            icon: Icons.router_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldMac,
            value: device.macAddress.isEmpty
                ? priceCheckerEmptyValue
                : device.macAddress,
            icon: Icons.fingerprint_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldDriver,
            value: device.driver.isEmpty
                ? priceCheckerEmptyValue
                : device.driver,
            icon: Icons.memory_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldHardware,
            value: priceCheckerHardwareLabel(device),
            icon: Icons.devices_other_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldDiscovery,
            value: priceCheckerDiscoveryLabel(l10n, device),
            icon: Icons.travel_explore_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldLocation,
            value: device.location.trim().isEmpty
                ? priceCheckerEmptyValue
                : device.location.trim(),
            icon: Icons.place_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildDisplaySection(
    BuildContext context,
    AppLocalizations l10n,
    PriceCheckerDevice device,
  ) {
    return PointyDetailSection(
      title: l10n.priceCheckerDisplaySection,
      icon: Icons.monitor_outlined,
      child: PointyMetricGrid(
        minTileWidth: 170,
        maxColumns: 3,
        gap: PointyMetricGridGap.compact,
        metrics: [
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldDisplaySize,
            // Wrap in an LTR isolate (U+2066 … U+2069) so "5 × 20" keeps its
            // rows-before-cols order inside the RTL layout instead of flipping.
            value:
                '\u{2066}'
                '${l10n.priceCheckerDisplaySizeValue(device.displayRows, device.displayCols)}'
                '\u{2069}',
            icon: Icons.grid_on_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldArabic,
            value: priceCheckerArabicSupportLabel(l10n, device),
            icon: Icons.translate_outlined,
          ),
          PointyMetricGridItem(
            label: l10n.priceCheckerFieldEncoding,
            value: device.encoding.isEmpty
                ? priceCheckerEmptyValue
                : device.encoding,
            icon: Icons.code_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildActivitySection(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);

    final Widget child;
    if (_isLoadingEvents && _events.isEmpty) {
      child = const PointyLoadingArea(minHeight: 120);
    } else if (_hasEventsError) {
      child = PointyInlineMessage.error(
        message: l10n.priceCheckerActivityLoadError,
      );
    } else if (_events.isEmpty) {
      child = PointyInlineMessage(
        message: l10n.priceCheckerActivityEmpty,
        icon: Icons.history_outlined,
      );
    } else {
      child = Column(
        children: [
          for (var index = 0; index < _events.length; index++) ...[
            if (index > 0) Divider(height: spacing.lg),
            _ScanEventRow(event: _events[index]),
          ],
        ],
      );
    }

    return PointyDetailSection(
      title: l10n.priceCheckerActivitySection,
      icon: Icons.history_outlined,
      trailing: IconButton(
        tooltip: l10n.priceCheckerRefreshTooltip,
        onPressed: _isLoadingEvents ? null : _loadEvents,
        icon: const Icon(Icons.sync, size: 20),
      ),
      child: child,
    );
  }
}

class _ScanEventRow extends StatelessWidget {
  const _ScanEventRow({required this.event});

  final PriceCheckEvent event;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final resultColor = priceCheckResultColor(colors, event);

    final priceText = event.finalPrice == null
        ? ''
        : '${event.finalPrice} ${event.currency}'.trim();
    final subtitleParts = <String>[
      priceCheckResultLabel(l10n, event),
      if (event.productName.trim().isNotEmpty) event.productName.trim(),
      if (event.createdAt != null) formatDateTime(event.createdAt!),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(priceCheckResultIcon(event), color: resultColor, size: 20),
        SizedBox(width: spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event.barcode.isEmpty
                          ? priceCheckerEmptyValue
                          : ltrIsolated(event.barcode),
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (priceText.isNotEmpty) ...[
                    SizedBox(width: spacing.sm),
                    Text(
                      priceText,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.primaryStrong,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitleParts.join(' · '),
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
