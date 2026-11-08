import 'package:flutter/widgets.dart';

/// Off the web the payment page is a native web view; there is no frame.
class PaymentFrame extends StatelessWidget {
  const PaymentFrame({
    super.key,
    required this.url,
    required this.onLoaded,
    required this.onReturn,
  });

  final Uri url;
  final VoidCallback onLoaded;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
