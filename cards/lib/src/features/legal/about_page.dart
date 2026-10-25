import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/support.dart';
import '../../design/cards_logo.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import 'legal_document.dart';
import 'legal_page.dart';

/// Who makes the app and how to reach them, its version, and the legal
/// texts in one place.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const AboutPage()));

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((info) {
          if (mounted) {
            setState(() => _version = info.version);
          }
        })
        .catchError((Object _) {});
  }

  void _open(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    const rowPadding = EdgeInsets.symmetric(horizontal: CardsSpace.lg);
    final version = _version;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          CardsSpace.lg,
          CardsSpace.gutter,
          MediaQuery.paddingOf(context).bottom + CardsSpace.huge,
        ),
        children: [
          const Center(child: CardsLogo(size: 88)),
          const SizedBox(height: CardsSpace.lg),
          Text(
            l10n.appTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (version != null) ...[
            const SizedBox(height: CardsSpace.xs),
            Text(
              l10n.aboutVersion(version),
              textAlign: TextAlign.center,
              style: muted,
            ),
          ],
          const SizedBox(height: CardsSpace.md),
          Text(
            l10n.aboutTagline,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: CardsSpace.xl),
          Text(
            l10n.aboutBody,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
          ),
          const SizedBox(height: CardsSpace.xl),
          Grouped(
            children: [
              ListTile(
                contentPadding: rowPadding,
                leading: const Icon(Icons.chat_rounded),
                title: Text(
                  l10n.contactWhatsApp,
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    Support.whatsAppDisplay,
                    textDirection: TextDirection.ltr,
                  ),
                ),
                onTap: () => _open(Support.whatsAppUrl),
              ),
              ListTile(
                contentPadding: rowPadding,
                leading: const Icon(Icons.language_rounded),
                title: Text(
                  l10n.websiteTitle,
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    Support.website.host,
                    textDirection: TextDirection.ltr,
                  ),
                ),
                onTap: () => _open(Support.website),
              ),
            ],
          ),
          const SizedBox(height: CardsSpace.xl),
          Grouped(
            children: [
              for (final document in LegalDocument.values)
                ListTile(
                  contentPadding: rowPadding,
                  leading: Icon(_iconOf(document)),
                  title: Text(
                    LegalPage.titleOf(l10n, document),
                    style: theme.textTheme.titleSmall,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => LegalPage.open(context, document),
                ),
              ListTile(
                contentPadding: rowPadding,
                leading: const Icon(Icons.code_rounded),
                title: Text(
                  l10n.openSourceLicenses,
                  style: theme.textTheme.titleSmall,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: l10n.appTitle,
                  applicationVersion: version,
                  applicationIcon: const Padding(
                    padding: EdgeInsets.all(CardsSpace.md),
                    child: CardsLogo(size: 56),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CardsSpace.xl),
          Text(l10n.aboutCopyright, textAlign: TextAlign.center, style: muted),
        ],
      ),
    );
  }

  static IconData _iconOf(LegalDocument document) => switch (document) {
    LegalDocument.privacy => Icons.privacy_tip_outlined,
    LegalDocument.terms => Icons.description_outlined,
  };
}
