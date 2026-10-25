import 'package:flutter/foundation.dart';

/// The tab bar's way of asking the shelf to start over: the search cleared,
/// back to all categories, back to the top.
class HomeReset extends ChangeNotifier {
  /// Whether the shelf was already on screen: then it moves there visibly;
  /// arriving from another tab, it is simply already there.
  bool animate = false;

  void reset({required bool animate}) {
    this.animate = animate;
    notifyListeners();
  }
}
