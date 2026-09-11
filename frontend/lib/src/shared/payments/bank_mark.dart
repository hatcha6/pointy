import 'package:flutter/material.dart';

import '../design/design.dart';
import 'libyan_banks.dart';

/// The issuing bank's mark and name, for a card whose bank we actually know.
///
/// Two independent things can be missing here and each degrades on its own:
///
/// * **The bank is unknown** — the receipt carried no BIN, or the BIN is not in
///   the table. Then this draws nothing at all. Never a placeholder mark, never
///   a "بنك غير معروف" row: an unresolved bank is not a fact about the card, it
///   is an absence of one, and a row saying so would be noise on every receipt
///   from an acquirer that masks the PAN.
/// * **The bank is known but its logo is not bundled** — the marks are bank
///   trademarks, added deliberately, so a build may carry the register without
///   the images. Then the name shows on its own. `errorBuilder` is what makes
///   that a shrug rather than a red box.
class BankMark extends StatelessWidget {
  const BankMark({super.key, required this.bank, this.size = 28});

  final LibyanBank? bank;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bank = this.bank;
    if (bank == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BankLogo(bank: bank, size: size),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            bank.arabicName,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Just the mark, sized for a row. Collapses to nothing if the asset is absent.
class BankLogo extends StatelessWidget {
  const BankLogo({super.key, required this.bank, this.size = 28});

  final LibyanBank bank;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      // A gentle rounded rect, NOT a circle. These marks are not uniform discs:
      // Waha's is nearly twice as wide as it is tall and Aman's is a wide oval
      // with the bank's name inside it. Clipping to a circle amputated both
      // ends of exactly the logos whose name you could otherwise read. With
      // BoxFit.contain the image is already letterboxed inside the box, so this
      // radius only ever touches empty corners.
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: Image.asset(
        bank.logoAsset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        // A trademark we have not bundled is a gap, not a failure. Without this
        // Flutter paints its error box and the row turns into a bug report.
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
}
