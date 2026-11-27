import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/result.dart';
import '../../data/models/order.dart';
import '../../data/vault/card_vault.dart';
import '../../data/vault/payer_vault.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../../shared/glass_bar.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/method_tile.dart';
import '../../shared/motion.dart';
import '../../shared/side_back.dart';
import 'card_payment_page.dart';

/// What this device keeps of how its customer pays, from the settings: the
/// way to pay offered first, the bank cards kept for the app's own card
/// form (on a phone), and the wallets' numbers payments went through from.
/// Each one can be removed. Saving happens only when paying.
class SavedPaymentsPage extends StatefulWidget {
  const SavedPaymentsPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('saved_payments'),
      builder: (_) => const SavedPaymentsPage(),
    ),
  );

  @override
  State<SavedPaymentsPage> createState() => _SavedPaymentsPageState();
}

class _SavedPaymentsPageState extends State<SavedPaymentsPage> {
  List<SavedCard>? _cards;

  /// The ways to pay, for the preferred one's name and mark; none offline.
  List<PaymentMethod> _methods = const [];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final dependencies = CardsScope.of(context);
    final results = await Future.wait<Object?>([
      dependencies.cards.cards(),
      dependencies.orders.checkoutOptions(),
      dependencies.payments.load(),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      _cards = results[0] as List<SavedCard>;
      if (results[1] case Ok(:final value)) {
        _methods = (value as CheckoutOptions).methods;
      }
    });
  }

  /// Asks before [what] goes; true to remove it.
  Future<bool> _confirm(String title, String body) async {
    final l10n = AppLocalizations.of(context);
    Haptics.warning();
    final confirmed = await showCardsDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
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
    return confirmed == true;
  }

  Future<void> _removeCard(SavedCard card) async {
    final l10n = AppLocalizations.of(context);
    final vault = CardsScope.of(context).cards;
    if (!await _confirm(l10n.removeCardTitle, l10n.removeCardBody)) {
      return;
    }
    await vault.remove(card);
    final cards = await vault.cards();
    if (mounted) {
      setState(() => _cards = cards);
    }
  }

  Future<void> _removePayer(SavedPayer payer) async {
    final l10n = AppLocalizations.of(context);
    final payments = CardsScope.of(context).payments;
    if (await _confirm(
      l10n.removePayerTitle,
      l10n.removePayerBody(payer.methodName),
    )) {
      await payments.forget(payer.method);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final dependencies = CardsScope.of(context);
    final cards = _cards;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SideBack(
      child: Scaffold(
        extendBodyBehindAppBar: GlassBar.extendsBody,
        appBar: GlassBar(title: Text(l10n.savedPaymentsSettings)),
        body: cards == null
            ? const SizedBox.shrink()
            : ListenableBuilder(
                listenable: dependencies.payments,
                builder: (context, _) {
                  final payments = dependencies.payments;
                  final payers = payments.saved;
                  final preferred = _methods
                      .where((m) => m.key == payments.lastMethod)
                      .firstOrNull;
                  final keepsCards = dependencies.cards.available;
                  final nothing =
                      preferred == null && cards.isEmpty && payers.isEmpty;
                  return ListView(
                    padding: CardsLayout.page(
                      context,
                      top: CardsSpace.lg,
                      bottom:
                          MediaQuery.paddingOf(context).bottom + CardsSpace.xl,
                    ),
                    children: [
                      if (nothing)
                        EmptyState(
                          icon: Icons.wallet_rounded,
                          title: l10n.savedNothingTitle,
                          body: l10n.savedNothingBody,
                        )
                      else ...[
                        Text(l10n.savedPaymentsBody, style: muted),
                        const SizedBox(height: CardsSpace.xl),
                      ],
                      if (preferred != null) ...[
                        Grouped(
                          title: l10n.defaultMethodTitle,
                          children: [
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: CardsSpace.lg,
                              ),
                              leading: MethodMark(method: preferred),
                              title: Text(
                                methodName(context, preferred),
                                style: theme.textTheme.titleSmall,
                              ),
                              subtitle: Text(l10n.defaultMethodBody),
                            ),
                          ],
                        ),
                        const SizedBox(height: CardsSpace.xl),
                      ],
                      if (keepsCards && !nothing) ...[
                        _SectionTitle(l10n.bankCards),
                        if (cards.isEmpty)
                          Text(l10n.savedCardsEmpty, style: muted)
                        else
                          for (final card in cards) ...[
                            SavedCardTile(
                              card: card,
                              trailing: _RemoveButton(
                                onPressed: () => _removeCard(card),
                              ),
                            ),
                            const SizedBox(height: CardsSpace.sm),
                          ],
                        const SizedBox(height: CardsSpace.xl),
                      ],
                      if (!nothing) ...[
                        if (payers.isEmpty) ...[
                          _SectionTitle(l10n.savedWalletsTitle),
                          Text(l10n.savedWalletsEmpty, style: muted),
                        ] else
                          Grouped(
                            title: l10n.savedWalletsTitle,
                            children: [
                              for (final payer in payers)
                                _PayerTile(
                                  payer: payer,
                                  preferred: payer.method == preferred?.key,
                                  onRemove: () => _removePayer(payer),
                                ),
                            ],
                          ),
                        const SizedBox(height: CardsSpace.xl),
                      ],
                      _Note(
                        icon: Icons.lock_rounded,
                        text: keepsCards
                            ? '${l10n.savedCardsNote}\n${l10n.savedWalletsNote}'
                            : l10n.savedWalletsNote,
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// A heading over cards that stand on their own (not in a [Grouped]), in
/// the same place and type as a group's own title.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: CardsSpace.xs,
        bottom: CardsSpace.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One wallet's number kept: its mark and name, the number, and «إزالة».
class _PayerTile extends StatelessWidget {
  const _PayerTile({
    required this.payer,
    required this.preferred,
    required this.onRemove,
  });

  final SavedPayer payer;
  final bool preferred;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(
        start: CardsSpace.lg,
        end: CardsSpace.sm,
      ),
      leading: MethodMark.provider(payer.provider),
      title: Row(
        children: [
          Flexible(
            child: Text(
              payer.methodName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (preferred) ...[
            const SizedBox(width: CardsSpace.sm),
            Icon(
              Icons.star_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
          ],
        ],
      ),
      subtitle: Wrap(
        spacing: CardsSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PayerNumber(payer.masked),
          if (payer.birthYear.isNotEmpty)
            Text('· ${l10n.savedPayerBirthYear}', style: muted),
        ],
      ),
      trailing: _RemoveButton(onPressed: onRemove),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.error,
    ),
    onPressed: onPressed,
    child: Text(AppLocalizations.of(context).removeCard),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: CardsSpace.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
