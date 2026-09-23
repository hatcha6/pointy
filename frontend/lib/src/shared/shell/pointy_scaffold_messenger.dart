import 'package:flutter/material.dart';

/// The app's [ScaffoldMessenger]: every snackbar closes itself after
/// [snackBarDuration], whatever the screen that showed it asked for.
///
/// Snackbars are built inline all over the app and the theme has no duration
/// setting, so the one place every `showSnackBar` passes through is where the
/// rule lives. It covers snackbars with an action too: Flutter makes those
/// [SnackBar.persist] by default, so an undo or a print offer would otherwise
/// sit over the till until somebody tapped it.
class PointyScaffoldMessenger extends ScaffoldMessenger {
  const PointyScaffoldMessenger({super.key, required super.child});

  static const Duration snackBarDuration = Duration(seconds: 3);

  @override
  ScaffoldMessengerState createState() => _PointyScaffoldMessengerState();
}

class _PointyScaffoldMessengerState extends ScaffoldMessengerState {
  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    return super.showSnackBar(
      _timed(snackBar),
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
  }
}

/// [snackBar] on the app's timer. Copies the same fields as
/// [SnackBar.withAnimation]; keep the two in step on a Flutter upgrade.
SnackBar _timed(SnackBar snackBar) {
  return SnackBar(
    key: snackBar.key,
    content: snackBar.content,
    backgroundColor: snackBar.backgroundColor,
    elevation: snackBar.elevation,
    margin: snackBar.margin,
    padding: snackBar.padding,
    width: snackBar.width,
    shape: snackBar.shape,
    hitTestBehavior: snackBar.hitTestBehavior,
    behavior: snackBar.behavior,
    action: snackBar.action,
    actionOverflowThreshold: snackBar.actionOverflowThreshold,
    showCloseIcon: snackBar.showCloseIcon,
    closeIconColor: snackBar.closeIconColor,
    duration: PointyScaffoldMessenger.snackBarDuration,
    persist: false,
    animation: snackBar.animation,
    onVisible: snackBar.onVisible,
    dismissDirection: snackBar.dismissDirection,
    clipBehavior: snackBar.clipBehavior,
  );
}
