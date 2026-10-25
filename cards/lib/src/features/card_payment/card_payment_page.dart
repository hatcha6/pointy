import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/order.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../data/vault/card_vault.dart';
import 'card_number.dart';
import 'card_payment_model.dart';
import 'moamalat_client.dart';
import 'three_ds_view.dart';

/// How the card page ended.
enum CardPaymentResult {
  /// Paid, or the order moved on: the order page follows it.
  settled,

  /// The form cannot take this order: open Dafa's page instead.
  usePaymentPage,

  /// The customer closed the page without paying.
  closed,
}

/// A bank-card order paid in the app's own form: the card, then, when the
/// card's bank asks, its confirmation page with the code it texted.
class CardPaymentPage extends StatefulWidget {
  const CardPaymentPage({super.key, required this.order});

  final CardOrder order;

  static Future<CardPaymentResult> open(
    BuildContext context,
    CardOrder order,
  ) async {
    final result = await Navigator.of(context).push<CardPaymentResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CardPaymentPage(order: order),
      ),
    );
    return result ?? CardPaymentResult.closed;
  }

  @override
  State<CardPaymentPage> createState() => _CardPaymentPageState();
}

class _CardPaymentPageState extends State<CardPaymentPage> {
  late final CardPaymentModel _model;
  final _number = TextEditingController();
  final _expiry = TextEditingController();
  final _name = TextEditingController();
  String? _numberError;
  String? _expiryError;
  String? _nameError;
  bool _left = false;
  bool _started = false;

  /// Cards kept on this phone, still in date; the first is chosen.
  List<SavedCard> _saved = const [];
  SavedCard? _chosen;

  /// Typing a card even though some are saved.
  bool _manual = false;

  /// Keep the typed card once it has paid.
  bool _saveCard = false;
  String? _savedNote;

  @override
  void initState() {
    super.initState();
    _number.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    final dependencies = CardsScope.of(context);
    _model = CardPaymentModel(
      orders: dependencies.orders,
      moamalat: dependencies.moamalat,
      cards: dependencies.cards,
      order: widget.order,
    )..addListener(_onChange);
    _model.start();
    dependencies.cards.cards().then((cards) {
      if (!mounted) {
        return;
      }
      final now = DateTime.now();
      setState(() {
        _saved = [
          for (final card in cards)
            if (!card.expiredAt(now)) card,
        ];
        _chosen = _saved.firstOrNull;
      });
    });
  }

  @override
  void dispose() {
    _model.removeListener(_onChange);
    _model.dispose();
    _number.dispose();
    _expiry.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onChange() {
    switch (_model.stage) {
      case CardPaymentStage.done:
        // Without the app's own save, the phone's card store may offer to
        // keep the card it just filled in.
        TextInput.finishAutofillContext(shouldSave: !_saveCard);
        _leave(CardPaymentResult.settled);
      case CardPaymentStage.fallback:
        _leave(CardPaymentResult.usePaymentPage);
      case CardPaymentStage.form when _model.problem != null:
        Haptics.error();
      case _:
        break;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _leave(CardPaymentResult result) {
    if (_left || !mounted) {
      return;
    }
    _left = true;
    if (result == CardPaymentResult.settled) {
      Haptics.success();
    }
    Navigator.of(context).pop(result);
  }

  void _pay() {
    final l10n = AppLocalizations.of(context);
    final number = CardNumber.digits(_number.text);
    final expiry = CardNumber.expiry(_expiry.text);
    setState(() {
      _numberError = CardNumber.isValid(number) ? null : l10n.cardNumberInvalid;
      _expiryError = expiry == null ? l10n.cardExpiryInvalid : null;
      _nameError = _name.text.trim().length < 2 ? l10n.cardNameInvalid : null;
    });
    if (_numberError != null || _expiryError != null || _nameError != null) {
      Haptics.warning();
      return;
    }
    FocusScope.of(context).unfocus();
    Haptics.tap();
    _model.pay(
      CardDetails(
        number: number,
        expiryMonth: expiry!.$1,
        expiryYear: expiry.$2,
        name: _name.text.trim(),
      ),
      save: _saveCard,
    );
  }

  /// A saved card: the phone asks its owner (Face ID or the passcode)
  /// before the app may read its number.
  Future<void> _payWithSaved(SavedCard card) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _savedNote = null);
    Haptics.tap();
    final number = await CardsScope.of(context).cards
        .number(card, reason: l10n.savedCardUnlockReason);
    if (!mounted) {
      return;
    }
    if (number == null) {
      Haptics.warning();
      setState(() => _savedNote = l10n.savedCardLocked);
      return;
    }
    _model.pay(
      CardDetails(
        number: number,
        expiryMonth: card.expiryMonth,
        expiryYear: card.expiryYear,
        name: card.name,
      ),
    );
  }

  String? _problemText(AppLocalizations l10n) => switch (_model.problem) {
    null => null,
    CardPaymentProblem.declined => l10n.cardErrDeclined,
    CardPaymentProblem.expiry => l10n.cardErrExpiry,
    CardPaymentProblem.network => l10n.cardErrNetwork,
    CardPaymentProblem.verification => l10n.cardErrVerification,
    CardPaymentProblem.expired => l10n.cardErrExpired,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final verifying = _model.stage == CardPaymentStage.verifying;
    return PopScope(
      // Leaving the bank's page goes back to the card, not out of paying.
      canPop: !verifying,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _model.verificationAbandoned();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(verifying ? l10n.cardVerifyTitle : l10n.cardPayTitle),
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const Icon(Icons.close_rounded),
            onPressed: verifying
                ? _model.verificationAbandoned
                : () => _leave(CardPaymentResult.closed),
          ),
        ),
        body: SafeArea(
          top: false,
          child: AnimatedSwitcher(
            duration: CardsMotion.standard,
            child: switch (_model.stage) {
              CardPaymentStage.opening ||
              CardPaymentStage.done ||
              CardPaymentStage.fallback => _Waiting(
                key: const ValueKey('opening'),
                text: l10n.cardOpening,
              ),
              CardPaymentStage.verifying => _verification(context),
              _ => _form(context),
            },
          ),
        ),
      ),
    );
  }

  Widget _verification(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('verifying'),
      padding: const EdgeInsets.fromLTRB(
        CardsSpace.gutter,
        CardsSpace.sm,
        CardsSpace.gutter,
        CardsSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.sms_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Text(
                  l10n.cardVerifyBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CardsSpace.md),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(CardsRadii.tile),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: ThreeDSView(
                url: _model.verificationUrl!,
                returnUrl: _model.returnUrl,
                onAnswer: _model.verified,
              ),
            ),
          ),
          const SizedBox(height: CardsSpace.sm),
          _SecureNote(text: l10n.cardSecureNote),
        ],
      ),
    );
  }

  Widget _form(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final busy = _model.stage != CardPaymentStage.form;
    final network = CardNumber.networkOf(_number.text);
    final problem = _problemText(l10n);
    final amount = Money(_model.amount ?? 0);
    final numeric = PointyTypography.numeric(theme.textTheme.titleMedium!);
    final chosen = _chosen;
    final usingSaved = _saved.isNotEmpty && !_manual && chosen != null;
    return AutofillGroup(
      key: const ValueKey('form'),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          CardsSpace.sm,
          CardsSpace.gutter,
          CardsSpace.xl,
        ),
        children: [
          _AmountHeader(amount: amount),
          const SizedBox(height: CardsSpace.xl),
          if (problem != null) ...[
            _Problem(text: problem),
            const SizedBox(height: CardsSpace.lg),
          ],
          if (usingSaved) ...[
            _SavedCards(
              cards: _saved,
              chosen: _chosen,
              enabled: !busy,
              onChoose: (card) => setState(() => _chosen = card),
            ),
            if (_savedNote != null) ...[
              const SizedBox(height: CardsSpace.md),
              _Problem(text: _savedNote!),
            ],
            const SizedBox(height: CardsSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: busy ? null : () => setState(() => _manual = true),
                icon: const Icon(Icons.add_card_rounded),
                label: Text(l10n.useAnotherCard),
              ),
            ),
          ] else ...[
            TextField(
              controller: _number,
              enabled: !busy,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.left,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.creditCardNumber],
              inputFormatters: const [CardNumberFormatter()],
              style: numeric.copyWith(letterSpacing: 1.2),
              decoration: InputDecoration(
                labelText: l10n.cardNumberLabel,
                hintText: '0000 0000 0000 0000',
                hintTextDirection: TextDirection.ltr,
                errorText: _numberError,
                prefixIcon: const Icon(Icons.credit_card_rounded),
                suffixIcon: _NetworkBadge(network: network),
              ),
              onChanged: (_) {
                if (_numberError != null) {
                  setState(() => _numberError = null);
                }
              },
            ),
            const SizedBox(height: CardsSpace.lg),
            TextField(
              controller: _name,
              enabled: !busy,
              keyboardType: TextInputType.name,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.creditCardName],
              inputFormatters: [LengthLimitingTextInputFormatter(50)],
              decoration: InputDecoration(
                labelText: l10n.cardNameLabel,
                errorText: _nameError,
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
              onChanged: (_) {
                if (_nameError != null) {
                  setState(() => _nameError = null);
                }
              },
            ),
            const SizedBox(height: CardsSpace.lg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _expiry,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [
                      AutofillHints.creditCardExpirationDate,
                    ],
                    inputFormatters: const [ExpiryFormatter()],
                    style: numeric,
                    decoration: InputDecoration(
                      labelText: l10n.cardExpiryLabel,
                      hintText: 'MM/YY',
                      hintTextDirection: TextDirection.ltr,
                      errorText: _expiryError,
                      errorMaxLines: 2,
                    ),
                    onChanged: (_) {
                      if (_expiryError != null) {
                        setState(() => _expiryError = null);
                      }
                    },
                    onSubmitted: (_) => _pay(),
                  ),
                ),
                const SizedBox(width: CardsSpace.md),
                // Local cards carry no CVV: the number, the holder's name and
                // the expiry are all Moamalat asks for.
                const Spacer(),
              ],
            ),
            if (CardsScope.of(context).cards.available) ...[
              const SizedBox(height: CardsSpace.md),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _saveCard,
                onChanged: busy
                    ? null
                    : (on) {
                        Haptics.select();
                        setState(() => _saveCard = on);
                      },
                title: Text(
                  l10n.saveCardTitle,
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(l10n.saveCardBody),
              ),
            ],
            if (_saved.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(() => _manual = false),
                  icon: const Icon(Icons.credit_card_rounded),
                  label: Text(l10n.savedCardsTitle),
                ),
              ),
          ],
          const SizedBox(height: CardsSpace.xl),
          SizedBox(
            height: CardsSizes.button,
            child: FilledButton(
              onPressed: busy
                  ? null
                  : usingSaved
                  ? () => _payWithSaved(chosen)
                  : _pay,
              child: busy
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                        const SizedBox(width: CardsSpace.md),
                        Text(
                          _model.stage == CardPaymentStage.confirming
                              ? l10n.cardConfirming
                              : l10n.cardCharging,
                        ),
                      ],
                    )
                  : Text(l10n.payAmount(formatMoney(l10n, amount))),
            ),
          ),
          const SizedBox(height: CardsSpace.lg),
          _SecureNote(text: l10n.cardSecureNote),
          if (!busy) ...[
            const SizedBox(height: CardsSpace.sm),
            Center(
              child: TextButton(
                onPressed: () => _leave(CardPaymentResult.usePaymentPage),
                child: Text(
                  l10n.cardUsePaymentPage,
                  style: TextStyle(color: CardsTheme.link(theme)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What is paid, and to whom it goes: the amount, and Moamalat's mark.
class _AmountHeader extends StatelessWidget {
  const _AmountHeader({required this.amount});

  final Money amount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mark = PaymentMethodMarks.of('moamalat');
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          padding: const EdgeInsets.all(CardsSpace.sm),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(CardsRadii.field),
            border: Border.all(color: const Color(0x1A101828)),
          ),
          child: mark == null ? null : Image(image: mark),
        ),
        const SizedBox(width: CardsSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formatMoney(l10n, amount),
                style: PointyTypography.numeric(theme.textTheme.headlineSmall!)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                l10n.cardThroughMoamalat,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NetworkBadge extends StatelessWidget {
  const _NetworkBadge({required this.network});

  final CardNetwork network;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (network) {
      CardNetwork.visa => 'VISA',
      CardNetwork.mastercard => 'Mastercard',
      _ => null,
    };
    final Widget? child = switch (network) {
      CardNetwork.local when PaymentMethodMarks.of('moamalat') != null => Image(
        image: PaymentMethodMarks.of('moamalat')!,
        width: 28,
      ),
      _ when label != null => Text(
        label,
        textDirection: TextDirection.ltr,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      _ => null,
    };
    return AnimatedSwitcher(
      duration: CardsMotion.fast,
      child: child == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey(network),
              padding: const EdgeInsetsDirectional.only(end: CardsSpace.md),
              child: Center(widthFactor: 1, child: child),
            ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(CardsRadii.field),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: CardsSpace.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SecureNote extends StatelessWidget {
  const _SecureNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_rounded, size: 16, color: color),
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

class _Waiting extends StatelessWidget {
  const _Waiting({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: CardsSpace.lg),
          Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The cards kept on this phone, one to choose: a mark, the last four, the
/// holder and the expiry, never more.
class _SavedCards extends StatelessWidget {
  const _SavedCards({
    required this.cards,
    required this.chosen,
    required this.enabled,
    required this.onChoose,
  });

  final List<SavedCard> cards;
  final SavedCard? chosen;
  final bool enabled;
  final ValueChanged<SavedCard> onChoose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.savedCardsTitle,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: CardsSpace.sm),
        for (final card in cards) ...[
          SavedCardTile(
            card: card,
            selected: card.id == chosen?.id,
            onTap: enabled ? () => onChoose(card) : null,
          ),
          const SizedBox(height: CardsSpace.sm),
        ],
      ],
    );
  }
}

/// One saved card: Moamalat's mark, •••• and the last four, the holder and
/// the expiry; a ring when it is the one chosen.
class SavedCardTile extends StatelessWidget {
  const SavedCardTile({
    super.key,
    required this.card,
    this.selected = false,
    this.onTap,
    this.trailing,
  });

  final SavedCard card;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mark = PaymentMethodMarks.of('moamalat');
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CardsRadii.tile),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(CardsSpace.md),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 32,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0x1A101828)),
                ),
                child: mark == null ? null : Image(image: mark),
              ),
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '•••• ${card.last4}',
                      textDirection: TextDirection.ltr,
                      style: PointyTypography.numeric(
                        theme.textTheme.titleSmall!,
                      ).copyWith(letterSpacing: 1),
                    ),
                    Text(
                      '${card.name} · ${l10n.savedCardExpires(card.expiry)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
              if (trailing == null && onTap != null)
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
