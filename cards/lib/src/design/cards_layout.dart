import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'cards_tokens.dart';

/// How pages use a wide screen (a tablet, the iPhone Duo open): text, forms
/// and lists keep a comfortable reading width, centred, rather than running
/// edge to edge; pictures and shelves take the room.
abstract final class CardsLayout {
  /// The widest a column of text, settings or a form grows.
  static const double readable = 640;

  /// The widest the shelf grows: on a desktop's broad window its rows keep a
  /// size a person takes in at a glance, centred, as a store's pages do.
  static const double shelf = 1180;

  /// A window wide enough for a sidebar beside the page, as a desktop's.
  static bool desktop(Size size) => size.width >= 1024;

  /// A page wide enough to set a picture beside its details.
  static bool sideBySide(Size size) =>
      size.width >= 720 && size.width > size.height;

  /// Padding for a list [width] wide that keeps its content a centred column
  /// at most [readable] wide, and at least the page gutter from each side.
  static EdgeInsets column(
    double width, {
    double top = 0,
    double bottom = 0,
    double maxWidth = readable,
  }) {
    final side = math.max(CardsSpace.gutter, (width - maxWidth) / 2);
    return EdgeInsets.fromLTRB(side, top, side, bottom);
  }

  /// [column] for a page's own list, which the screen's side insets (a
  /// system column down one side, a notch) have not already been taken off:
  /// the column is centred between them.
  static EdgeInsets page(
    BuildContext context, {
    double top = 0,
    double bottom = 0,
    double maxWidth = readable,
  }) {
    final media = MediaQuery.of(context);
    final inner = column(
      media.size.width - media.padding.horizontal,
      top: top,
      bottom: bottom,
      maxWidth: maxWidth,
    );
    return inner.copyWith(
      left: inner.left + media.padding.left,
      right: inner.right + media.padding.right,
    );
  }
}
