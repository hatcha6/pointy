import '../../../data/models/service_quote.dart';

/// Why the cashier cannot add a service to the cart yet — one reason, the
/// first thing still missing — so the screen can say it under the button.
///
/// The reason is a value, not a sentence: the Arabic wording is the screen's.
enum ServiceBlockReason {
  /// The menu says the service cannot be sold right now.
  notSellable,
  noCountry,
  loadingCountry,
  countryFailed,
  noNumber,
  numberTooShort,

  /// More digits than any number has: a slip of the keys, not a missing part.
  numberTooLong,

  /// The number was pasted with a calling code several countries share, and
  /// none is chosen yet.
  chooseDialCountry,

  /// The relay says what was typed is not a number in this country.
  numberInvalid,

  /// The number the server will send to is not the one the relay placed: the
  /// two read the digits differently, so a wrong number could be topped up.
  numberMismatch,
  noNetwork,
  noProvider,
  noAccount,
  accountTooShort,
  noInvoice,
  noAmount,
  noPlan,
  amountInvalid,
  amountBelowMin,
  amountAboveMax,
  quoting,
  quoteFailed,

  /// The server declined to price it; [ServiceBlocker.code] says why.
  quoteRefused,
}

/// What can be wrong with an amount the cashier typed.
enum ServiceAmountProblem { invalid, belowMin, aboveMax }

class ServiceBlocker {
  const ServiceBlocker(this.reason, {this.code = '', this.min, this.max});

  final ServiceBlockReason reason;

  /// The server's refusal code, for [ServiceBlockReason.quoteRefused].
  final String code;

  /// The limits an amount broke, for the amount reasons and for a refusal that
  /// carried them.
  final double? min;
  final double? max;

  /// Asking again may help: nothing is wrong with what was chosen, the answer
  /// just did not come — or was refused for a reason that may pass.
  bool get isRetryable =>
      reason == ServiceBlockReason.quoteFailed ||
      reason == ServiceBlockReason.countryFailed ||
      (reason == ServiceBlockReason.quoteRefused &&
          ServiceRefusalCode.isTransient(code));

  /// The server answered that what was chosen is no longer on its list — a
  /// network or provider that left, an amount or plan that was withdrawn — so
  /// the list the screen was built on is old: reading it again is the fix.
  bool get needsFreshList =>
      reason == ServiceBlockReason.quoteRefused &&
      (code == ServiceRefusalCode.unknownOperator ||
          code == ServiceRefusalCode.unknownBiller ||
          code == ServiceRefusalCode.amountNotOffered);

  /// Things the cashier can fix by typing, as opposed to waiting or giving up.
  bool get isWaiting =>
      reason == ServiceBlockReason.loadingCountry ||
      reason == ServiceBlockReason.quoting;
}
