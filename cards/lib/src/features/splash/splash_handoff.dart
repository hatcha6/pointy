import 'package:flutter/widgets.dart';

/// Lets a screen under the opening take its tile: the screen names where
/// the tile should land and what it looks like there, the opening flies it
/// there instead of fading it, and says when it has landed so the screen
/// can carry on from that very picture. The onboarding's first step does
/// this; with no taker, the opening ends as it always has.
class SplashHandoff extends ChangeNotifier {
  GlobalKey? _target;
  CustomPainter Function()? _painter;
  bool _landed = false;

  /// The box the tile lands on (square), when a screen is waiting for it.
  GlobalKey? get target => _target;

  /// The landing box's own picture, drawn on the tile in flight so it grows
  /// crisp and arrives identical.
  CustomPainter Function()? get painter => _painter;

  /// Whether the opening is over: a screen that waits for the tile starts
  /// when this turns true.
  bool get landed => _landed;

  void claim(GlobalKey target, CustomPainter Function() painter) {
    _target = target;
    _painter = painter;
  }

  void release(GlobalKey target) {
    if (_target == target) {
      _target = null;
      _painter = null;
    }
  }

  void land() {
    if (_landed) {
      return;
    }
    _landed = true;
    notifyListeners();
  }
}

/// Hands the opening's [SplashHandoff] to the screens under it.
class SplashHandoffScope extends InheritedWidget {
  const SplashHandoffScope({
    super.key,
    required this.handoff,
    required super.child,
  });

  final SplashHandoff handoff;

  static SplashHandoff? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SplashHandoffScope>()?.handoff;

  @override
  bool updateShouldNotify(SplashHandoffScope oldWidget) =>
      oldWidget.handoff != handoff;
}
