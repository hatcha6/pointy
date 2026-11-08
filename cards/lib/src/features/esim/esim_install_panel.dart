import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/esim/esim_device.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import '../../shared/section_header.dart';
import 'esim_format.dart';

/// One secondary action on the eSIM page: a quiet row under the pinned button.
class EsimActionRow extends StatelessWidget {
  const EsimActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 22),
    title: Text(label),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    onTap: onTap,
  );
}

/// The QR to scan from another screen, and the details to type: for a phone
/// where the one-tap install cannot work.
class EsimInstallAlternatives extends StatelessWidget {
  const EsimInstallAlternatives({
    super.key,
    required this.install,
    required this.facts,
  });

  final EsimInstall install;
  final EsimDeviceFacts facts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: l10n.esimQrTitle,
          padding: const EdgeInsets.only(bottom: CardsSpace.sm),
        ),
        Text(
          facts.isIos
              ? l10n.esimQrStepsIos
              : facts.isAndroid
              ? l10n.esimQrStepsAndroid
              : l10n.esimQrStepsOther,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: CardsSpace.md),
        if (install.qr.isNotEmpty)
          Center(
            child: Container(
              padding: const EdgeInsets.all(CardsSpace.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(CardsRadii.tile),
                boxShadow: CardsShadows.raised,
              ),
              child: Semantics(
                label: l10n.esimQrTitle,
                child: QrImageView(
                  data: install.qr,
                  size: 200,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
          ),
        const SizedBox(height: CardsSpace.lg),
        Grouped(
          title: l10n.esimManualTitle,
          children: [
            if (install.smdp.isNotEmpty)
              EsimCopyRow(label: l10n.esimSmdp, value: install.smdp),
            if (install.activationCode.isNotEmpty)
              EsimCopyRow(
                label: l10n.esimActivationCode,
                value: install.activationCode,
              ),
            if (install.confirmationCode.isNotEmpty)
              EsimCopyRow(
                label: l10n.esimConfirmationCode,
                value: install.confirmationCode,
              ),
          ],
        ),
      ],
    );
  }
}

/// What makes an installed eSIM actually connect, folded away until wanted.
class EsimSetupSteps extends StatelessWidget {
  const EsimSetupSteps({
    super.key,
    required this.install,
    required this.facts,
    this.initiallyExpanded = false,
  });

  final EsimInstall install;
  final EsimDeviceFacts facts;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final apnManual = facts.isIos
        ? install.iosApnType == 'manual'
        : install.androidApnType == 'manual';
    final apnValue = facts.isIos
        ? install.iosApnValue
        : install.androidApnValue;
    Widget step(int number, String text) => Padding(
      padding: const EdgeInsets.only(bottom: CardsSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              '$number',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: CardsSpace.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
    var number = 0;
    return ExpansionTile(
      key: ValueKey(initiallyExpanded),
      initiallyExpanded: initiallyExpanded,
      leading: const Icon(Icons.tune_rounded, size: 22),
      title: Text(l10n.esimNextStepsTitle),
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.fromLTRB(
        CardsSpace.lg,
        0,
        CardsSpace.lg,
        CardsSpace.sm,
      ),
      children: [
        step(++number, l10n.esimStepDataLine),
        if (install.roaming) step(++number, l10n.esimStepRoaming),
        if (apnManual && apnValue.isNotEmpty) ...[
          step(++number, l10n.esimStepApn),
          EsimCopyRow(label: l10n.esimApn, value: apnValue),
        ],
        step(++number, l10n.esimStepArrive),
      ],
    );
  }
}
