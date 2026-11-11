import 'package:flutter/widgets.dart';

import 'page_title_served.dart'
    if (dart.library.js_interop) 'page_title_served_web.dart';

/// The web build's tab title.
///
/// The relay sends each address with its own title («شحن ببجي موبايل في
/// ليبيا…»), which is what a search engine lists the page by. The app used to
/// replace it with its own name as it started, on every page. Now the page the
/// browser was opened on keeps the title it was served with for as long as it
/// is the page in front; any other page shows the app's name.
///
/// Off the web no title is served, so the app's name is always the answer.
class PageTitles extends ChangeNotifier implements NavigatorObserver {
  PageTitles({String? served, String? path})
    : _served = served ?? servedPageTitle(),
      _path = path ?? Uri.base.path,
      _front = path ?? Uri.base.path;

  /// The title the page came with; empty where none was served.
  final String _served;

  /// The address the browser was opened on.
  final String _path;

  /// The address of the page in front.
  String _front;

  bool get _onServedPage =>
      _served.isNotEmpty && Uri.parse(_front).path == _path;

  /// The title to show while the app is called [appTitle].
  String title(String appTitle) => _onServedPage ? _served : appTitle;

  void _show(String? location) {
    if (location == null) {
      // A sheet or a dialog: the page under it is still the page.
      return;
    }
    final before = _onServedPage;
    _front = location;
    if (_onServedPage != before) {
      // Routes change while the tree is being built: tell the app after.
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => notifyListeners())
        ..ensureVisualUpdate();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The shell itself is every address the tabs and the shelf answer to
    // (/category/…), so starting on it changes nothing.
    if (previousRoute != null) {
      _show(route.settings.name);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name != null) {
      _show(previousRoute?.settings.name ?? Navigator.defaultRouteName);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _show(newRoute?.settings.name);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {}

  @override
  void didChangeTop(
    Route<dynamic> topRoute,
    Route<dynamic>? previousTopRoute,
  ) {}

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {}

  @override
  void didStopUserGesture() {}

  @override
  NavigatorState? get navigator => null;
}
