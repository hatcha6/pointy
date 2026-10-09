import '../../../../data/models/service_kinds.dart';
import '../../../../data/models/service_quote.dart';

/// What the cashier chose to sell, priced by the server and ready for the cart.
class ServiceAddRequest {
  const ServiceAddRequest({
    required this.kind,
    required this.quote,
    required this.variantId,
    this.billType,
    this.testMode = false,
  });

  final ServiceKind kind;

  /// The type of bill, for a bill.
  final BillType? billType;

  /// The server's exact, sealed price.
  final ServiceQuote quote;

  /// The system service product the cart line points at: the menu's.
  final int variantId;

  /// Chosen while the relay was buying from its test supplier: the line says
  /// «عملية تجريبية» for as long as it is in the cart.
  final bool testMode;
}

/// Puts a priced service in the cart. False when the cart cannot take it right
/// now (a sale is being completed): nothing was added, so the screen keeps what
/// the cashier built and says so.
typedef ServiceAddCallback = bool Function(ServiceAddRequest request);
