import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/support.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../links/cards_link.dart';
import '../../shared/reading_page.dart';
import 'legal_document.dart';
import '../../core/analytics/analytics.dart';

/// A legal text, read the way a long page should be: a centred title, short
/// headed sections, comfortable lines in one column.
class LegalPage extends StatefulWidget {
  const LegalPage({super.key, required this.document});

  final LegalDocument document;

  static Future<void> open(BuildContext context, LegalDocument document) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: PageLink(switch (document) {
              LegalDocument.privacy => LinkedPage.privacy,
              LegalDocument.terms => LinkedPage.terms,
            }).location,
            arguments: ScreenName(document.name),
          ),
          builder: (_) => LegalPage(document: document),
        ),
      );

  static String titleOf(AppLocalizations l10n, LegalDocument document) =>
      switch (document) {
        LegalDocument.privacy => l10n.privacyPolicy,
        LegalDocument.terms => l10n.termsOfUse,
      };

  @override
  State<LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<LegalPage> {
  Future<List<LegalBlock>>? _blocks;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _blocks ??= widget.document.load(
      Localizations.localeOf(context).languageCode,
      bundle: DefaultAssetBundle.of(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ReadingPage(
      title: LegalPage.titleOf(l10n, widget.document),
      body: FutureBuilder(
        future: _blocks,
        builder: (context, snapshot) => SliverList.list(
          children: [
            for (final block in snapshot.data ?? const <LegalBlock>[])
              _Block(block: block),
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.block});

  final LegalBlock block;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge?.copyWith(height: 1.75);
    switch (block.kind) {
      case LegalBlockKind.heading:
        return Padding(
          padding: const EdgeInsets.only(
            top: CardsSpace.xl,
            bottom: CardsSpace.sm,
          ),
          child: Text(
            block.text,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      case LegalBlockKind.bullet:
        return Padding(
          padding: const EdgeInsets.only(bottom: CardsSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  top: 11,
                  end: CardsSpace.md,
                ),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(child: Text(block.text, style: body)),
            ],
          ),
        );
      case LegalBlockKind.paragraph:
        if (block.text == Support.whatsAppDisplay) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => launchUrl(
                Support.whatsAppUrl,
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.chat_rounded),
              label: Text(
                block.text,
                textDirection: TextDirection.ltr,
                style: TextStyle(color: CardsTheme.link(theme)),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: CardsSpace.md),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              block.text,
              style: body,
              textDirection: block.isLatin ? TextDirection.ltr : null,
            ),
          ),
        );
    }
  }
}
