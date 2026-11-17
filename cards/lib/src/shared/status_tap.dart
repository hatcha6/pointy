import 'package:flutter/widgets.dart';

/// A tap on the iPhone's status bar scrolls a page to its top. The system
/// tells the page's `Scaffold`, which scrolls the route's own scroll
/// controller: a page that scrolls with a controller of its own never hears
/// of it. Around such a page's `Scaffold`, this names [controller] as the one
/// the tap scrolls.
///
/// Nothing under it takes [controller] up by itself: the page's other
/// scroll views keep their own.
class StatusTapScrolls extends StatelessWidget {
  const StatusTapScrolls({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => PrimaryScrollController(
    controller: controller,
    automaticallyInheritForPlatforms: const {},
    child: child,
  );
}
