import '../data/models/catalog.dart';

/// What the phone can do with a bought code.
enum RedeemKind {
  /// Calls [RedeemStep.value], the code already in the number.
  call,

  /// Opens the issuer's page at [RedeemStep.value], the code copied first in
  /// case the page does not take it from its address.
  link,
}

class RedeemStep {
  const RedeemStep(this.kind, this.value);

  final RedeemKind kind;
  final String value;
}

/// The one-tap way to redeem [code], from the catalog's [redeem] for its brand.
/// Null where there is none, or where the code is not the shape the operator's
/// string or the issuer's link takes: the app never guesses, as a wrong string
/// costs a customer their first try at a card they paid for.
RedeemStep? redeemStep(
  CardRedeem? redeem, {
  required String code,
  String country = '',
}) {
  if (redeem == null) {
    return null;
  }
  final spaced = code.replaceAll(RegExp(r'\s'), '');
  final joined = spaced.replaceAll('-', '');
  if (joined.isEmpty) {
    return null;
  }
  final pattern = redeem.pattern;
  if (pattern != null && !pattern.hasMatch(joined.toUpperCase())) {
    return null;
  }
  switch (redeem.kind) {
    case 'dial':
      if (!RegExp(r'^[0-9]+$').hasMatch(joined)) {
        return null;
      }
      return RedeemStep(
        RedeemKind.call,
        redeem.template.replaceAll(CardRedeem.placeholder, joined),
      );
    case 'link':
      // A code with a pattern is issued joined up, in capitals. Any other
      // keeps its dashes, which a Steam key's page expects.
      final value = pattern != null ? joined.toUpperCase() : spaced;
      final link = (redeem.byCountry[country] ?? redeem.template).replaceAll(
        CardRedeem.placeholder,
        Uri.encodeQueryComponent(value),
      );
      return RedeemStep(RedeemKind.link, link);
    default:
      // A kind this build does not know yet.
      return null;
  }
}
