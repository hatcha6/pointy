import 'package:flutter/material.dart';

import '../../../../data/models/service_country_detail.dart';
import '../../../../data/models/services_directory.dart';
import '../../../../shared/design/design.dart';
import 'airtime_phone_step.dart';
import 'service_flag.dart';

/// What the customer is read back before the line goes in the cart: the number
/// in large digits, left to right, exactly as the server will send it; and
/// under it the country (flag and name) and the network (logo and name).
///
/// A wrong number is the one mistake nobody can undo, so this is drawn bigger
/// than anything else in the bar. [number] is the server's own normalisation
/// once it has priced the line ([fromServer]); before that it is what was
/// typed, in a quieter colour. [problem] paints it red: the server and the
/// relay disagree about the number, or the relay says it is not one.
class ServiceReadBack extends StatelessWidget {
  const ServiceReadBack({
    super.key,
    required this.number,
    required this.fromServer,
    required this.country,
    required this.network,
    this.problem = false,
    this.numberSize = 24,
  });

  /// `+223 70 12 34 56`; null until a number is typed.
  final String? number;
  final bool fromServer;
  final bool problem;

  /// The digits' size: large in the summary, where the customer reads them.
  final double numberSize;
  final ServiceCountry country;
  final AirtimeOperator? network;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final numberColor = problem
        ? colors.danger
        : (fromServer ? colors.ink : colors.mutedInk);
    final network = this.network;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            number ?? '\u{2014}',
            key: const ValueKey('service_readback_number'),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            style: PointyTypography.numeric(
              (textTheme.titleLarge ?? const TextStyle()).copyWith(
                color: numberColor,
                fontSize: numberSize,
                fontWeight: FontWeight.w800,
                height: 1.15,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 2,
          children: [
            ServiceFlag(code: country.code, width: 22, height: 15),
            Text(
              country.label,
              style: textTheme.labelLarge?.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (network != null) ...[
              Text(
                '\u{00B7}',
                style: textTheme.labelLarge?.copyWith(color: colors.mutedInk),
              ),
              ServiceNetworkLogo(operator: network, size: 20),
              Text(
                network.label,
                style: textTheme.labelLarge?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
