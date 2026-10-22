import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/integration_card.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../direct_services/service_test_mode_banner.dart';

/// The PINs of the cards a sale just bought.
///
/// Always on screen, not only when the receipt failed: a print job the
/// printer accepted is not paper in the customer's hand, and a jam after
/// "printed" used to lose the card with nothing left to read it from.
class VoucherCodesCard extends StatelessWidget {
  const VoucherCodesCard({
    super.key,
    required this.cards,
    this.testMode = false,
  });

  final List<IntegrationChargeResult> cards;
  final bool testMode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return PointyResultSection(
      key: const ValueKey('voucher_codes_card'),
      icon: Icons.confirmation_number_outlined,
      title: l10n.checkoutResultCardsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.checkoutResultCardsBody,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          if (testMode || cards.any((card) => card.testMode)) ...[
            const SizedBox(height: 8),
            const Center(child: ServiceTestModeMark()),
          ],
          for (final card in cards) ...[
            const SizedBox(height: 10),
            _VoucherCode(card: card),
          ],
        ],
      ),
    );
  }
}

class _VoucherCode extends StatelessWidget {
  const _VoucherCode({required this.card});

  final IntegrationChargeResult card;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final serial = (card.receipt['serial'] ?? '').trim();
    final instructions = (card.receipt['instructions'] ?? '').trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card.optionLabel,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.posServicesSuccessCopy,
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: card.voucherCode)),
                icon: const Icon(Icons.copy_rounded),
              ),
            ],
          ),
          // One line, however long: a PIN split over two is misread.
          PointyFittedToken(
            code: card.voucherCode,
            style: PointyTypography.numeric(
              (textTheme.headlineSmall ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: colors.primaryDark,
              ),
            ),
          ),
          if (serial.isNotEmpty)
            Text(
              l10n.voucherSerial(serial),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          if (instructions.isNotEmpty)
            Text(
              instructions,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.ink),
            ),
        ],
      ),
    );
  }
}
