import 'package:flutter/material.dart';

import '../../../../data/models/voucher_menu.dart' show VoucherCountry;
import '../voucher_country_flag.dart';

/// A country's flag on the airtime and bill screens, by ISO code. The flag
/// ships with the app; a country without one shows its code.
class ServiceFlag extends StatelessWidget {
  const ServiceFlag({
    super.key,
    required this.code,
    this.width = 30,
    this.height = 20,
  });

  final String code;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return VoucherCountryFlag(
      country: VoucherCountry(code: code),
      width: width,
      height: height,
    );
  }
}
