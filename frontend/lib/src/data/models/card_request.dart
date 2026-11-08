import 'integration_card.dart';
import 'provider_receipt_fields.dart';

/// Where a card sold from the company's shelf has got to.
enum CardRequestState {
  /// Sold, and the request has not left yet.
  queued,

  /// Sent; the supplier is working on it, or has not answered.
  working,
  succeeded,

  /// It ended without delivering. Final: another go is another sale.
  failed,

  /// The sale was given back before anything was sent.
  cancelled,
}

/// One line of the till's requests panel.
///
/// Keyed by [orderLine], which the till knows the moment a sale is recorded,
/// before the server has answered anything about the request itself.
class CardRequest {
  const CardRequest({
    required this.orderLine,
    required this.orderId,
    required this.state,
    required this.label,
    this.receiptNumber = '',
    this.customerName = '',
    this.brand = '',
    this.brandName = '',
    this.kind = '',
    this.account = '',
    this.accountName = '',
    this.late = false,
    this.amount = 0,
    this.createdAt,
    this.finishedAt,
    this.errorCode = '',
    this.errorDetail = '',
    this.receipt = const {},
    this.refundAmount,
    this.refundToAccount = false,
  });

  factory CardRequest.fromJson(Map<String, Object?> json) {
    final receipt = json['receipt'];
    return CardRequest(
      orderLine: int.tryParse(json['order_line']?.toString() ?? '') ?? 0,
      orderId: int.tryParse(json['order']?.toString() ?? '') ?? 0,
      state: switch (json['state']) {
        'queued' => CardRequestState.queued,
        'succeeded' => CardRequestState.succeeded,
        'failed' => CardRequestState.failed,
        'cancelled' => CardRequestState.cancelled,
        _ => CardRequestState.working,
      },
      label: json['label']?.toString() ?? '',
      receiptNumber: json['receipt_number']?.toString() ?? '',
      customerName: json['customer_name']?.toString() ?? '',
      brand: json['brand']?.toString() ?? '',
      brandName: json['brand_name']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      account: json['account']?.toString() ?? '',
      accountName: json['account_name']?.toString() ?? '',
      late: json['late'] == true,
      amount: double.tryParse(json['amount']?.toString() ?? '') ?? 0,
      createdAt: DateTime.tryParse(
        json['created_at']?.toString() ?? '',
      )?.toLocal(),
      finishedAt: DateTime.tryParse(
        json['finished_at']?.toString() ?? '',
      )?.toLocal(),
      errorCode: json['error_code']?.toString() ?? '',
      errorDetail: json['error_detail']?.toString() ?? '',
      receipt: receipt == null ? const {} : providerReceiptFromJson(receipt),
      refundAmount: json['refunded'] == true
          ? double.tryParse(json['refund_amount']?.toString() ?? '')
          : null,
      refundToAccount: json['refund_to_account'] == true,
    );
  }

  final int orderLine;
  final int orderId;
  final CardRequestState state;
  final String label;
  final String receiptNumber;
  final String customerName;
  final String brand;
  final String brandName;
  final String kind;

  /// The account it is sent to, on one line; empty for a code.
  final String account;
  final String accountName;

  /// Open for much longer than usual. Never "failed": only the supplier's word
  /// ends it, and selling it again could pay twice.
  final bool late;
  final double amount;
  final DateTime? createdAt;
  final DateTime? finishedAt;
  final String errorCode;
  final String errorDetail;

  /// The slip of a delivered request: its code, or whose account it reached.
  final Map<String, String> receipt;

  /// What went back to the customer; null when nothing was given back.
  final double? refundAmount;

  /// Given back off the debt of a sale on account: nothing to hand back.
  final bool refundToAccount;

  bool get isOpen =>
      state == CardRequestState.queued || state == CardRequestState.working;
  bool get isSucceeded => state == CardRequestState.succeeded;
  bool get isFailed => state == CardRequestState.failed;

  /// What the customer is handed: a card's code, a prepaid meter's token.
  String get code => receipt['code'] ?? receipt['pin'] ?? '';

  /// As the sale's receipt reads a provider's answer.
  IntegrationChargeResult toChargeResult() => IntegrationChargeResult(
    fulfillment: null,
    orderLine: orderLine,
    provider: 'pointy',
    kind: kind.isEmpty ? 'voucher' : kind,
    subscriberRef: account,
    optionLabel: label,
    outcome: isSucceeded
        ? 'charged'
        : isFailed
        ? 'refused'
        : 'unknown',
    status: isSucceeded ? 'confirmed' : '',
    errorCode: errorCode,
    errorDetail: errorDetail,
    receipt: receipt,
    refundAmount: refundAmount,
    refundToAccount: refundToAccount,
  );

  /// The same request, as a charge's answer left it.
  CardRequest answeredBy(IntegrationChargeResult result) => CardRequest(
    orderLine: orderLine,
    orderId: orderId,
    state: result.isCharged
        ? CardRequestState.succeeded
        : result.isRefused
        ? CardRequestState.failed
        : CardRequestState.working,
    label: label,
    receiptNumber: receiptNumber,
    customerName: customerName,
    brand: brand,
    brandName: brandName,
    kind: result.kind.isEmpty ? kind : result.kind,
    account: account,
    accountName: accountName,
    amount: amount,
    createdAt: createdAt,
    finishedAt: result.isCharged || result.isRefused ? DateTime.now() : null,
    errorCode: result.errorCode,
    errorDetail: result.errorDetail,
    receipt: result.receipt,
    refundAmount: result.refundAmount,
    refundToAccount: result.refundToAccount,
  );
}
