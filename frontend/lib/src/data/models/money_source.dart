/// Where real money on an account moves: through the cashier's own drawer, or
/// straight into or out of the treasury — the cash box, or a bank account.
enum MoneySource {
  drawer('drawer'),
  treasury('treasury');

  const MoneySource(this.apiValue);

  final String apiValue;
}
