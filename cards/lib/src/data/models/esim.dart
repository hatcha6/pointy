import '../../core/money.dart';
import 'json.dart';

/// Where eSIMs are sold: a country, a region, or the whole world.
enum EsimKind {
  local,
  regional,
  global;

  static EsimKind parse(String raw) => switch (raw) {
    'global' => EsimKind.global,
    'regional' => EsimKind.regional,
    _ => EsimKind.local,
  };
}

/// A promotion running on a destination's plans.
class EsimPromo {
  const EsimPromo({required this.badge, required this.percent, this.endsAt});

  /// Null when the relay sent none.
  static EsimPromo? read(Map<String, dynamic> json, String key) {
    final promo = readMap(json, key);
    if (promo.isEmpty) {
      return null;
    }
    return EsimPromo(
      badge: readString(promo, 'badge'),
      percent: readInt(promo, 'percent'),
      endsAt: readTime(promo, 'ends_at'),
    );
  }

  /// The operator's own words for it; empty when there are none.
  final String badge;
  final int percent;
  final DateTime? endsAt;
}

/// One of a destination's plans, as the shelf needs it to filter by a trip.
class EsimPlanBrief {
  const EsimPlanBrief({
    required this.mb,
    required this.days,
    required this.price,
    required this.unlimited,
  });

  factory EsimPlanBrief.fromJson(Map<String, dynamic> json) => EsimPlanBrief(
    mb: readInt(json, 'mb'),
    days: readInt(json, 'days'),
    price: Money.parse(readString(json, 'price')),
    unlimited: readBool(json, 'unlimited'),
  );

  final int mb;
  final int days;
  final Money price;
  final bool unlimited;
}

/// One row of the eSIM shelf.
class EsimDestinationRow {
  const EsimDestinationRow({
    required this.key,
    required this.kind,
    required this.country,
    required this.name,
    required this.image,
    required this.fromPrice,
    required this.plans,
    required this.countries,
    this.regularFromPrice,
    this.promo,
    this.planList = const [],
    this.covers = const [],
  });

  factory EsimDestinationRow.fromJson(Map<String, dynamic> json) =>
      EsimDestinationRow(
        regularFromPrice: json['regular_from_price'] == null
            ? null
            : Money.parse(readString(json, 'regular_from_price')),
        promo: EsimPromo.read(json, 'promo'),
        planList: [
          for (final p in readList(json, 'plan_list'))
            EsimPlanBrief.fromJson(p),
        ],
        covers: [
          for (final c in (json['covers'] as List? ?? const []))
            if (c is String) c,
        ],
        key: readString(json, 'key'),
        kind: EsimKind.parse(readString(json, 'kind')),
        country: readString(json, 'country'),
        name: readString(json, 'name'),
        image: readString(json, 'image'),
        fromPrice: Money.parse(readString(json, 'from_price')),
        plans: readInt(json, 'plans'),
        countries: readInt(json, 'countries'),
      );

  final String key;
  final EsimKind kind;
  final String country;
  final String name;
  final String image;
  final Money fromPrice;
  final int plans;
  final int countries;

  /// What the cheapest plan costs outside its promotion; null without one.
  final Money? regularFromPrice;
  final EsimPromo? promo;

  /// Every plan's size, days and price; empty from a relay that sends none.
  final List<EsimPlanBrief> planList;

  /// The countries a region reaches, by name: a search finds it by them.
  final List<String> covers;
}

/// The eSIM shelf as the relay shows it. [available] false: the app shows no
/// eSIMs at all.
class EsimShelf {
  const EsimShelf({
    required this.available,
    required this.testMode,
    required this.destinations,
  });

  factory EsimShelf.fromJson(Map<String, dynamic> json) => EsimShelf(
    available: readBool(json, 'available'),
    testMode: readBool(json, 'test_mode'),
    destinations: [
      for (final d in readList(json, 'destinations'))
        EsimDestinationRow.fromJson(d),
    ],
  );

  static const closed = EsimShelf(
    available: false,
    testMode: false,
    destinations: [],
  );

  final bool available;
  final bool testMode;
  final List<EsimDestinationRow> destinations;
}

/// A country a plan works in, and through whom.
class EsimCountry {
  const EsimCountry({
    required this.code,
    required this.name,
    required this.networks,
  });

  factory EsimCountry.fromJson(Map<String, dynamic> json) => EsimCountry(
    code: readString(json, 'code'),
    name: readString(json, 'name'),
    networks: [
      for (final n in (json['networks'] as List? ?? const []))
        if (n is String) n,
    ],
  );

  final String code;
  final String name;
  final List<String> networks;
}

/// A plan: a first eSIM, or a top-up of one.
class EsimPlan {
  const EsimPlan({
    required this.item,
    required this.title,
    required this.data,
    required this.amountMb,
    required this.days,
    required this.unlimited,
    required this.voice,
    required this.text,
    required this.info,
    required this.operator,
    required this.rechargeable,
    required this.activationPolicy,
    required this.installWindowDays,
    required this.topUpGraceDays,
    required this.otherInfo,
    required this.price,
    this.regularPrice,
    this.promo,
  });

  factory EsimPlan.fromJson(Map<String, dynamic> json) => EsimPlan(
    item: readString(json, 'item'),
    title: readString(json, 'title'),
    data: readString(json, 'data'),
    amountMb: readInt(json, 'amount_mb'),
    days: readInt(json, 'days'),
    unlimited: readBool(json, 'unlimited'),
    voice: readInt(json, 'voice'),
    text: readInt(json, 'text'),
    info: readString(json, 'info'),
    operator: readString(json, 'operator'),
    rechargeable: readBool(json, 'rechargeable'),
    activationPolicy: readString(json, 'activation_policy'),
    installWindowDays: readInt(json, 'install_window_days'),
    topUpGraceDays: readInt(json, 'topup_grace_days'),
    otherInfo: readString(json, 'other_info'),
    price: Money.parse(readString(json, 'price')),
    regularPrice: json['regular_price'] == null
        ? null
        : Money.parse(readString(json, 'regular_price')),
    promo: EsimPromo.read(json, 'promo'),
  );

  /// The order item that buys it.
  final String item;
  final String title;
  final String data;
  final int amountMb;
  final int days;
  final bool unlimited;
  final int voice;
  final int text;
  final String info;
  final String operator;
  final bool rechargeable;

  /// When the validity starts: "first-usage" or "installation".
  final String activationPolicy;

  /// An eSIM not installed in this time is gone; 0 when not said.
  final int installWindowDays;

  /// After the plan ends, how long a top-up can still revive it.
  final int topUpGraceDays;
  final String otherInfo;
  final Money price;

  /// The price outside a running promotion; null without one.
  final Money? regularPrice;
  final EsimPromo? promo;

  /// The plan's own id, as a link names it: the order item without its kind.
  String get id => item.startsWith('esim:') ? item.substring(5) : item;

  bool get startsOnFirstUse => activationPolicy.contains('first');
}

/// A destination's page.
class EsimDestination {
  const EsimDestination({
    required this.key,
    required this.kind,
    required this.country,
    required this.name,
    required this.image,
    required this.countries,
    required this.plans,
  });

  factory EsimDestination.fromJson(Map<String, dynamic> json) =>
      EsimDestination(
        key: readString(json, 'key'),
        kind: EsimKind.parse(readString(json, 'kind')),
        country: readString(json, 'country'),
        name: readString(json, 'name'),
        image: readString(json, 'image'),
        countries: [
          for (final c in readList(json, 'countries')) EsimCountry.fromJson(c),
        ],
        plans: [for (final p in readList(json, 'plans')) EsimPlan.fromJson(p)],
      );

  final String key;
  final EsimKind kind;
  final String country;
  final String name;
  final String image;
  final List<EsimCountry> countries;
  final List<EsimPlan> plans;
}

/// An eSIM's state, as its network reports it.
enum EsimStatus {
  notActive,
  active,
  finished,
  expired,
  unknown;

  static EsimStatus parse(String raw) => switch (raw) {
    'NOT_ACTIVE' => EsimStatus.notActive,
    'ACTIVE' => EsimStatus.active,
    'FINISHED' => EsimStatus.finished,
    'EXPIRED' => EsimStatus.expired,
    _ => EsimStatus.unknown,
  };
}

/// What is left on an eSIM, as last read.
class EsimUsage {
  const EsimUsage({
    required this.status,
    required this.remainingMb,
    required this.totalMb,
    this.expiresAt,
  });

  factory EsimUsage.fromJson(Map<String, dynamic> json) => EsimUsage(
    status: EsimStatus.parse(readString(json, 'status')),
    remainingMb: readInt(json, 'remaining_mb'),
    totalMb: readInt(json, 'total_mb'),
    expiresAt: readTime(json, 'expires_at'),
  );

  final EsimStatus status;
  final int remainingMb;
  final int totalMb;
  final DateTime? expiresAt;

  /// The share left, 0 to 1; null when the totals mean nothing.
  double? get left =>
      totalMb > 0 ? (remainingMb / totalMb).clamp(0.0, 1.0) : null;

  /// A quarter of the data or less is left.
  bool get dataLow {
    final share = left;
    return share != null && share <= 0.25;
  }

  /// Over: nothing is left to use.
  bool get over =>
      status == EsimStatus.finished || status == EsimStatus.expired;

  /// Whole days to the end, when known.
  int? daysLeft(DateTime now) {
    final end = expiresAt;
    if (end == null) {
      return null;
    }
    final hours = end.difference(now).inHours;
    return hours <= 0 ? 0 : (hours + 23) ~/ 24;
  }

  /// Running out: the moment to offer a top-up first.
  bool runningOut(DateTime now) {
    if (status == EsimStatus.finished || status == EsimStatus.expired) {
      return true;
    }
    if (status != EsimStatus.active) {
      return false;
    }
    final share = left;
    final days = daysLeft(now);
    return (share != null && share <= 0.25) || (days != null && days <= 3);
  }
}

/// How to install an eSIM. It installs the eSIM: never logged, never in
/// analytics, and kept only as long as the page is open.
class EsimInstall {
  const EsimInstall({
    required this.qr,
    required this.smdp,
    required this.activationCode,
    required this.confirmationCode,
    required this.appleUrl,
    required this.androidUrl,
    required this.roaming,
    required this.androidApnType,
    required this.androidApnValue,
    required this.iosApnType,
    required this.iosApnValue,
    required this.shareLink,
    required this.shareCode,
    required this.recycled,
  });

  factory EsimInstall.fromJson(Map<String, dynamic> json) => EsimInstall(
    qr: readString(json, 'qr'),
    smdp: readString(json, 'smdp'),
    activationCode: readString(json, 'activation_code'),
    confirmationCode: readString(json, 'confirmation_code'),
    appleUrl: readString(json, 'apple_url'),
    androidUrl: readString(json, 'android_url'),
    roaming: readBool(json, 'roaming'),
    androidApnType: readString(json, 'android_apn_type'),
    androidApnValue: readString(json, 'android_apn_value'),
    iosApnType: readString(json, 'ios_apn_type'),
    iosApnValue: readString(json, 'ios_apn_value'),
    shareLink: readString(json, 'share_link'),
    shareCode: readString(json, 'share_code'),
    recycled: readBool(json, 'recycled'),
  );

  final String qr;
  final String smdp;
  final String activationCode;
  final String confirmationCode;
  final String appleUrl;
  final String androidUrl;
  final bool roaming;
  final String androidApnType;
  final String androidApnValue;
  final String iosApnType;
  final String iosApnValue;
  final String shareLink;
  final String shareCode;
  final bool recycled;
}

/// An eSIM the customer bought.
class CustomerEsim {
  const CustomerEsim({
    required this.iccid,
    required this.orderId,
    required this.title,
    required this.data,
    required this.days,
    required this.operator,
    required this.destination,
    required this.destinationName,
    required this.country,
    required this.image,
    required this.unlimited,
    required this.rechargeable,
    required this.label,
    required this.gift,
    required this.testMode,
    required this.usage,
    required this.createdAt,
    this.install,
  });

  factory CustomerEsim.fromJson(Map<String, dynamic> json) => CustomerEsim(
    iccid: readString(json, 'iccid'),
    orderId: readString(json, 'order_id'),
    title: readString(json, 'title'),
    data: readString(json, 'data'),
    days: readInt(json, 'days'),
    operator: readString(json, 'operator'),
    destination: readString(json, 'destination'),
    destinationName: readString(json, 'destination_name'),
    country: readString(json, 'country'),
    image: readString(json, 'image'),
    unlimited: readBool(json, 'unlimited'),
    rechargeable: readBool(json, 'rechargeable'),
    label: readString(json, 'label'),
    gift: readBool(json, 'gift'),
    testMode: readBool(json, 'test_mode'),
    usage: EsimUsage.fromJson(readMap(json, 'usage')),
    createdAt: readTime(json, 'created_at') ?? DateTime.now(),
    install: json['install'] is Map<String, dynamic>
        ? EsimInstall.fromJson(json['install'] as Map<String, dynamic>)
        : null,
  );

  final String iccid;
  final String orderId;
  final String title;
  final String data;
  final int days;
  final String operator;
  final String destination;
  final String destinationName;

  /// Its flag's ISO code; empty for a region or the world.
  final String country;
  final String image;
  final bool unlimited;
  final bool rechargeable;

  /// Who it is for, in the buyer's words.
  final String label;

  /// Bought for someone else's phone.
  final bool gift;
  final bool testMode;
  final EsimUsage usage;
  final DateTime createdAt;

  /// Only on a read of the one eSIM.
  final EsimInstall? install;

  /// Over for good: nothing can be done with it.
  bool get ended => usage.status == EsimStatus.expired;
}

/// A top-up's order, or an eSIM's: the keys the relay gives its order items.
abstract final class EsimItems {
  static bool isEsim(String itemKey) =>
      itemKey.startsWith('esim:') || itemKey.startsWith('esim-topup:');

  /// The ICCID a top-up is for; null for a new eSIM.
  static String? topUpIccid(String itemKey) {
    if (!itemKey.startsWith('esim-topup:')) {
      return null;
    }
    final parts = itemKey.split(':');
    return parts.length >= 3 ? parts[1] : null;
  }
}
