import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/redeem.dart';
import '../../core/result.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/pill.dart';
import '../../shared/haptics.dart';

/// The moment the purchase pays off. A seal says it worked, the card turns
/// over to show its code (once, on the card itself), and a row of round
/// actions sits under the thumb: copy, QR, send as a gift, recharge, used.
/// Opened from «كروتي», the codes wait behind Face ID or a fingerprint.
class RevealPage extends StatefulWidget {
  const RevealPage({
    super.key,
    required this.order,
    this.brand,
    this.fromHistory = false,
  });

  final CardOrder order;
  final CardBrand? brand;
  final bool fromHistory;

  @override
  State<RevealPage> createState() => _RevealPageState();
}

class _RevealPageState extends State<RevealPage> with TickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );
  late final AnimationController _seal = AnimationController(
    vsync: this,
    duration: CardsMotion.emphasized,
  );
  final _pages = PageController();
  List<CardCode> _codes = const [];
  Set<String> _used = {};
  bool _locked = false;
  bool _loading = true;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _codes = widget.order.codes;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _flip.dispose();
    _seal.dispose();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final dependencies = CardsScope.of(context);
    _locked = widget.fromHistory && !dependencies.lock.isUnlocked;
    if (_codes.isEmpty) {
      _codes = await dependencies.vault.codes(widget.order.id) ?? const [];
    }
    if (_codes.isEmpty) {
      final result = await dependencies.orders.order(widget.order.id);
      if (result case Ok(:final value)) {
        _codes = value.codes;
        await dependencies.vault.keep(value.id, value.codes);
      }
    }
    _used = await dependencies.vault.usedCodes();
    if (!mounted) {
      return;
    }
    setState(() => _loading = false);
    if (!_locked) {
      _reveal();
    }
  }

  void _reveal() {
    if (widget.fromHistory || MediaQuery.of(context).disableAnimations) {
      _flip.value = 1;
      _seal.value = 1;
      return;
    }
    Haptics.success();
    _seal.forward();
    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted) {
        Haptics.tap();
        _flip.forward();
      }
    });
  }

  Future<void> _unlock() async {
    final l10n = AppLocalizations.of(context);
    if (await CardsScope.of(context).lock.unlock(l10n.unlockReason) &&
        mounted) {
      setState(() => _locked = false);
      _reveal();
    }
  }

  Future<void> _toggleUsed(String code) async {
    final used = !_used.contains(code);
    await CardsScope.of(context).vault.setUsed(code, used);
    Haptics.select();
    setState(() => used ? _used.add(code) : _used.remove(code));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand =
        widget.brand ??
        CardsScope.of(context).catalog.brandOf(widget.order.brandKey);
    final tint = brand == null ? PointyColors.primary : brandTint(brand);
    final current = _codes.isEmpty
        ? null
        : _codes[_page.clamp(0, _codes.length - 1)];
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(widget.fromHistory ? widget.order.name : ''),
        leading: widget.fromHistory
            ? null
            : IconButton(
                tooltip: l10n.closeAction,
                icon: const Icon(Icons.close_rounded),
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
              ),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [
              tint.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.35 : 0.16,
              ),
              theme.scaffoldBackgroundColor,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  CardsSpace.gutter,
                  CardsSpace.sm,
                  CardsSpace.gutter,
                  CardsSpace.xxl,
                ),
                children: [
                  if (!widget.fromHistory) ...[
                    _Seal(animation: _seal),
                    const SizedBox(height: CardsSpace.md),
                    Text(
                      l10n.purchaseSuccess,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    Text(
                      widget.order.name,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: CardsSpace.xl),
                  ],
                  if (brand != null) _cards(context, brand),
                  const SizedBox(height: CardsSpace.lg),
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_locked)
                    _LockedPanel(onUnlock: _unlock)
                  else if (current == null)
                    const _PendingCodes()
                  else ...[
                    if (current.serial.isNotEmpty)
                      Text(
                        l10n.serialNumber(current.serial),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: CardsSpace.lg),
                    _ActionRow(
                      code: current,
                      name: widget.order.name,
                      redeemHint: brand?.redeemHint ?? '',
                      used: _used.contains(current.code),
                      onToggleUsed: () => _toggleUsed(current.code),
                    ),
                    if ((brand?.redeemHint ?? '').isNotEmpty) ...[
                      const SizedBox(height: CardsSpace.xl),
                      _HowTo(hint: brand!.redeemHint),
                    ],
                    if (!widget.fromHistory) ...[
                      const SizedBox(height: CardsSpace.xl),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(context)
                                .popUntil((route) => route.isFirst),
                        child: Text(l10n.doneAction),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One flipping card, or a pager of them with dots for several.
  Widget _cards(BuildContext context, CardBrand brand) {
    final l10n = AppLocalizations.of(context);
    final codes = _codes.isEmpty || _locked ? const <CardCode?>[null] : _codes;
    final width = math.min(
      MediaQuery.sizeOf(context).width - CardsSpace.gutter * 2,
      440.0,
    );
    Widget card(CardCode? code) => _FlipCard(
      animation: _flip,
      brand: brand,
      code: code?.code,
      used: code != null && _used.contains(code.code),
      onCopy: code == null ? null : () => _copy(context, code.code),
    );
    if (codes.length == 1) {
      return card(codes.first);
    }
    return Column(
      children: [
        SizedBox(
          height: width / kCardAspect + CardsSpace.lg,
          child: PageView.builder(
            controller: _pages,
            itemCount: codes.length,
            onPageChanged: (page) {
              Haptics.select();
              setState(() => _page = page);
            },
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.xs,
                vertical: CardsSpace.sm,
              ),
              child: card(codes[index]),
            ),
          ),
        ),
        const SizedBox(height: CardsSpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < codes.length; i++)
              AnimatedContainer(
                duration: CardsMotion.fast,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _page ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: i == _page ? 0.9 : 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
        const SizedBox(height: CardsSpace.xs),
        Text(
          l10n.cardIndex(_page + 1, codes.length),
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
    );
  }
}

Future<void> _copy(BuildContext context, String code) async {
  await Clipboard.setData(ClipboardData(text: code));
  Haptics.tap();
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).copiedNotice)),
      );
  }
}

/// The success mark: a teal disc with a check, landing with a little spring.
class _Seal extends StatelessWidget {
  const _Seal({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: CardsMotion.spring),
      child: Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: PointyColors.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: PointyColors.primary.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 36),
        ),
      ),
    );
  }
}

/// The card's art turning over to show its code on the back. The back is the
/// code's one home: large, left to right, one line, tap to copy.
class _FlipCard extends StatelessWidget {
  const _FlipCard({
    required this.animation,
    required this.brand,
    required this.code,
    required this.used,
    this.onCopy,
  });

  final Animation<double> animation;
  final CardBrand brand;
  final String? code;
  final bool used;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutBack,
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final angle = curved.value.clamp(0.0, 1.0) * math.pi;
        final showBack = angle > math.pi / 2 && code != null;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(code == null ? 0 : angle),
          child: showBack
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationY(math.pi),
                  child: _back(context),
                )
              : DecoratedBox(
                  decoration: const BoxDecoration(boxShadow: CardsShadows.hero),
                  child: CardArt(
                    brand: brand,
                    radius: CardsRadii.tile,
                    shadow: false,
                  ),
                ),
        );
      },
    );
  }

  Widget _back(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (light, dark) = DrawnCard.palette(brand.category);
    return AspectRatio(
      aspectRatio: kCardAspect,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [light, dark],
            ),
            boxShadow: CardsShadows.hero,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            onTap: onCopy,
            child: Padding(
              padding: const EdgeInsets.all(CardsSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          brand.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (used)
                        Pill(text: l10n.usedBadge, tone: PillTone.muted),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    l10n.secretCode,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    // One line always: a code broken across lines gets typed
                    // wrong. Long ones scale down instead.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        code!,
                        maxLines: 1,
                        style:
                            PointyTypography.numeric(
                              theme.textTheme.headlineMedium!,
                            ).copyWith(
                              color: Colors.white,
                              letterSpacing: 2,
                              decoration: used
                                  ? TextDecoration.lineThrough
                                  : null,
                              decorationColor: Colors.white70,
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(height: CardsSpace.sm),
                  Container(
                    height: 5,
                    width: 56,
                    color: PointyColors.accentAmber,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.code,
    required this.name,
    required this.redeemHint,
    required this.used,
    required this.onToggleUsed,
  });

  final CardCode code;
  final String name;
  final String redeemHint;
  final bool used;
  final VoidCallback onToggleUsed;

  Future<void> _gift(BuildContext context) async {
    final text = AppLocalizations.of(context).giftMessage(name, code.code);
    await launchUrl(
      Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
      mode: LaunchMode.externalApplication,
    );
  }

  void _qr(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            0,
            CardsSpace.gutter,
            CardsSpace.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CardsSpace.lg),
              Container(
                padding: const EdgeInsets.all(CardsSpace.lg),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(CardsRadii.card),
                  boxShadow: CardsShadows.raised,
                ),
                child: QrImageView(data: code.code, size: 220),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dial = rechargeDialString(redeemHint, code.code);
    final actions = <Widget>[
      _RoundAction(
        icon: Icons.copy_rounded,
        label: l10n.copyAction,
        primary: dial == null,
        onTap: () => _copy(context, code.code),
      ),
      if (dial != null)
        _RoundAction(
          icon: Icons.phone_forwarded_rounded,
          label: l10n.rechargeNow,
          primary: true,
          onTap: () => launchUrl(Uri(scheme: 'tel', path: dial)),
        ),
      _RoundAction(
        icon: Icons.qr_code_2_rounded,
        label: l10n.showQr,
        onTap: () => _qr(context),
      ),
      _RoundAction(
        icon: Icons.card_giftcard_rounded,
        label: l10n.sendAsGift,
        onTap: () => _gift(context),
      ),
      _RoundAction(
        icon: used ? Icons.undo_rounded : Icons.check_rounded,
        label: used ? l10n.markUnused : l10n.markUsed,
        onTap: onToggleUsed,
      ),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final action in actions) Expanded(child: action)],
    );
  }
}

/// A round action with its label under it, like a music player's actions.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Tooltip(
          message: label,
          child: Material(
            color: primary ? PointyColors.primary : theme.colorScheme.surface,
            shape: const CircleBorder(),
            elevation: 0,
            shadowColor: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: primary ? null : CardsShadows.raised,
                ),
                child: Icon(
                  icon,
                  color: primary ? Colors.white : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: CardsSpace.sm),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
  }
}

class _HowTo extends StatelessWidget {
  const _HowTo({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.howToRedeem,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: CardsSpace.xs),
          Text(
            hint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LockedPanel extends StatelessWidget {
  const _LockedPanel({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.codesLockedTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: CardsSpace.xs),
        Text(
          l10n.codesLockedBody,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: CardsSpace.lg),
        FilledButton.icon(
          onPressed: onUnlock,
          icon: const Icon(Icons.fingerprint_rounded),
          label: Text(l10n.unlockAction),
        ),
      ],
    );
  }
}

class _PendingCodes extends StatelessWidget {
  const _PendingCodes();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: CardsSpace.md),
        Text(
          l10n.codesPendingTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          l10n.codesPendingBody,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}
