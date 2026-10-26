import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'cards_link.dart';

/// Links waiting for the app to open them: the one the app was started
/// with, then any that arrive while it runs. The shell takes them once the
/// shelf can show them.
class LinkInbox extends ChangeNotifier {
  LinkInbox({CardsLink? initial, DateTime Function()? clock})
    : _pending = initial,
      _last = initial,
      _clock = clock ?? DateTime.now {
    if (initial != null) {
      _lastAt = _clock();
    }
  }

  final DateTime Function() _clock;
  CardsLink? _pending;
  CardsLink? _last;
  DateTime? _lastAt;

  CardsLink? get pending => _pending;

  void open(Uri uri) => deliver(CardsLink.parse(uri));

  void deliver(CardsLink link) {
    // A phone can report the link that started the app a second time as it
    // comes up: once is enough.
    final now = _clock();
    if (link == (_pending ?? _last) &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 2)) {
      return;
    }
    _pending = link;
    _last = link;
    _lastAt = now;
    notifyListeners();
  }

  /// The waiting link, now being opened.
  CardsLink? take() {
    final link = _pending;
    _pending = null;
    return link;
  }
}

/// Hands [inbox] the links the platform delivers: the one the app started
/// on (the tapped link on a phone, the page's address on the web), then any
/// that arrive while it runs. It sits above the app's navigator so it hears
/// them first: the navigator's own handling would look for a named route
/// and find none.
class LinkListener extends StatefulWidget {
  const LinkListener({super.key, required this.inbox, required this.child});

  final LinkInbox inbox;
  final Widget child;

  @override
  State<LinkListener> createState() => _LinkListenerState();
}

class _LinkListenerState extends State<LinkListener>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Read once the app runs: before, the web reports a plain `/`.
    final start = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    final uri = Uri.tryParse(start);
    if (uri != null && start != Navigator.defaultRouteName) {
      widget.inbox.open(uri);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    widget.inbox.open(routeInformation.uri);
    return SynchronousFuture(true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
