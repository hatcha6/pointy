import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/business_alert.dart';
import '../../../shared/design/design.dart';
import '../view_models/notification_center_view_model.dart';

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, required this.viewModel});

  final NotificationCenterViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final count = viewModel.activeCount;
        final tooltip = count == 0
            ? l10n.smartNotificationsTooltip
            : l10n.smartNotificationsTooltipWithCount(count);

        return Builder(
          builder: (buttonContext) {
            return Semantics(
              button: true,
              label: tooltip,
              child: IconButton(
                tooltip: tooltip,
                onPressed: () => Scaffold.of(buttonContext).openEndDrawer(),
                icon: _BellIcon(
                  count: count,
                  severity: viewModel.highestActiveSeverity,
                  isLoading: viewModel.isLoading,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BellIcon extends StatelessWidget {
  const _BellIcon({
    required this.count,
    required this.severity,
    required this.isLoading,
  });

  final int count;
  final BusinessAlertSeverity? severity;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    if (isLoading && count == 0) {
      return const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : count.toString()),
      backgroundColor: _badgeColor(context),
      child: Icon(
        count > 0
            ? Icons.notifications_active_outlined
            : Icons.notifications_none_outlined,
      ),
    );
  }

  Color _badgeColor(BuildContext context) {
    final colors = context.pointyColors;
    return switch (severity) {
      BusinessAlertSeverity.critical => colors.danger,
      BusinessAlertSeverity.warning => colors.warning,
      BusinessAlertSeverity.info || null => colors.primaryStrong,
    };
  }
}
