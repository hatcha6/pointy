import 'package:flutter/foundation.dart';

import '../links/cards_link.dart';

/// The tab bar's way of asking the shelf to start over: the search cleared,
/// back to all categories, back to the top. A link starts it over on the
/// category, the offers or the search it names instead.
class HomeReset extends ChangeNotifier {
  /// Whether the shelf was already on screen: then it moves there visibly;
  /// arriving from another tab, it is simply already there.
  bool animate = false;

  /// Where to start over: the plain shelf when null.
  ShelfLink? target;

  void reset({required bool animate, ShelfLink? to}) {
    this.animate = animate;
    target = to;
    notifyListeners();
  }
}
