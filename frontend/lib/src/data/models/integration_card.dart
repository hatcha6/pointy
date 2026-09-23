/// The till-facing half of `apps.integrations`: a subscriber's card, what can
/// be bought for it today, and what has been bought for it before.
///
/// Prices live in [IntegrationOffer.cost] and are quoted per lookup, never
/// cached. The same HD Box card in the field paid 210.00 for twelve months in
/// 2024 and 220.00 in 2026 — a remembered ladder books a sale at a cost the
/// shop did not pay.
library;

import 'integration_provider.dart';

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int _toInt(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _toDate(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

/// How closely a card is to running out — the thing a cashier reads first.
enum IntegrationCardHealth { active, expiringSoon, expired, locked, unknown }

class IntegrationCardInfo {
  const IntegrationCardInfo({
    required this.cardNo,
    this.status = '',
    this.statusId,
    this.startAt,
    this.expireAt,
    this.packageName = '',
    this.providerId = '',
    this.holderName = '',
    this.cardBalance,
  });

  /// What the provider's write path is keyed on — and so what a cart line
  /// carries: HD Box's card number, LNET's username.
  final String cardNo;

  /// The provider's own id for the line, when it differs from [cardNo].
  final String providerId;

  /// Who the line is registered to, where the provider will say.
  final String holderName;

  /// The subscriber's own credit with the provider — money already on the
  /// line or card. Not the agency float, which is the shop's. Null when the
  /// provider did not say, which is not the same as zero.
  final double? cardBalance;

  /// The provider's own wording ("On hold", "Active"). Shown verbatim next to
  /// our own reading of it, because the cashier may be asked to repeat it.
  final String status;
  final int? statusId;
  final DateTime? startAt;
  final DateTime? expireAt;
  final String packageName;

  /// Days until expiry; negative once it has passed. Null when unknown.
  int? daysRemaining({DateTime? now}) {
    final expiry = expireAt;
    if (expiry == null) return null;
    final today = now ?? DateTime.now();
    return expiry.difference(today).inDays;
  }

  /// HD Box status ids: 1/3 activatable, 4 locked, 5 inactive, 6/9 on hold.
  ///
  /// LNET has no numeric id and says it in words instead, so the word is read
  /// when there is no id — otherwise every LNET line would be judged purely on
  /// its expiry date and a suspended one would read as healthy.
  IntegrationCardHealth health({DateTime? now}) {
    if (statusId == 4) return IntegrationCardHealth.locked;
    if (statusId == 6 || statusId == 9 || statusId == 5) {
      return IntegrationCardHealth.expired;
    }
    if (statusId == null) {
      final word = status.trim().toLowerCase();
      if (word == 'suspended' || word == 'locked') {
        return IntegrationCardHealth.locked;
      }
      if (word == 'expired' || word == 'inactive' || word == 'disabled') {
        return IntegrationCardHealth.expired;
      }
    }
    final days = daysRemaining(now: now);
    if (days == null) return IntegrationCardHealth.unknown;
    if (days < 0) return IntegrationCardHealth.expired;
    if (days <= 14) return IntegrationCardHealth.expiringSoon;
    return IntegrationCardHealth.active;
  }

  factory IntegrationCardInfo.fromJson(Map<String, Object?> json) {
    return IntegrationCardInfo(
      cardNo: json['card_no']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      statusId: json['status_id'] == null ? null : _toInt(json['status_id']),
      startAt: _toDate(json['start_at']),
      expireAt: _toDate(json['expire_at']),
      packageName: json['package_name']?.toString() ?? '',
      providerId: json['provider_id']?.toString() ?? '',
      holderName: json['holder_name']?.toString() ?? '',
      cardBalance: _toDouble(json['card_balance']),
    );
  }
}

/// Something that can be bought for a card, at the price quoted right now.
class IntegrationOffer {
  const IntegrationOffer({
    required this.code,
    required this.kind,
    required this.label,
    required this.cost,
    required this.price,
    this.months = 0,
    this.packageId = '',
    this.packageName = '',
    this.faceValue,
  });

  /// Stable within one lookup, e.g. `renew:12`.
  final String code;

  /// `renew` — more time on the package the card already has. Package switches
  /// are not offered: the provider hides them and a mis-tap would break a
  /// subscriber's card.
  ///
  /// `topup` — money onto a stored-value line, in an amount the customer
  /// chooses. These carry no [months]; do not print one for them.
  final String kind;

  /// The provider's own wording, e.g. "12 month 220.00$".
  final String label;

  /// What the shop's float pays, in LYD.
  final double cost;

  /// What the customer pays: [cost] plus the shop's configured markup, worked
  /// out server-side. The till shows this; [cost] is the shop's own business.
  final double price;

  /// What the provider says this is worth, when the provider — not the shop —
  /// decides: the face value of stored value. 45 dinars of credit sells for
  /// 45, and the shop's income is the agency commission already inside [cost].
  /// Null when the shop's markup is what sets the price.
  final double? faceValue;

  double get margin => price - cost;
  final int months;
  final String packageId;
  final String packageName;

  bool get isRenewal => kind == 'renew';
  bool get isTopUp => kind == 'topup';

  factory IntegrationOffer.fromJson(Map<String, Object?> json) {
    return IntegrationOffer(
      code: json['code']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      cost: _toDouble(json['cost']) ?? 0,
      price: _toDouble(json['price']) ?? _toDouble(json['cost']) ?? 0,
      months: _toInt(json['months']),
      packageId: json['package_id']?.toString() ?? '',
      packageName: json['package_name']?.toString() ?? '',
      faceValue: _toDouble(json['face_value']),
    );
  }
}

/// A provider that will take any amount, not just the ones it listed.
///
/// When this is present the offers beside it are quick-pick buttons rather
/// than the menu, and the till owes the cashier somewhere to type an amount —
/// without one it would be strictly less capable than the provider's own
/// portal, which is a poor reason to adopt Pointy.
class IntegrationOpenAmount {
  const IntegrationOpenAmount({
    this.minimum = 1,
    this.maximum,
    this.step = 1,
    this.costRatio = 1,
    this.pricePerUnit = 1,
    this.priceFixed = 0,
  });

  final double minimum;
  final double? maximum;

  /// Amounts must be a whole multiple of this.
  final double step;

  /// What the float pays per dinar of face value — 0.95 for a 5% commission.
  final double costRatio;

  /// Together these are the shop's pricing rule for an amount nobody quoted:
  /// `price = max(face, amount * pricePerUnit + priceFixed)`. The server sends
  /// them already worked out so the till evaluates its rule rather than
  /// keeping a second copy of it that can drift.
  final double pricePerUnit;
  final double priceFixed;

  double costOf(double amount) => _money(amount * costRatio);

  /// What the customer pays for [amount] of face value. Never below face: the
  /// shop's income is the commission inside [costOf], and selling stored value
  /// under its face value loses money on every sale by construction.
  double priceOf(double amount) {
    final marked = _money(amount * pricePerUnit + priceFixed);
    return marked > amount ? marked : _money(amount);
  }

  static double _money(double value) =>
      double.parse(value.toStringAsFixed(2));

  /// `null` when [amount] is sellable, else which rule it broke.
  IntegrationAmountProblem? validate(double amount) {
    if (amount <= 0) return IntegrationAmountProblem.notPositive;
    if (amount < minimum) return IntegrationAmountProblem.belowMinimum;
    final ceiling = maximum;
    if (ceiling != null && amount > ceiling) {
      return IntegrationAmountProblem.aboveMaximum;
    }
    if (step > 0) {
      // Compare in whole steps to keep binary floating point out of it:
      // 45.5 % 1 is not reliably 0.5 once it has been through a double.
      final steps = amount / step;
      if ((steps - steps.roundToDouble()).abs() > 1e-9) {
        return IntegrationAmountProblem.notAMultiple;
      }
    }
    return null;
  }

  factory IntegrationOpenAmount.fromJson(Map<String, Object?> json) {
    return IntegrationOpenAmount(
      minimum: _toDouble(json['minimum']) ?? 1,
      maximum: _toDouble(json['maximum']),
      step: _toDouble(json['step']) ?? 1,
      costRatio: _toDouble(json['cost_ratio']) ?? 1,
      pricePerUnit:
          _toDouble(json['price_per_unit']) ?? _toDouble(json['cost_ratio']) ?? 1,
      priceFixed: _toDouble(json['price_fixed']) ?? 0,
    );
  }
}

extension IntegrationOpenAmountOffer on IntegrationOpenAmount {
  /// Turn a typed amount into an ordinary [IntegrationOffer].
  ///
  /// The code carries the amount (`topup:45`) exactly as a quick-pick's does,
  /// so the cart, the fulfillment and the driver all see one kind of thing and
  /// none of them needs a special case for "the cashier typed it".
  IntegrationOffer offerFor(double amount, {String packageName = ''}) {
    final whole = amount == amount.roundToDouble()
        ? amount.toStringAsFixed(0)
        : amount.toString();
    return IntegrationOffer(
      code: 'topup:$whole',
      kind: 'topup',
      label: '$whole LYD',
      cost: costOf(amount),
      price: priceOf(amount),
      faceValue: amount,
      packageName: packageName,
    );
  }
}

enum IntegrationAmountProblem {
  notPositive,
  belowMinimum,
  aboveMaximum,
  notAMultiple,
}

/// Everything one lookup returns — one round trip, because a customer is
/// standing at the counter while it runs.
/// The catalog product a recharge from this provider is rung up as.
class IntegrationServiceVariant {
  const IntegrationServiceVariant({
    required this.id,
    required this.productId,
    this.sku = '',
    this.name = '',
  });

  final int id;
  final int productId;
  final String sku;
  final String name;

  factory IntegrationServiceVariant.fromJson(Map<String, Object?> json) {
    return IntegrationServiceVariant(
      id: _toInt(json['id']),
      productId: _toInt(json['product_id']),
      sku: json['sku']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
    );
  }
}

class IntegrationCardSnapshot {
  const IntegrationCardSnapshot({
    required this.card,
    required this.offers,
    required this.serviceVariant,
    this.subscriber,
    this.currency = 'LYD',
    this.balance,
    this.offersErrorCode = '',
    this.openAmount,
    this.candidates = const [],
    this.needsSelection = false,
    this.historyKinds = const ['purchases', 'statuses'],
  });

  final IntegrationCardInfo card;
  final List<IntegrationOffer> offers;

  /// Set when the provider takes any amount and [offers] are only shortcuts.
  final IntegrationOpenAmount? openAmount;

  /// Every line the search matched. One phone number can hold several — a
  /// live one beside an expired one is ordinary — so when [needsSelection] is
  /// true nothing has been priced yet and the cashier must choose first.
  /// Guessing would top up somebody's dead second line and leave the one they
  /// came in about still expired.
  final List<IntegrationCardInfo> candidates;
  final bool needsSelection;

  /// Which history feeds this provider can answer. LNET keeps no state log,
  /// and a tab that always errors reads to a cashier as the provider being
  /// down — so the till offers only what is really there.
  final List<String> historyKinds;

  bool get hasStatusHistory => historyKinds.contains('statuses');

  /// The catalog variant a cart line for this provider must point at.
  final IntegrationServiceVariant serviceVariant;

  /// Who this card belongs to, as far as Pointy knows. The provider will not
  /// say — HD Box masks the name — so this is the shop's own record.
  final IntegrationSubscriber? subscriber;
  final String currency;

  /// The agency float as of the last probe — so a cashier can see before
  /// selling that there is not enough left to perform it.
  final double? balance;

  /// Set when the card was found but its price ladder could not be read.
  final String offersErrorCode;

  bool get hasOffers => offers.isNotEmpty;

  /// True when the cashier may type any amount rather than only tap one.
  bool get allowsOpenAmount => openAmount != null;

  factory IntegrationCardSnapshot.fromJson(Map<String, Object?> json) {
    final offers = (json['offers'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(IntegrationOffer.fromJson)
        .toList(growable: false);
    final candidates = (json['candidates'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(IntegrationCardInfo.fromJson)
        .toList(growable: false);
    return IntegrationCardSnapshot(
      candidates: candidates,
      needsSelection: json['needs_selection'] == true,
      historyKinds: switch (json['history_kinds']) {
        final List<Object?> kinds when kinds.isNotEmpty =>
          kinds.map((k) => k.toString()).toList(growable: false),
        // An older backend says nothing; it only had providers with both.
        _ => const ['purchases', 'statuses'],
      },
      openAmount: switch (json['open_amount']) {
        final Map<String, Object?> row => IntegrationOpenAmount.fromJson(row),
        _ => null,
      },
      card: IntegrationCardInfo.fromJson(
        (json['card'] as Map<String, Object?>?) ?? const {},
      ),
      offers: offers,
      serviceVariant: IntegrationServiceVariant.fromJson(
        (json['service_variant'] as Map<String, Object?>?) ?? const {},
      ),
      subscriber: switch (json['subscriber']) {
        final Map<String, Object?> row => IntegrationSubscriber.fromJson(row),
        _ => null,
      },
      currency: json['currency']?.toString() ?? 'LYD',
      balance: _toDouble(json['balance']),
      offersErrorCode: json['offers_error_code']?.toString() ?? '',
    );
  }
}

/// One past top-up, as the provider recorded it.
class IntegrationPurchaseEntry {
  const IntegrationPurchaseEntry({
    this.reference = '',
    this.cost,
    this.months = 0,
    this.at,
    this.packageName = '',
    this.operatorName = '',
    this.isOurs = false,
  });

  final String reference;
  final double? cost;
  final int months;
  final DateTime? at;
  final String packageName;

  /// The agency that sold it — often not this shop.
  final String operatorName;

  /// Whether this shop's own account sold it. The reason the log is worth
  /// showing at a till: everything else on the list went to a competitor.
  final bool isOurs;

  factory IntegrationPurchaseEntry.fromJson(Map<String, Object?> json) {
    return IntegrationPurchaseEntry(
      reference: json['reference']?.toString() ?? '',
      cost: _toDouble(json['cost']),
      months: _toInt(json['months']),
      at: _toDate(json['at']),
      packageName: json['package_name']?.toString() ?? '',
      operatorName: json['operator_name']?.toString() ?? '',
      isOurs: json['is_ours'] == true,
    );
  }
}

/// One state change of a card.
class IntegrationStatusEntry {
  const IntegrationStatusEntry({
    this.fromStatus = '',
    this.toStatus = '',
    this.operatorName = '',
    this.action = '',
    this.at,
  });

  final String fromStatus;
  final String toStatus;
  final String operatorName;
  final String action;
  final DateTime? at;

  /// The provider's scheduler, not a person.
  bool get isAutomatic => operatorName.toLowerCase() == 'system';

  factory IntegrationStatusEntry.fromJson(Map<String, Object?> json) {
    return IntegrationStatusEntry(
      fromStatus: json['from_status']?.toString() ?? '',
      toStatus: json['to_status']?.toString() ?? '',
      operatorName: json['operator_name']?.toString() ?? '',
      action: json['action']?.toString() ?? '',
      at: _toDate(json['at']),
    );
  }
}

enum IntegrationHistoryKind { purchases, statuses }

/// One page of history. [total] is the provider's count, not the page length.
class IntegrationHistoryPage {
  const IntegrationHistoryPage({
    required this.ok,
    required this.kind,
    this.total = 0,
    this.limit = 10,
    this.offset = 0,
    this.purchases = const [],
    this.statuses = const [],
    this.errorCode = '',
  });

  final bool ok;
  final IntegrationHistoryKind kind;
  final int total;
  final int limit;
  final int offset;
  final List<IntegrationPurchaseEntry> purchases;
  final List<IntegrationStatusEntry> statuses;
  final String errorCode;

  int get length => kind == IntegrationHistoryKind.purchases
      ? purchases.length
      : statuses.length;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + limit < total;
  int get pageNumber => limit <= 0 ? 1 : (offset ~/ limit) + 1;
  int get pageCount =>
      limit <= 0 ? 1 : ((total + limit - 1) ~/ limit).clamp(1, 9999);

  factory IntegrationHistoryPage.fromJson(Map<String, Object?> json) {
    final kind = json['kind']?.toString() == 'statuses'
        ? IntegrationHistoryKind.statuses
        : IntegrationHistoryKind.purchases;
    final entries = (json['entries'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .toList(growable: false);
    return IntegrationHistoryPage(
      ok: json['ok'] == true,
      kind: kind,
      total: _toInt(json['total']),
      limit: _toInt(json['limit']),
      offset: _toInt(json['offset']),
      purchases: kind == IntegrationHistoryKind.purchases
          ? entries
                .map(IntegrationPurchaseEntry.fromJson)
                .toList(growable: false)
          : const [],
      statuses: kind == IntegrationHistoryKind.statuses
          ? entries.map(IntegrationStatusEntry.fromJson).toList(growable: false)
          : const [],
      errorCode: json['error_code']?.toString() ?? '',
    );
  }
}

/// A top-up the cashier has chosen, on its way into the cart.
///
/// Carries both numbers deliberately: [cost] is what the provider will draw
/// from the float, [price] is what the customer pays. Keeping them apart is
/// what makes the margin on a recharge real rather than assumed, and it is
/// what lands in `OrderLine.unit_cost` versus `unit_price`.
class IntegrationRechargeDraft {
  const IntegrationRechargeDraft({
    required this.provider,
    required this.serviceVariant,
    required this.subscriberRef,
    required this.offer,
    required this.price,
  });

  final IntegrationProviderKey provider;
  final IntegrationServiceVariant serviceVariant;
  final String subscriberRef;
  final IntegrationOffer offer;

  /// What the customer pays, as quoted by the server for this shop's markup.
  /// Sent for display only — apps.sales recomputes it at checkout and never
  /// trusts a price that came from a till.
  final double price;

  double get cost => offer.cost;
  double get margin => price - cost;

  Map<String, Object?> toJson() => {
    'provider': integrationProviderKeyToJson(provider),
    'subscriber_ref': subscriberRef,
    'option_code': offer.code,
    'option_label': offer.label,
    'months': offer.months,
    'package_id': offer.packageId,
    'package_name': offer.packageName,
    'cost': cost,
  };
}

/// One thing the provider sells, with what it costs the shop and what the
/// shop charges for it.
///
/// The list is *learned*: HD Box only exposes its price ladder inside a
/// per-card renew form, so there is no catalog to read in Shop Settings.
/// Every real card lookup records the options it was quoted, and the owner
/// prices what has actually been seen.
class IntegrationOptionPrice {
  const IntegrationOptionPrice({
    required this.optionCode,
    this.label = '',
    this.kind = '',
    this.months = 0,
    this.packageName = '',
    this.price,
    this.suggestedPrice,
    this.isSuggested = false,
    this.effectivePrice,
    this.lastCost = 0,
    this.margin,
    this.isBelowCost = false,
    this.lastSeenAt,
  });

  final String optionCode;
  final String label;
  final String kind;
  final int months;
  final String packageName;

  /// The price the owner set. Null means they have not chosen one, and the
  /// provider's recommendation (or the fallback markup) applies.
  final double? price;

  /// What the provider recommends charging. HD Box publishes a retail ladder
  /// every agency sells at, so a newly connected shop starts from it rather
  /// than from cost.
  final double? suggestedPrice;

  /// Currently charging the recommendation rather than a chosen price.
  final bool isSuggested;

  /// What a sale actually charges: [price] if set, else [suggestedPrice].
  final double? effectivePrice;

  /// The provider's most recent quote.
  final double lastCost;
  final double? margin;

  /// The provider now charges more than the shop asks. The quiet way a
  /// top-up starts losing money after a provider raises its prices.
  final bool isBelowCost;
  final DateTime? lastSeenAt;

  bool get isRenewal => kind == 'renew';
  bool get hasPrice => effectivePrice != null;

  factory IntegrationOptionPrice.fromJson(Map<String, Object?> json) {
    return IntegrationOptionPrice(
      optionCode: json['option_code']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      months: _toInt(json['months']),
      packageName: json['package_name']?.toString() ?? '',
      price: _toDouble(json['price']),
      suggestedPrice: _toDouble(json['suggested_price']),
      isSuggested: json['is_suggested'] == true,
      effectivePrice: _toDouble(json['effective_price']),
      lastCost: _toDouble(json['last_cost']) ?? 0,
      margin: _toDouble(json['margin']),
      isBelowCost: json['is_below_cost'] == true,
      lastSeenAt: _toDate(json['last_seen_at']),
    );
  }
}

/// The shop's whole price list for one provider.
class IntegrationPriceList {
  const IntegrationPriceList({this.currency = 'LYD', this.options = const []});

  final String currency;
  final List<IntegrationOptionPrice> options;

  bool get isEmpty => options.isEmpty;
  int get pricedCount => options.where((o) => o.hasPrice).length;
  bool get hasBelowCost => options.any((o) => o.isBelowCost);

  factory IntegrationPriceList.fromJson(Map<String, Object?> json) {
    return IntegrationPriceList(
      currency: json['currency']?.toString() ?? 'LYD',
      options: (json['options'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(IntegrationOptionPrice.fromJson)
          .toList(growable: false),
    );
  }
}

/// A provider float: what the shop put in, what the provider has taken, and
/// what the provider itself says is left.
///
/// [drift] is the figure worth looking at. Pointy's arithmetic against the
/// provider's own number: a gap means somebody moved the float outside
/// Pointy, and it catches cards this shop has never even looked up.
class IntegrationFloat {
  const IntegrationFloat({
    this.expectedBalance = 0,
    this.toppedUp = 0,
    this.drawn = 0,
    this.committed = 0,
    this.reportedBalance,
    this.reportedAt,
    this.drift,
    this.moneyAccountId,
    this.moneyAccountName = '',
  });

  /// Opening + top-ups − confirmed draws.
  final double expectedBalance;
  final double toppedUp;

  /// Only what the provider is known to have performed.
  final double drawn;

  /// Sold by the shop, not yet performed. Beside the balance, never inside
  /// it — the money is still with the provider.
  final double committed;

  final double? reportedBalance;
  final DateTime? reportedAt;
  final double? drift;
  final int? moneyAccountId;
  final String moneyAccountName;

  bool get hasDrift => drift != null && drift!.abs() >= 1;

  /// The provider holds less than Pointy expects — money left the float
  /// outside Pointy.
  bool get isShort => drift != null && drift! < 0;

  factory IntegrationFloat.fromJson(Map<String, Object?> json) {
    return IntegrationFloat(
      expectedBalance: _toDouble(json['expected_balance']) ?? 0,
      toppedUp: _toDouble(json['topped_up']) ?? 0,
      drawn: _toDouble(json['drawn']) ?? 0,
      committed: _toDouble(json['committed']) ?? 0,
      reportedBalance: _toDouble(json['reported_balance']),
      reportedAt: _toDate(json['reported_at']),
      drift: _toDouble(json['drift']),
      moneyAccountId: json['money_account_id'] is int
          ? json['money_account_id'] as int
          : int.tryParse(json['money_account_id']?.toString() ?? ''),
      moneyAccountName: json['money_account_name']?.toString() ?? '',
    );
  }
}

/// Who a card belongs to, plus what the provider says about the subscription.
class IntegrationSubscriber {
  const IntegrationSubscriber({
    required this.subscriberRef,
    this.id,
    this.customerId,
    this.displayName = '',
    this.label = '',
    this.isIdentified = false,
    this.note = '',
    this.packageName = '',
    this.deviceModel = '',
    this.providerStatus = '',
    this.pricePerMonth,
    this.expireAt,
    this.purchaseCount = 0,
    this.lifetimeSpend,
  });

  final int? id;
  final String subscriberRef;
  final int? customerId;
  final String displayName;

  /// Who to show: the linked customer's name wins over a typed one.
  final String label;
  final bool isIdentified;
  final String note;
  final String packageName;
  final String deviceModel;
  final String providerStatus;
  final double? pricePerMonth;
  final DateTime? expireAt;

  /// Across every agency, not just this shop — which is what makes it worth
  /// showing a cashier: it says how much of this customer somebody else has.
  final int purchaseCount;
  final double? lifetimeSpend;

  factory IntegrationSubscriber.fromJson(Map<String, Object?> json) {
    return IntegrationSubscriber(
      id: json['id'] is int ? json['id'] as int : null,
      subscriberRef: json['subscriber_ref']?.toString() ?? '',
      customerId: json['customer_id'] is int
          ? json['customer_id'] as int
          : null,
      displayName: json['display_name']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      isIdentified: json['is_identified'] == true,
      note: json['note']?.toString() ?? '',
      packageName: json['package_name']?.toString() ?? '',
      deviceModel: json['device_model']?.toString() ?? '',
      providerStatus: json['provider_status']?.toString() ?? '',
      pricePerMonth: _toDouble(json['price_per_month']),
      expireAt: _toDate(json['expire_at']),
      purchaseCount: _toInt(json['purchase_count']),
      lifetimeSpend: _toDouble(json['lifetime_spend']),
    );
  }
}

/// What one attempted recharge did — including "we cannot say".
///
/// Three outcomes, not two, because the provider is not idempotent: a
/// [needsAttention] result means a write went out and its answer never came
/// back, so the money may or may not have moved. Nothing may retry it. The
/// till says so plainly rather than offering a button that would spend twice.
class IntegrationChargeResult {
  const IntegrationChargeResult({
    required this.fulfillment,
    required this.outcome,
    this.provider = '',
    this.kind = 'recharge',
    this.orderLine,
    this.subscriberRef = '',
    this.optionLabel = '',
    this.status = '',
    this.needsAttention = false,
    this.errorCode = '',
    this.errorDetail = '',
    this.providerReference = '',
    this.balanceAfter,
    this.receipt = const {},
  });

  final int? fulfillment;
  final int? orderLine;
  final String provider;

  /// `voucher` for a card off a provider's shelf — its PIN is in [receipt] —
  /// else `recharge`.
  final String kind;
  final String subscriberRef;
  final String optionLabel;

  /// charged · refused · unknown · not_claimable
  final String outcome;

  /// The row this left behind. Disagrees with [outcome] on purpose when the
  /// answer never arrived: `unknown` leaves the row `submitted`.
  final String status;

  final bool needsAttention;
  final String errorCode;
  final String errorDetail;
  final String providerReference;
  final double? balanceAfter;

  /// The provider's own printed slip, if it gave us one.
  final Map<String, String> receipt;

  bool get isCharged => outcome == 'charged';
  bool get isVoucher => kind == 'voucher';

  /// A card's PIN, once it was bought. Empty for everything else.
  String get voucherCode => receipt['code'] ?? '';
  bool get isRefused => outcome == 'refused';
  bool get isOutOfFloat => errorCode == 'insufficient_float';

  factory IntegrationChargeResult.fromJson(Map<String, Object?> json) {
    return IntegrationChargeResult(
      fulfillment: int.tryParse(json['fulfillment']?.toString() ?? ''),
      provider: json['provider']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'recharge',
      orderLine: int.tryParse(json['order_line']?.toString() ?? ''),
      subscriberRef: json['subscriber_ref']?.toString() ?? '',
      optionLabel: json['option_label']?.toString() ?? '',
      outcome: json['outcome']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      needsAttention: json['needs_attention'] == true,
      errorCode: json['error_code']?.toString() ?? '',
      errorDetail: json['error_detail']?.toString() ?? '',
      providerReference: json['provider_reference']?.toString() ?? '',
      balanceAfter: double.tryParse(json['balance_after']?.toString() ?? ''),
      receipt: {
        for (final entry
            in (json['receipt'] as Map<String, Object?>? ?? const {}).entries)
          entry.key: entry.value?.toString() ?? '',
      },
    );
  }
}
