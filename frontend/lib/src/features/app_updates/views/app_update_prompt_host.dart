import 'package:flutter/material.dart';

import '../view_models/app_update_prompter.dart';
import 'app_update_dialog.dart';

/// Shows [prompter]'s offer over whichever screen is up, once it is a calm
/// moment to ask.
///
/// Sits above the Navigator, beside the other app-wide notifiers, so the offer
/// reaches every route; it opens the dialog through [navigatorKey]. "Calm" is
/// whatever [canPrompt] says — in the app: someone is signed in, the machine
/// is not a price-checker kiosk, and the till is not in the middle of a sale.
/// An offer that arrives mid-sale waits for the cart to clear rather than
/// landing on top of the customer at the counter.
class AppUpdatePromptHost extends StatefulWidget {
  const AppUpdatePromptHost({
    super.key,
    required this.prompter,
    required this.navigatorKey,
    required this.canPrompt,
    required this.promptConditions,
    required this.install,
    required this.child,
  });

  final AppUpdatePrompter prompter;
  final GlobalKey<NavigatorState> navigatorKey;
  final bool Function() canPrompt;

  /// Notifies whenever [canPrompt]'s answer may have changed.
  final Listenable promptConditions;
  final AppUpdateInstaller install;
  final Widget child;

  @override
  State<AppUpdatePromptHost> createState() => _AppUpdatePromptHostState();
}

class _AppUpdatePromptHostState extends State<AppUpdatePromptHost> {
  bool _showing = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.prompter.addListener(_maybeShow);
    widget.promptConditions.addListener(_maybeShow);
  }

  @override
  void didUpdateWidget(AppUpdatePromptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prompter != widget.prompter) {
      oldWidget.prompter.removeListener(_maybeShow);
      widget.prompter.addListener(_maybeShow);
    }
    if (oldWidget.promptConditions != widget.promptConditions) {
      oldWidget.promptConditions.removeListener(_maybeShow);
      widget.promptConditions.addListener(_maybeShow);
    }
  }

  @override
  void dispose() {
    widget.prompter.removeListener(_maybeShow);
    widget.promptConditions.removeListener(_maybeShow);
    super.dispose();
  }

  void _maybeShow() {
    // Cheap first: the conditions notify on every scan at the till.
    if (_showing ||
        _scheduled ||
        widget.prompter.offer == null ||
        !widget.canPrompt()) {
      return;
    }
    // Never open a route in the middle of someone else's build or notify.
    _scheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _scheduled = false;
        _showNow();
      })
      // An idle till may draw nothing for minutes; ask for the frame.
      ..ensureVisualUpdate();
  }

  Future<void> _showNow() async {
    if (!mounted || _showing || !widget.canPrompt()) {
      return;
    }
    final navigatorContext = widget.navigatorKey.currentContext;
    if (navigatorContext == null) {
      return;
    }
    final offer = widget.prompter.takeOffer();
    if (offer == null) {
      return;
    }
    _showing = true;
    try {
      await showAppUpdateDialog(
        navigatorContext,
        offer: offer,
        install: widget.install,
        onPostpone: widget.prompter.postpone,
      );
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
