/// The dial string that recharges a telecom card, read from the brand's
/// redeem hint when it spells one out ("اطلب *112* ثم الرقم السري ثم #").
/// Null when the hint does not: the app never guesses an operator's code.
String? rechargeDialString(String redeemHint, String code) {
  final match = RegExp(r'\*(\d{2,4})\*').firstMatch(redeemHint);
  if (match == null || !redeemHint.contains('#')) {
    return null;
  }
  final digits = code.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) {
    return null;
  }
  return '*${match.group(1)}*$digits#';
}
