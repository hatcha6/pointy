import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../core/phone.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/grouped.dart';
import '../../shared/method_tile.dart';
import '../../shared/money_text.dart';
import '../../shared/relay_error_text.dart';
import '../orders/order_progress_page.dart';
import 'checkout_model.dart';
import 'payer_dialog.dart';
import '../../shared/haptics.dart';
import '../../shared/shake.dart';

/// Checkout in one sheet, laid out like a wallet's pay sheet: what is bought,
/// how it is paid (one row, «تغيير» to pick another), what it costs line by
/// line, and one button. Then the order's own page.
Future<void> showCheckout(
  BuildContext context, {
  required CardBrand brand,
  required CardItem item,
  int quantity = 1,
  String? heroTag,
}) async {
  final dependencies = CardsScope.of(context);
  final model = CheckoutModel(
    orders: dependencies.orders,
    brand: brand,
    item: item,
    quantity: quantity,
    preferences: dependencies.preferences,
  )..load();
  final order = await showModalBottomSheet<CardOrder>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CheckoutSheet(model: model),
  );
  model.dispose();
  if (order == null || !context.mounted) {
    return;
  }
  await OrderProgressPage.open(context, order: order, brand: brand);
}

class CheckoutSheet extends StatefulWidget {
  const CheckoutSheet({super.key, required this.model});

  final CheckoutModel model;

  @override
  State<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<CheckoutSheet> {
  final _otp = TextEditingController();
  final _otpShake = ShakeController();

  CheckoutModel get model => widget.model;

  @override
  void dispose() {
    _otp.dispose();
    _otpShake.dispose();
    super.dispose();
  }

  Future<void> _pickMethod() async {
    final options = model.options;
    if (options == null) {
      return;
    }
    final chosen = await showModalBottomSheet<PaymentMethod>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) =>
          _MethodPicker(methods: options.methods, selected: model.method),
    );
    if (chosen != null) {
      model.choose(chosen);
    }
  }

  Future<void> _pay() async {
    var payer = '';
    var birthYear = '';
    if (model.needsPayerDetails) {
      final session = CardsScope.of(context).auth.session.value;
      final details = await showPayerDialog(
        context,
        method: model.method!,
        amount: model.toPay,
        phone: session == null
            ? ''
            : LibyanPhone.display(session.phone.replaceFirst('218', '')),
      );
      if (details == null || !mounted) {
        return;
      }
      (payer, birthYear) = details;
    }
    Haptics.tap();
    final order = await model.pay(payer: payer, birthYear: birthYear);
    if (!mounted) {
      return;
    }
    if (order == null) {
      final error = model.error;
      if (error != null) {
        relayErrorIsPassing(error) ? Haptics.warning() : Haptics.error();
      }
      return;
    }
    // A wallet payment waits for its code here; anything else goes on to
    // the order's page.
    if (order.status == OrderStatus.awaitingPayment &&
        order.nextAction == 'otp') {
      return;
    }
    _handOver(order);
  }

  /// The order page takes every order the sheet is done with, however it
  /// ended: a card on its way, money back in credit, a payment that did not
  /// go through. The feel says which before the page does.
  void _handOver(CardOrder order) {
    switch (order.status) {
      // Still to be paid, on the bank's page: nothing has happened yet.
      case OrderStatus.awaitingPayment:
        break;
      case OrderStatus.paid || OrderStatus.fulfilling || OrderStatus.delivered:
        Haptics.success();
      default:
        Haptics.warning();
    }
    Navigator.of(context).pop(order);
  }

  Future<void> _confirm() async {
    if (_otp.text.length < 4) {
      return;
    }
    final order = await model.confirm(_otp.text);
    if (!mounted || order == null) {
      return;
    }
    if (order.status != OrderStatus.awaitingPayment) {
      _handOver(order);
    } else if (model.error != null) {
      Haptics.error();
      _otpShake.shake();
      _otp.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final order = model.order;
        final waitingForCode =
            order != null &&
            order.status == OrderStatus.awaitingPayment &&
            order.nextAction == 'otp';
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              CardsSpace.gutter,
              0,
              CardsSpace.gutter,
              CardsSpace.xl,
            ),
            child: AnimatedSize(
              duration: CardsMotion.standard,
              curve: CardsMotion.curve,
              child: AnimatedSwitcher(
                duration: CardsMotion.standard,
                child: waitingForCode
                    ? _walletCodeStep(context, order)
                    : _reviewStep(context),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _reviewStep(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final item = model.item;
    final label = item.label.isNotEmpty
        ? item.label
        : '${item.faceValue} ${item.faceCurrency}';
    final method = model.method;
    return Column(
      key: const ValueKey('review'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.checkoutTitle, style: theme.textTheme.headlineSmall),
        const SizedBox(height: CardsSpace.lg),
        Row(
          children: [
            SizedBox(width: 96, child: CardArt(brand: model.brand, radius: 10)),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.brand.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '$label × ${model.quantity}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: CardsSpace.xl),
        Grouped(
          children: [
            if (!model.creditCovers)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: CardsSpace.lg,
                ),
                onTap: model.options == null ? null : _pickMethod,
                leading: method == null
                    ? const SizedBox(
                        width: 48,
                        height: 32,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : MethodMark(method: method),
                title: Text(
                  l10n.paymentMethodLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                subtitle: Text(
                  method == null ? '—' : methodName(context, method),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                trailing: Text(
                  l10n.changeAction,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: CardsTheme.link(theme),
                  ),
                ),
              ),
            if (model.credit.isPositive)
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: CardsSpace.lg,
                ),
                secondary: const Icon(Icons.account_balance_wallet_rounded),
                value: model.useCredit,
                onChanged: (value) {
                  Haptics.select();
                  model.setUseCredit(value);
                },
                title: Text(
                  l10n.useCredit(formatMoney(l10n, model.credit)),
                  style: theme.textTheme.titleSmall,
                ),
              ),
          ],
        ),
        const SizedBox(height: CardsSpace.lg),
        _Totals(model: model),
        // The error opens its own space and fades in, rather than shoving
        // the button down in one frame.
        AnimatedSize(
          duration: CardsMotion.standard,
          curve: CardsMotion.curve,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: CardsMotion.fast,
            child: model.error == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    key: ValueKey(relayErrorText(l10n, model.error!)),
                    padding: const EdgeInsets.only(top: CardsSpace.md),
                    child: _ErrorLine(
                      text: relayErrorText(l10n, model.error!),
                      passing: relayErrorIsPassing(model.error!),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: CardsSpace.xl),
        FilledButton(
          onPressed: model.busy || (!model.creditCovers && model.method == null)
              ? null
              : _pay,
          child: model.busy
              ? const _Spinner()
              : Text(
                  model.creditCovers
                      ? l10n.payFromCredit
                      : l10n.payAmount(formatMoney(l10n, model.toPay)),
                ),
        ),
        const SizedBox(height: CardsSpace.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_rounded,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: CardsSpace.xs),
            Flexible(
              child: Text(
                l10n.securePaymentNote,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _walletCodeStep(BuildContext context, CardOrder order) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // The order's own method, whatever is selected on the review step.
    final method =
        model.options?.methods
            .where((m) => m.key == order.method)
            .firstOrNull ??
        model.method;
    final name = method == null ? '' : methodName(context, method);
    return Column(
      key: const ValueKey('wallet-code'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (method != null) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: MethodMark(method: method, width: 64, height: 42),
          ),
          const SizedBox(height: CardsSpace.lg),
        ],
        Text(l10n.walletCodeTitle(name), style: theme.textTheme.headlineSmall),
        const SizedBox(height: CardsSpace.xs),
        Text(
          l10n.walletCodeBody(name, formatMoney(l10n, order.amountToPay)),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: CardsSpace.xl),
        Shake(
          controller: _otpShake,
          child: TextField(
            controller: _otp,
            autofocus: true,
            enabled: !model.busy,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            style: PointyTypography.numeric(theme.textTheme.headlineMedium!)
                .copyWith(letterSpacing: 10, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              hintText: '••••••',
              errorText: model.error == null
                  ? null
                  : relayErrorText(l10n, model.error!),
              errorMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _confirm(),
          ),
        ),
        const SizedBox(height: CardsSpace.xl),
        FilledButton(
          onPressed: model.busy || _otp.text.length < 4 ? null : _confirm,
          child: model.busy ? const _Spinner() : Text(l10n.confirmPayment),
        ),
        const SizedBox(height: CardsSpace.sm),
        TextButton(
          onPressed: model.busy
              ? null
              : () async {
                  await model.cancel();
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          child: Text(l10n.cancelOrder),
        ),
      ],
    );
  }
}

class _MethodPicker extends StatelessWidget {
  const _MethodPicker({required this.methods, required this.selected});

  final List<PaymentMethod> methods;
  final PaymentMethod? selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          CardsSpace.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.choosePaymentMethod,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: CardsSpace.lg),
            Grouped(
              children: [
                for (final method in methods)
                  MethodRow(
                    method: method,
                    selected: method.key == selected?.key,
                    onTap: () {
                      Haptics.select();
                      Navigator.of(context).pop(method);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.model});

  final CheckoutModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget line(String label, Money amount, {bool negative = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: CardsSpace.sm),
          Text(
            '${negative ? '− ' : ''}${formatMoney(l10n, amount)}',
            style: PointyTypography.numeric(theme.textTheme.bodyMedium!),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CardsSpace.xs),
      child: Column(
        children: [
          line(l10n.lineSubtotal, model.total),
          if (model.creditApplied.isPositive)
            line(l10n.lineCredit, model.creditApplied, negative: true),
          if (model.fee.isPositive) line(l10n.lineFee, model.fee),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: CardsSpace.sm),
            child: Divider(),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.lineTotal,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: CardsSpace.sm),
              AnimatedSwitcher(
                duration: CardsMotion.fast,
                child: Text(
                  formatMoney(l10n, model.toPay),
                  key: ValueKey(model.toPay),
                  style: PointyTypography.numeric(
                    theme.textTheme.headlineSmall!,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Why the payment did not start. A passing problem (no connection, the
/// gateway busy) is a soft amber with a clock: try again in a moment. A
/// refusal (declined, wrong details) is red: something needs changing.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.text, required this.passing});

  final String text;
  final bool passing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = passing
        ? (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
            Icons.schedule_rounded,
          )
        : (
            scheme.error.withValues(alpha: 0.08),
            scheme.error,
            Icons.error_outline_rounded,
          );
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(CardsRadii.field),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(width: CardsSpace.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 22,
    height: 22,
    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
  );
}
