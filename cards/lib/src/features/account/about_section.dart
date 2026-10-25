import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import '../legal/about_page.dart';
import '../legal/legal_document.dart';
import '../legal/legal_page.dart';

/// The app itself, signed in or not: who makes it, and the privacy policy
/// and terms the stores and the law ask to be one tap away.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget row(IconData icon, String title, VoidCallback onTap) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: CardsSpace.lg),
      leading: Icon(icon),
      title: Text(title, style: theme.textTheme.titleSmall),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
    return Grouped(
      title: l10n.aboutSection,
      children: [
        row(
          Icons.info_outline_rounded,
          l10n.aboutTitle,
          () => AboutPage.open(context),
        ),
        row(
          Icons.privacy_tip_outlined,
          l10n.privacyPolicy,
          () => LegalPage.open(context, LegalDocument.privacy),
        ),
        row(
          Icons.description_outlined,
          l10n.termsOfUse,
          () => LegalPage.open(context, LegalDocument.terms),
        ),
      ],
    );
  }
}
