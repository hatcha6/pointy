// Dev-only (safe to delete): purchases in the preview harness that end the
// way you choose, so every outcome can be walked through the real screens.
// Not shipped.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Builds an order's JSON as the relay sends it (`fixtureOrder`).
typedef OrderJson = Map<String, dynamic> Function({
  String id,
  String status,
  String item,
  String brand,
  String name,
  String total,
  String nextAction,
  String errorCode,
});

/// How a purchase in the preview ends.
enum PreviewOutcome {
  delivered('الكرت يصلك', 'نجاح'),
  refunded('تعذّر الكرت، فيُعاد المبلغ إلى الرصيد', 'استرداد'),
  review('دفعة بمبلغ مختلف، قيد المراجعة', 'مراجعة'),
  unpaid('لم يكتمل الدفع', 'لم يكتمل'),
  wrongCode('رمز المحفظة خاطئ أولاً، ثم صحيح', 'رمز خاطئ'),
  declined('رُفض الدفع عند البدء', 'رفض'),
  offline('انقطع الاتصال عند الدفع', 'دون اتصال');

  const PreviewOutcome(this.description, this.short);

  /// What happens, in a sentence.
  final String description;

  /// What the floating chip says.
  final String short;
}

/// The outcome the next purchase gets. Each purchase takes it and moves the
/// next one on, so buying again and again walks every outcome in turn.
class PreviewScenarios extends ChangeNotifier {
  PreviewOutcome next = PreviewOutcome.values.first;

  void choose(PreviewOutcome outcome) {
    next = outcome;
    notifyListeners();
  }

  PreviewOutcome take() {
    final taken = next;
    next =
        PreviewOutcome.values[(taken.index + 1) % PreviewOutcome.values.length];
    notifyListeners();
    return taken;
  }
}

/// One scripted order: how it ends and how far it has got.
class _Script {
  _Script({required this.outcome, required this.hosted, required this.order});

  final PreviewOutcome outcome;

  /// Paid on the bank's page (asked after) rather than with a wallet code.
  final bool hosted;
  final Map<String, dynamic> order;
  bool paid = false;
  bool wrongCodeTried = false;
  int polls = 0;

  /// What each poll answers once paid (or, on the bank's page, from the
  /// start): a beat of "preparing", then the ending.
  List<(String, String)> get afterPayment => switch (outcome) {
    PreviewOutcome.refunded => [('fulfilling', ''), ('refunded', '')],
    PreviewOutcome.review => [('paid', ''), ('failed', 'payment_mismatch')],
    PreviewOutcome.unpaid => [('awaiting_payment', ''), ('expired', '')],
    _ => [('fulfilling', ''), ('delivered', '')],
  };
}

/// The order side of the fake relay when the preview plays scenarios: it
/// places, confirms and answers orders as [scenarios] says. It learns names
/// and prices from the shelf the app was shown ([learnShelf]).
class ScriptedOrders {
  ScriptedOrders(this.scenarios);

  final PreviewScenarios scenarios;
  final _scripts = <String, _Script>{};
  final _items = <String, (String, String, String)>{};
  int _count = 0;

  /// Remembers each item's brand, name and price from a catalog answer.
  void learnShelf(String body) {
    try {
      final catalog = jsonDecode(body) as Map<String, dynamic>;
      for (final brand in catalog['brands'] as List) {
        final b = brand as Map<String, dynamic>;
        for (final item in b['items'] as List) {
          final i = item as Map<String, dynamic>;
          _items[i['key'] as String] = (
            b['key'] as String,
            '${b['name']} · ${i['label']}',
            i['price'] as String,
          );
        }
      }
    } catch (_) {
      // A shelf it cannot read leaves orders with placeholder names.
    }
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _refusal(
    String code,
    int status, [
    Map<String, Object>? extra,
  ]) => _json({'code': code, 'error': code, ...?extra}, status);

  /// Answers [request] if it is about orders, or null.
  Future<http.Response?> answer(
    http.BaseRequest request,
    String body,
    OrderJson order,
  ) async {
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/customers/orders') {
      final sent = jsonDecode(body) as Map<String, dynamic>;
      final outcome = scenarios.take();
      if (outcome == PreviewOutcome.offline) {
        throw http.ClientException('the preview pretends to be offline');
      }
      if (outcome == PreviewOutcome.declined) {
        return _refusal('declined', 402);
      }
      final itemKey = sent['item'] as String;
      final quantity = (sent['quantity'] as num?)?.toInt() ?? 1;
      final (brand, name, price) =
          _items[itemKey] ?? ('libyana', 'ليبيانا · 10 دينار', '10.00');
      final total = ((double.tryParse(price) ?? 10) * quantity).toStringAsFixed(
        3,
      );
      final hosted = sent['method'] == 'dafa_moamalat';
      final id = 'preview-${++_count}';
      final placed = order(
        id: id,
        status: 'awaiting_payment',
        item: itemKey,
        brand: brand,
        name: quantity > 1 ? '$name × $quantity' : name,
        total: total,
        nextAction: hosted ? 'hosted_page' : 'otp',
      );
      _scripts[id] = _Script(outcome: outcome, hosted: hosted, order: placed);
      return _json({'order': placed}, 201);
    }
    final match = RegExp(r'^/v1/customers/orders/([^/]+)(/confirm)?$')
        .firstMatch(path);
    final script = match == null ? null : _scripts[match.group(1)];
    if (script == null) {
      return null;
    }
    if (match!.group(2) != null && request.method == 'POST') {
      if (script.outcome == PreviewOutcome.wrongCode &&
          !script.wrongCodeTried) {
        script.wrongCodeTried = true;
        return _refusal('otp_rejected', 422, {'attempts_left': 2});
      }
      if (script.outcome == PreviewOutcome.unpaid) {
        // The wallet turned the payment down: nothing taken.
        return _json({'order': _with(script, 'failed', 'declined', order)});
      }
      script.paid = true;
      return _json({'order': _with(script, 'paid', '', order)});
    }
    if (request.method == 'GET') {
      if (!script.hosted && !script.paid) {
        return _json({'order': script.order});
      }
      final steps = script.afterPayment;
      final (status, error) = steps[script.polls.clamp(0, steps.length - 1)];
      script.polls++;
      return _json({'order': _with(script, status, error, order)});
    }
    return null;
  }

  Map<String, dynamic> _with(
    _Script script,
    String status,
    String errorCode,
    OrderJson order,
  ) => order(
    id: script.order['id'] as String,
    status: status,
    item: script.order['item'] as String,
    brand: script.order['brand'] as String,
    name: script.order['name'] as String,
    total: script.order['total'] as String,
    errorCode: errorCode,
  );
}
