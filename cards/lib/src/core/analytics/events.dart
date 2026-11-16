import '../../data/api/relay_api.dart';
import '../../data/models/campaign.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../money.dart';
import 'analytics.dart';

/// Every event the app sends, in one place: the names PostHog's funnels and
/// dashboards are built on, so renaming one here breaks them there.
///
/// Properties are plain facts about the catalog and the order: brand and
/// item keys, amounts in dinars, the payment method. Never a code, a phone
/// number or what was typed into a payment form. A search's text is sent,
/// so the shelf can learn what people look for and do not find.
extension CardsEvents on Analytics {
  // The shelf.

  void brandViewed(CardBrand brand) =>
      capture('brand_viewed', {'brand': brand.key, 'category': brand.category});

  void brandShared(CardBrand brand) =>
      capture('brand_shared', {'brand': brand.key});

  void categorySelected(String category) =>
      capture('category_selected', {'category': category});

  void searched(String query, int results) =>
      capture('search_performed', {'query': query, 'results': results});

  // Buying.

  void checkoutStarted(CardBrand brand, CardItem item, int quantity) =>
      capture('checkout_started', {
        'brand': brand.key,
        'item': item.key,
        'quantity': quantity,
        'price': dinars(item.price),
      });

  void paymentMethodSelected(String method) =>
      capture('payment_method_selected', {'method': method});

  /// A bank-card order's payment opened: `native` (the app's card form) or
  /// `hosted` (Dafa's page). The payment-form experiment's funnel starts here.
  void paymentFormShown(String form) =>
      capture('payment_form_shown', {'form': form});

  void orderPlaced(CardOrder order) => capture('order_placed', _order(order));

  /// The relay refused the order, or Dafa would not start its payment. Dafa's
  /// own code and the relay's `detail` (written for the operator) say which
  /// step refused. The detail quotes Dafa's own sentences, so any long run of
  /// digits in it is masked here: a payer's number never leaves the phone.
  void orderPlaceFailed(Object error, {required String method}) {
    final body = error is RelayApiException ? error.body : const {};
    final gatewayCode = body['gateway_code'];
    final detail = body['detail'];
    capture('order_place_failed', {
      'error_code': errorCodeOf(error),
      'method': method,
      if (gatewayCode is String && gatewayCode.isNotEmpty)
        'gateway_code': gatewayCode,
      if (detail is String && detail.isNotEmpty) 'detail': _masked(detail),
    });
  }

  /// [text] cut short, with every run of six digits or more (a phone or a
  /// card number) replaced.
  static String _masked(String text) {
    final masked = text.replaceAll(_longNumber, '•••');
    return masked.length <= 200 ? masked : masked.substring(0, 200);
  }

  static final _longNumber = RegExp(
    r'[0-9\u0660-\u0669](?:[ -]?[0-9\u0660-\u0669]){5,}',
  );

  /// Dafa's card page did not load in the app's web view.
  void paymentPageLoadFailed(CardOrder order, String reason) => capture(
    'payment_page_load_failed',
    {'order_id': order.id, 'reason': reason},
  );

  /// Dafa's card page closed: `returned` (its «المتابعة»), `settled` (the
  /// relay heard first) or `closed` (the payer closed it). `status` is the
  /// order as the app knew it then: a `settled` page may have ended unpaid.
  void paymentPageClosed(
    CardOrder order, {
    required String result,
    required Duration open,
  }) => capture('payment_page_closed', {
    'order_id': order.id,
    'result': result,
    'status': order.status.name,
    'seconds': open.inSeconds,
  });

  /// Paid, whatever happens next: the money event. `revenue` (in dinars) is
  /// what revenue analytics reads.
  void orderPaid(CardOrder order) => capture('order_paid', {
    ..._order(order),
    'revenue': dinars(order.total),
    'currency': 'LYD',
  });

  void orderDelivered(CardOrder order) =>
      capture('order_delivered', _order(order));

  /// Refunded, failed, expired or called off.
  void orderEnded(CardOrder order) => capture('order_ended', {
    ..._order(order),
    'status': order.status.name,
    'error_code': order.errorCode,
  });

  // After buying.

  void codeAction(String action, {required String brand}) =>
      capture('code_action', {'action': action, 'brand': brand});

  // The account.

  void signInStarted() => capture('sign_in_started');

  void signInCodeRequested() => capture('sign_in_code_requested');

  void signedIn() => capture('signed_in');

  void signInFailed(String step, String errorCode) =>
      capture('sign_in_failed', {'step': step, 'error_code': errorCode});

  void signedOut() => capture('signed_out');

  void accountDeleted() => capture('account_deleted');

  // Notifications.

  void pushPermission({required bool granted}) =>
      capture('push_permission', {'granted': granted});

  void pushOpened({required String link, required String campaign}) =>
      capture('push_opened', {'link': link, 'campaign': campaign});

  void onboardingFinished({required bool skipped, required int step}) =>
      capture('onboarding_finished', {'skipped': skipped, 'step': step});

  // Where customers come from. A campaign code is the operator's, printed on
  // posters: not the customer's secret.

  void attributionAnswered({
    required String heardFrom,
    required bool hasCode,
  }) => capture('attribution_answered', {
    'heard_from': heardFrom.isEmpty ? 'skipped' : heardFrom,
    'has_code': hasCode,
  });

  /// «من أين سمعت عنا؟» as a fact about the customer, not only an event.
  void heardFrom(String answer) => setPersonOnce({'heard_from': answer});

  void campaignCodeChecked({required bool valid}) =>
      capture('campaign_code_checked', {'valid': valid});

  void campaignRewardShown(CampaignReward reward) =>
      capture('campaign_reward_shown', {
        'campaign': reward.code,
        'kind': reward.kind,
        'via': reward.via,
        'amount': dinars(reward.amount),
      });

  static Map<String, Object> _order(CardOrder order) => {
    'order_id': order.id,
    'brand': order.brandKey,
    'item': order.itemKey,
    'quantity': order.quantity,
    'total': dinars(order.total),
    'fee': dinars(order.fee),
    'credit_used': dinars(order.creditUsed),
    'method': order.method.isEmpty ? 'credit' : order.method,
  };
}

/// An amount in dinars, as PostHog sums it.
double dinars(Money money) => money.dirhams / 1000;

/// The relay's reason for a refusal, or what kind of failure it was: what an
/// event says went wrong, never the message itself.
String errorCodeOf(Object error) => switch (error) {
  RelayApiException(:final code) when code.isNotEmpty => code,
  RelayApiException(:final status) => 'http_$status',
  _ => error.runtimeType.toString(),
};
