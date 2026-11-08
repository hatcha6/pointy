import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../core/result.dart';
import '../api/relay_api.dart';
import '../models/campaign.dart';

/// Where the customer came from, carried to the relay without ever being
/// lost on the way.
///
/// A campaign's code arrives before there is anyone to credit it to: in the
/// link that opened the app (cards.dftr.ly/go/CODE, or ?c=CODE on the web),
/// in Google Play's install referrer on the first launch, or typed into the
/// question the first run asks. It waits on the phone ([pending], kept in
/// preferences, so a closed app or a failed sign-in keeps it) and rides on
/// the sign-in itself; only the relay's answer clears it. Signed in already,
/// it goes at once, and again at every launch until the relay has it.
///
/// A campaign with a reward puts credit in the new customer's balance:
/// [reward] holds it until the app has said so.
class AttributionRepository {
  AttributionRepository({
    required this.api,
    required this.isSignedIn,
    this.preferences,
    Analytics? analytics,
    Future<InstallReferrer> Function()? installReferrer,
  }) : analytics = analytics ?? NoAnalytics(),
       _installReferrer = installReferrer ?? _playInstallReferrer;

  final RelayApi api;
  final SharedPreferencesAsync? preferences;
  final Analytics analytics;
  final bool Function() isSignedIn;
  final Future<InstallReferrer> Function() _installReferrer;

  static const _pendingKey = 'cards.attribution.pending';
  static const _askedKey = 'cards.attribution.asked';
  static const _heardFromKey = 'cards.attribution.heard_from';
  static const _referrerKey = 'cards.attribution.referrer_read';

  PendingAttribution _pending = PendingAttribution.empty;

  /// What the relay has not taken yet.
  PendingAttribution get pending => _pending;

  String _heardFrom = '';

  /// The answer given on this phone. [pending]'s is cleared once the relay has
  /// it; this one stays, because analytics can only be told once the customer
  /// is known, and is told again at each launch in case sharing was off.
  String get heardFrom => _heardFrom;

  /// The offer behind a code the customer typed or followed, once checked.
  CampaignOffer? offer;

  bool _asked = false;

  /// Whether «من أين سمعت عنا؟» was answered or skipped on this phone.
  bool get asked => _asked;

  bool _newCustomer = false;

  /// The question is worth asking after this sign-in: a new customer who
  /// never saw it.
  bool get shouldAskAfterSignIn => _newCustomer && !_asked;

  /// Credit a campaign just gave, waiting to be shown.
  final ValueNotifier<CampaignReward?> reward = ValueNotifier(null);

  /// Called with the page a followed campaign link opens.
  void Function(String landing)? onLanding;

  Future<void>? _flushing;

  /// Reads what waits from the last run. On a first launch from Google
  /// Play, the campaign it was installed from follows, then whatever waits
  /// is sent (signed in).
  Future<void> load() async {
    try {
      final raw = await preferences?.getString(_pendingKey);
      if (raw != null && raw.isNotEmpty) {
        _pending = PendingAttribution.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
      _asked = await preferences?.getBool(_askedKey) ?? false;
      _heardFrom =
          await preferences?.getString(_heardFromKey) ?? _pending.heardFrom;
    } on Object {
      // Unreadable: nothing waits.
    }
    unawaited(_readInstallReferrer().whenComplete(flush));
  }

  /// A link opened the app or reached it: a campaign's code is taken from it
  /// (`/go/CODE`, or `?c=CODE` on any page).
  void openedLink(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final fromPath = segments.length == 2 && segments.first == 'go';
    final code = normalizeCampaignCode(
      fromPath ? segments[1] : uri.queryParameters['c'] ?? '',
    );
    if (!isCampaignCode(code)) {
      return;
    }
    _hold(code, kIsWeb ? 'web' : 'link');
    if (fromPath) {
      // The installed app opened the link itself, so the relay never saw
      // it: count it, and go where it points.
      unawaited(_openCampaign(code));
    }
  }

  Future<void> _openCampaign(String code) async {
    try {
      final answer = await api.post('/v1/customers/campaigns/$code/open');
      final found = CampaignOffer.fromJson(
        answer['campaign'] as Map<String, dynamic>? ?? const {},
      );
      offer = found;
      if (found.landing != '/') {
        onLanding?.call(found.landing);
      }
    } on RelayApiException {
      // An ended campaign, or offline: the code still waits for the relay.
    }
  }

  /// Checks a typed code. Unknown or ended is a [RelayApiException] with
  /// code `unknown_campaign`.
  Future<Result<CampaignOffer>> check(String typed) async {
    final code = normalizeCampaignCode(typed);
    final result = await Result.guard(() async {
      final answer = await api.get('/v1/customers/campaigns/$code');
      return CampaignOffer.fromJson(
        answer['campaign'] as Map<String, dynamic>? ?? const {},
      );
    });
    analytics.campaignCodeChecked(valid: result is Ok);
    return result;
  }

  /// The first run's question, answered: an answer, a checked code, or both.
  Future<void> answer({String heardFrom = '', CampaignOffer? code}) async {
    if (heardFrom.isNotEmpty && _pending.heardFrom.isEmpty) {
      _pending = _pending.copyWith(heardFrom: heardFrom);
      _save();
    }
    if (heardFrom.isNotEmpty && _heardFrom.isEmpty) {
      _heardFrom = heardFrom;
      preferences
          ?.setString(_heardFromKey, heardFrom)
          .catchError((Object _) {});
      if (isSignedIn()) {
        analytics.heardFrom(heardFrom);
      }
    }
    if (code != null) {
      offer = code;
      _hold(code.code, 'code', send: false);
    }
    analytics.attributionAnswered(heardFrom: heardFrom, hasCode: code != null);
    _markAsked();
    await flush();
  }

  /// The customer signed out: their answer is not the next customer's on
  /// this phone. One the relay has not taken yet still rides on a sign-in.
  void signedOut() {
    _heardFrom = _pending.heardFrom;
    final write = _heardFrom.isEmpty
        ? preferences?.remove(_heardFromKey)
        : preferences?.setString(_heardFromKey, _heardFrom);
    write?.catchError((Object _) {});
  }

  /// The question, skipped: not asked again.
  void skip() {
    analytics.attributionAnswered(heardFrom: '', hasCode: false);
    _markAsked();
  }

  /// What the sign-in carries, if anything waits.
  Map<String, String>? get forSignIn =>
      _pending.isEmpty ? null : _pending.toJson();

  /// The relay's answer to a sign-in: what it took is cleared, a reward
  /// waits to be shown.
  void signedIn(Map<String, dynamic> answer) {
    _newCustomer = answer['created'] == true;
    if (answer.containsKey('attribution')) {
      _took(answer);
    } else {
      // A relay that did not read it: send it on its own.
      unawaited(flush());
    }
  }

  /// Sends what waits, signed in. Safe to call any time; one at a time.
  Future<void> flush() =>
      _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    final sending = _pending;
    if (sending.isEmpty || !isSignedIn()) {
      return;
    }
    try {
      final answer = await api.put(
        '/v1/customers/me/attribution',
        body: sending.toJson(),
        signedIn: true,
      );
      _took(answer, sent: sending);
    } on RelayApiException catch (error) {
      // Offline or the relay is down: it waits for the next launch. A
      // refusal will never change: dropped, so nothing is stuck re-sending.
      if (!error.isNetwork && error.status < 500 && error.status != 401) {
        _clear(sending);
      }
    }
  }

  void _took(Map<String, dynamic> answer, {PendingAttribution? sent}) {
    _clear(sent ?? _pending);
    final given = answer['reward'];
    if (given is Map<String, dynamic>) {
      final credited = CampaignReward.fromJson(given);
      if (credited.amount.isPositive) {
        reward.value = credited;
      }
    }
  }

  int _holds = 0;

  /// A screen that must not be covered (the sign-in sheet) is up: rewards
  /// wait until it [release]s them.
  bool get holding => _holds > 0;

  void hold() => _holds++;

  void release() {
    _holds = _holds > 0 ? _holds - 1 : 0;
    final waiting = reward.value;
    if (!holding && waiting != null) {
      // Told again, now that it can be shown.
      reward.value = null;
      reward.value = waiting;
    }
  }

  /// The reward, now shown.
  void rewardShown() {
    final shown = reward.value;
    if (shown != null) {
      analytics.campaignRewardShown(shown);
    }
    reward.value = null;
  }

  void _hold(String code, String via, {bool send = true}) {
    // The first code named is the one the relay will keep, so it is the one
    // kept here too.
    if (_pending.code.isNotEmpty) {
      return;
    }
    _pending = _pending.copyWith(code: code, via: via);
    _save();
    if (send) {
      unawaited(flush());
    }
  }

  /// Forgets what was sent, unless something newer arrived meanwhile.
  void _clear(PendingAttribution sent) {
    _pending = PendingAttribution(
      code: _pending.code == sent.code ? '' : _pending.code,
      via: _pending.code == sent.code ? '' : _pending.via,
      heardFrom: _pending.heardFrom == sent.heardFrom ? '' : _pending.heardFrom,
    );
    _save();
  }

  void _markAsked() {
    _asked = true;
    preferences?.setBool(_askedKey, true).catchError((Object _) {});
  }

  void _save() {
    final write = _pending.isEmpty
        ? preferences?.remove(_pendingKey)
        : preferences?.setString(_pendingKey, jsonEncode(_pending.toJson()));
    write?.catchError((Object _) {});
  }

  /// Once per install: an Android phone installed from a campaign's Play
  /// link has its code in the referrer (utm_campaign=CODE). Asked at every
  /// launch until Play gives an answer that will not change: one it could
  /// not give now (Play busy, updating, or slow) is asked again next time.
  Future<void> _readInstallReferrer() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      if (await preferences?.getBool(_referrerKey) ?? false) {
        return;
      }
      final answer = await _installReferrer().timeout(
        _referrerPatience,
        onTimeout: () => const InstallReferrer.later(),
      );
      if (kDebugMode) {
        debugPrint(
          'install referrer: ${answer.settled ? 'settled' : 'later'} '
          '${answer.referrer}',
        );
      }
      if (!answer.settled) {
        return;
      }
      await preferences?.setBool(_referrerKey, true);
      final code = normalizeCampaignCode(
        Uri.splitQueryString(answer.referrer ?? '')['utm_campaign'] ?? '',
      );
      if (isCampaignCode(code)) {
        _hold(code, 'referrer');
      }
    } on Object {
      // No channel (a test, a background isolate) or an unreadable answer:
      // asked again next launch.
    }
  }

  /// How long the first launch waits for Play before trying again next time.
  static const _referrerPatience = Duration(seconds: 10);

  static const _install = MethodChannel('ly.dftr.cards/install');

  static Future<InstallReferrer> _playInstallReferrer() async {
    final answer = await _install.invokeMapMethod<String, Object?>('referrer');
    return switch (answer?['status']) {
      'ok' => InstallReferrer(answer?['referrer'] as String?),
      'none' => const InstallReferrer(null),
      _ => const InstallReferrer.later(),
    };
  }
}

/// What Google Play says about this install's link: [referrer] once it has
/// answered for good ([settled]), or nothing yet.
class InstallReferrer {
  const InstallReferrer(this.referrer) : settled = true;

  const InstallReferrer.later() : referrer = null, settled = false;

  final String? referrer;
  final bool settled;
}
