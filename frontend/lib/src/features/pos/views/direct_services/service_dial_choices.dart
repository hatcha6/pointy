import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/services_directory.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import 'service_flag.dart';

/// Said under the number field when a pasted number begins with a calling code
/// several countries share (`+1`): which of them is it for? One tap answers.
/// Never guessed — a wrong country sends the credit to somebody else.
class ServiceDialChoices extends StatefulWidget {
  const ServiceDialChoices({
    super.key,
    required this.dial,
    required this.countries,
    required this.onChosen,
  });

  /// The shared code, digits only.
  final String dial;
  final List<ServiceCountry> countries;
  final ValueChanged<ServiceCountry> onChosen;

  @override
  State<ServiceDialChoices> createState() => _ServiceDialChoicesState();
}

class _ServiceDialChoicesState extends State<ServiceDialChoices> {
  @override
  void initState() {
    super.initState();
    // The question stops the sale: wherever the form is scrolled to, it comes
    // into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.4,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dial = widget.dial;
    final countries = widget.countries;
    final onChosen = widget.onChosen;
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      key: const ValueKey('service_dial_choices'),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.warning.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.priority_high_rounded,
                  size: 19,
                  color: colors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.posAirtimePhoneSharedCode(ltrIsolated(dial)),
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final country in countries)
                  ActionChip(
                    key: ValueKey('service_dial_choice_${country.code}'),
                    avatar: ServiceFlag(
                      code: country.code,
                      width: 24,
                      height: 16,
                    ),
                    label: Text(country.label),
                    labelStyle: textTheme.bodyMedium?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                    onPressed: () => onChosen(country),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
