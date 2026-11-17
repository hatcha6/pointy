import 'package:flutter/foundation.dart';

import '../links/cards_link.dart';

/// The shell's way of asking the shelf to start over. A link starts it over
/// on the category, the offers or the search it names ([reset]); the tab
/// bar's Home takes the customer back ([home]).
class HomeReset extends ChangeNotifier {
  /// Whether the shelf was already on screen: then it moves there visibly;
  /// arriving from another tab, it is simply already there.
  bool animate = false;

  /// Where to start over: the plain shelf when null.
  ShelfLink? target;

  /// Whether it is the tab bar's Home that asks ([home]), not a link.
  bool back = false;

  void reset({required bool animate, ShelfLink? to}) {
    this.animate = animate;
    target = to;
    back = false;
    notifyListeners();
  }

  /// The tab bar's Home. From a category or a search it goes back to the
  /// whole shelf, where the customer was in it before; pressed again, with
  /// the whole shelf showing, it goes to the top. Coming from another tab,
  /// the whole shelf is simply shown as it was left.
  void home({required bool onScreen}) {
    animate = onScreen;
    target = null;
    back = true;
    notifyListeners();
  }
}
