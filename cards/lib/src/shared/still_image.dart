import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// [child], drawn once into an image and reused, on the web.
///
/// For what is costly to draw and still while it is shown: a wide blur of a
/// card's art, say, that only fades or scrolls. A phone's engine keeps such a
/// picture between frames by itself; a browser keeps nothing, and would blur
/// it again at every frame of the fade or the scroll. The image is drawn
/// again only when [child] itself changes (its art arriving). Off the web it
/// is [child], untouched.
class StillImage extends StatefulWidget {
  const StillImage({super.key, required this.child, this.resolution = 1});

  final Widget child;

  /// The image's sharpness, as a share of the screen's: below 1 for what is
  /// blurred anyway, which then costs a fraction to draw (a quarter of the
  /// sharpness, a sixteenth of the pixels and a quarter of the blur's reach)
  /// and looks the same scaled up.
  final double resolution;

  @override
  State<StillImage> createState() => _StillImageState();
}

class _StillImageState extends State<StillImage> {
  final _controller = SnapshotController(allowSnapshotting: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return widget.child;
    }
    if (widget.resolution == 1) {
      return SnapshotWidget(controller: _controller, child: widget.child);
    }
    // The snapshot takes its sharpness from the screen's pixel ratio: it is
    // told a lower one, and [child] keeps the screen's own.
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        devicePixelRatio: media.devicePixelRatio * widget.resolution,
      ),
      child: SnapshotWidget(
        controller: _controller,
        child: MediaQuery(data: media, child: widget.child),
      ),
    );
  }
}
