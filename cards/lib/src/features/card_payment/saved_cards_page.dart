import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/vault/card_vault.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/side_back.dart';
import 'card_payment_page.dart';
import '../../core/analytics/analytics.dart';

/// The cards kept on this phone, each one removable. Reached from the
/// settings; saving happens only when paying.
class SavedCardsPage extends StatefulWidget {
  const SavedCardsPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('saved_cards'),
      builder: (_) => const SavedCardsPage(),
    ),
  );

  @override
  State<SavedCardsPage> createState() => _SavedCardsPageState();
}

class _SavedCardsPageState extends State<SavedCardsPage> {
  List<SavedCard>? _cards;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cards == null) {
      _load();
    }
  }

  Future<void> _load() async {
    final cards = await CardsScope.of(context).cards.cards();
    if (mounted) {
      setState(() => _cards = cards);
    }
  }

  Future<void> _remove(SavedCard card) async {
    final l10n = AppLocalizations.of(context);
    final vault = CardsScope.of(context).cards;
    Haptics.warning();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.removeCardTitle),
        content: Text(l10n.removeCardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelAction),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.removeCard),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await vault.remove(card);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cards = _cards;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SideBack(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.savedCardsSettings),
          automaticallyImplyLeading: !SideBack.active(context),
        ),
        body: cards == null
            ? const SizedBox.shrink()
            : Builder(
                builder: (context) => ListView(
                  padding: CardsLayout.page(
                    context,
                    top: CardsSpace.lg,
                    bottom:
                        MediaQuery.paddingOf(context).bottom + CardsSpace.xl,
                  ),
                  children: [
                    if (cards.isEmpty)
                      Text(l10n.savedCardsEmpty, style: muted)
                    else
                      for (final card in cards) ...[
                        SavedCardTile(
                          card: card,
                          trailing: TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error,
                            ),
                            onPressed: () => _remove(card),
                            child: Text(l10n.removeCard),
                          ),
                        ),
                        const SizedBox(height: CardsSpace.sm),
                      ],
                    const SizedBox(height: CardsSpace.lg),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lock_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: CardsSpace.sm),
                        Expanded(
                          child: Text(
                            l10n.savedCardsNote,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
