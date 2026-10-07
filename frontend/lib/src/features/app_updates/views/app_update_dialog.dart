import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/services/client_update_service.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/app_update_prompter.dart';
import 'app_update_dialog_views.dart';

/// Downloads [release] and hands it to the platform installer.
typedef AppUpdateInstaller =
    Future<void> Function(
      ClientRelease release,
      void Function(double progress) onProgress,
    );

/// Offers [offer] over the whole app. Resolves once the dialog is closed.
///
/// "Later" does not just close it: the dialog turns into a reminder of where
/// the update lives (device settings → app updates), because a postponed
/// build is not offered again on this machine.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateOffer offer,
  required AppUpdateInstaller install,
  required Future<void> Function(String version) onPostpone,
}) {
  return showDialog<void>(
    context: context,
    // A tap beside a small dialog is too easy to make by accident on a busy
    // counter; leaving goes through "later", so the reminder is never skipped.
    barrierDismissible: false,
    builder: (_) =>
        AppUpdateDialog(offer: offer, install: install, onPostpone: onPostpone),
  );
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.offer,
    required this.install,
    required this.onPostpone,
  });

  final AppUpdateOffer offer;
  final AppUpdateInstaller install;
  final Future<void> Function(String version) onPostpone;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _reminding = false;
  bool _installing = false;
  bool _failed = false;
  double _progress = 0;

  String get _newVersion => widget.offer.release.version;

  Future<void> _update() async {
    setState(() {
      _installing = true;
      _failed = false;
      _progress = 0;
    });
    try {
      await widget.install(widget.offer.release, (value) {
        // A chunk arrives every few kilobytes; repaint per whole percent, which
        // is all the panel can show, so a slow tablet spends nothing on it.
        if (mounted && (value * 100).floor() != (_progress * 100).floor()) {
          setState(() => _progress = value);
        }
      });
      // Android's installer now has the screen; Windows and Linux are about
      // to exit. Either way this dialog has done its job.
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (mounted) {
        setState(() {
          _installing = false;
          _failed = true;
        });
      }
    }
  }

  void _later() {
    if (_installing || _reminding) return;
    unawaited(widget.onPostpone(_newVersion));
    setState(() => _reminding = true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back / Escape means "later", so it shows the reminder first.
      canPop: _reminding,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _later();
      },
      child: AppUpdateDialogFrame(
        child: AnimatedSwitcher(
          duration: PointyMotion.standard,
          child: _reminding
              ? AppUpdateReminderView(
                  key: const ValueKey('reminder'),
                  version: _newVersion,
                  onDismiss: () => Navigator.of(context).pop(),
                )
              : AppUpdateOfferView(
                  key: const ValueKey('offer'),
                  offer: widget.offer,
                  installing: _installing,
                  failed: _failed,
                  progress: _progress,
                  onUpdate: _update,
                  onLater: _later,
                ),
        ),
      ),
    );
  }
}

/// The dialog's surface: compact, clipped to its rounded corners, and growing
/// smoothly as its content changes (the offer, the progress, the reminder).
class AppUpdateDialogFrame extends StatelessWidget {
  const AppUpdateDialogFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: PointyMotion.emphasized,
          curve: PointyMotion.curve,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
    );
  }
}
