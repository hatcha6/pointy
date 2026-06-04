import 'package:flutter/material.dart';

import '../../../data/models/business_alert.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/notification_center_view_model.dart';
import 'notification_bell.dart';
import 'notification_center_drawer.dart';

class NotificationCenterHost extends StatefulWidget {
  const NotificationCenterHost({
    super.key,
    required this.viewModel,
    required this.child,
    this.onOpenAlert,
  });

  final NotificationCenterViewModel viewModel;
  final Widget child;
  final Future<void> Function(BuildContext context, BusinessAlert alert)?
  onOpenAlert;

  @override
  State<NotificationCenterHost> createState() => _NotificationCenterHostState();
}

class _NotificationCenterHostState extends State<NotificationCenterHost> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.loadAlerts();
  }

  @override
  void didUpdateWidget(NotificationCenterHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) {
      widget.viewModel.loadAlerts();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PointyShellActionScope(
      appBarActionsBuilder: (context) {
        return [NotificationBell(viewModel: widget.viewModel)];
      },
      endDrawerBuilder: (context) {
        return NotificationCenterDrawer(
          viewModel: widget.viewModel,
          onOpenAlert: widget.onOpenAlert,
        );
      },
      child: widget.child,
    );
  }
}
