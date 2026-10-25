import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_theme.dart';
import 'legal_document.dart';
import 'legal_page.dart';

/// «بالمتابعة، أنت توافق على شروط الاستخدام وسياسة الخصوصية.», each name a
/// link: said where the account is made, so agreeing is a step the customer
/// sees rather than a page they never open.
class LegalConsent extends StatefulWidget {
  const LegalConsent({super.key});

  @override
  State<LegalConsent> createState() => _LegalConsentState();
}

class _LegalConsentState extends State<LegalConsent> {
  final Map<LegalDocument, TapGestureRecognizer> _taps = {};

  /// Private-use characters stand in for the links while the sentence is
  /// built, so each language keeps its own word order around them.
  static const Map<LegalDocument, String> _marks = {
    LegalDocument.terms: '',
    LegalDocument.privacy: '',
  };

  @override
  void dispose() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.6,
    );
    final link = TextStyle(
      color: CardsTheme.link(theme),
      fontWeight: FontWeight.w600,
    );
    final sentence = l10n.signInConsent(
      _marks[LegalDocument.terms]!,
      _marks[LegalDocument.privacy]!,
    );
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    for (final char in sentence.characters) {
      final document = _marks.entries
          .where((entry) => entry.value == char)
          .map((entry) => entry.key)
          .firstOrNull;
      if (document == null) {
        buffer.write(char);
        continue;
      }
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
      spans.add(
        TextSpan(
          text: LegalPage.titleOf(l10n, document),
          style: link,
          recognizer: _taps[document] ??= TapGestureRecognizer()
            ..onTap = () => LegalPage.open(context, document),
        ),
      );
    }
    spans.add(TextSpan(text: buffer.toString()));
    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.center,
      style: style,
    );
  }
}
