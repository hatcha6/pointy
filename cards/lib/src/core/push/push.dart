import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../features/links/link_inbox.dart';
import '../analytics/analytics.dart';
import '../analytics/events.dart';
import 'firebase_options.dart';

/// Notifications: the company's messages (an offer, a new card on the
/// shelf), written in Firebase's console and sent to topics every phone
/// joins: `all`, and its build's channel (`ios`, `play`, `apk`). The App
/// Store build sells services only, so an offer on game cards goes to `play`
/// and `apk`, never `all`.
///
/// A message whose data carries `link` (a `https://cards.dftr.ly/…` address)
/// opens that place when tapped, as the link itself would; `campaign` names
/// the message in analytics.
///
/// The phone's own question is asked once, after the customer's first card
/// is revealed: by then a notification is worth something to them. The
/// account page has the switch.
class Push extends ChangeNotifier {
  Push();

  /// Shows what arrives while the app is open, where the phone would not.
  final GlobalKey<ScaffoldMessengerState> messenger = GlobalKey();

  /// Whether this build has notifications at all (not the web, not tests).
  bool get available => false;

  /// The customer's switch is on and the phone lets the app notify.
  bool get enabled => false;

  /// Starts listening: taps open their links in [links]. Asks nothing.
  Future<void> start(LinkInbox links) async {}

  /// Asks the phone, the first time only.
  Future<void> offer() async {}

  /// The customer's switch; false when the phone still will not allow it.
  Future<bool> setEnabled(bool on) async => false;

  /// This device's notification token, for the relay to reach this customer
  /// here; null where there is none (yet).
  Future<String?> deviceToken() async => null;

  /// A new token, when Firebase replaces this device's.
  Stream<String> get tokenChanges => const Stream.empty();
}

/// No notifications: the web build, tests and the preview harness.
class NoPush extends Push {}

/// Firebase Cloud Messaging, on the phone apps.
class FirebasePush extends Push {
  FirebasePush({
    required this.options,
    required this.channel,
    required this.analytics,
    this.preferences,
  });

  /// The phone apps' Firebase project, else nothing.
  static Push forPlatform({
    required String channel,
    required Analytics analytics,
    SharedPreferencesAsync? preferences,
  }) {
    final options = cardsFirebaseOptions();
    return options == null
        ? NoPush()
        : FirebasePush(
            options: options,
            channel: channel,
            analytics: analytics,
            preferences: preferences,
          );
  }

  final FirebaseOptions options;
  final String channel;
  final Analytics analytics;
  final SharedPreferencesAsync? preferences;

  static const _onKey = 'push.on';
  static const _askedKey = 'push.asked';

  LinkInbox? _links;
  final _ready = Completer<bool>();
  bool _on = true;
  bool _allowed = false;

  /// A phone app has notifications from the start; a Firebase that will not
  /// start leaves the switch unable to turn on.
  @override
  bool get available => true;

  @override
  bool get enabled => _on && _allowed;

  List<String> get _topics => ['all', channel];

  @override
  Future<void> start(LinkInbox links) async {
    _links = links;
    try {
      await Firebase.initializeApp(options: options);
      _on = await preferences?.getBool(_onKey) ?? true;
      final messaging = FirebaseMessaging.instance;
      // An iPhone shows a message that arrives while the app is open, too.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      FirebaseMessaging.onMessageOpenedApp.listen(_opened);
      FirebaseMessaging.onMessage.listen(_arrived);
      final first = await messaging.getInitialMessage();
      if (first != null) {
        _opened(first);
      }
      _allowed = _allows(await messaging.getNotificationSettings());
      _ready.complete(true);
      notifyListeners();
      if (enabled) {
        unawaited(_join());
      }
    } catch (error) {
      // Notifications never stand in the customer's way.
      debugPrint('Notifications did not start: $error');
      if (!_ready.isCompleted) {
        _ready.complete(false);
      }
    }
  }

  @override
  Future<String?> deviceToken() async {
    if (!await _ready.future || !enabled) {
      return null;
    }
    try {
      if (!await _apnsReady()) {
        return null;
      }
      // The registration token FCM's HTTP v1 API sends to. Its successor,
      // register(), answers with an installation id instead, which the
      // relay's sender does not address.
      // ignore: deprecated_member_use
      return await FirebaseMessaging.instance.getToken();
    } catch (error) {
      debugPrint('Notifications: no token: $error');
      return null;
    }
  }

  @override
  // Only once Firebase has started: before that, touching
  // FirebaseMessaging.instance throws, and at launch that stops the app on
  // its splash. See deviceToken for the deprecated call.
  Stream<String> get tokenChanges =>
      Stream.fromFuture(_ready.future).asyncExpand(
        (started) => started
            // ignore: deprecated_member_use
            ? FirebaseMessaging.instance.onTokenRefresh
            : const Stream<String>.empty(),
      );

  @override
  Future<void> offer() async {
    if (!await _ready.future ||
        _allowed ||
        await preferences?.getBool(_askedKey) == true) {
      return;
    }
    await _ask();
  }

  @override
  Future<bool> setEnabled(bool on) async {
    if (!await _ready.future) {
      return false;
    }
    _on = on;
    notifyListeners();
    await preferences?.setBool(_onKey, on);
    if (!on) {
      unawaited(_leave());
      return true;
    }
    return _allowed || await _ask();
  }

  Future<bool> _ask() async {
    await preferences?.setBool(_askedKey, true);
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      _allowed = _allows(settings);
      analytics.pushPermission(granted: _allowed);
      notifyListeners();
      if (enabled) {
        unawaited(_join());
      }
    } catch (error) {
      debugPrint('Notifications: $error');
    }
    return _allowed;
  }

  static bool _allows(NotificationSettings settings) =>
      settings.authorizationStatus == AuthorizationStatus.authorized ||
      settings.authorizationStatus == AuthorizationStatus.provisional;

  /// Joins the topics.
  Future<void> _join() async {
    final messaging = FirebaseMessaging.instance;
    try {
      if (!await _apnsReady()) {
        return;
      }
      for (final topic in _topics) {
        await messaging.subscribeToTopic(topic);
      }
    } catch (error) {
      debugPrint('Notifications: topics not joined: $error');
    }
  }

  /// An iPhone's APNs token, which Firebase needs first and which can come
  /// a moment after the permission does. Always ready elsewhere.
  Future<bool> _apnsReady() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }
    for (var tries = 0; tries < 10; tries++) {
      if (await FirebaseMessaging.instance.getAPNSToken() != null) {
        return true;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<void> _leave() async {
    try {
      for (final topic in _topics) {
        await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      }
    } catch (error) {
      debugPrint('Notifications: topics not left: $error');
    }
  }

  void _opened(RemoteMessage message) {
    final link = Uri.tryParse(message.data['link']?.toString() ?? '');
    analytics.pushOpened(
      link: link?.toString() ?? '',
      campaign: message.data['campaign']?.toString() ?? '',
    );
    if (link != null && link.hasAbsolutePath) {
      _links?.open(link);
    }
  }

  /// A message while the app is open: an iPhone shows it itself; Android
  /// leaves it to the app, which shows it along the bottom.
  void _arrived(RemoteMessage message) {
    final notification = message.notification;
    final state = messenger.currentState;
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        notification == null ||
        state == null) {
      return;
    }
    final l10n = AppLocalizations.of(state.context);
    final link = Uri.tryParse(message.data['link']?.toString() ?? '');
    state.showSnackBar(
      SnackBar(
        content: Text(
          [
            notification.title,
            notification.body,
          ].whereType<String>().where((s) => s.isNotEmpty).join('\n'),
        ),
        action: link == null || !link.hasAbsolutePath
            ? null
            : SnackBarAction(
                label: l10n.notificationOpenAction,
                onPressed: () => _opened(message),
              ),
      ),
    );
  }
}
