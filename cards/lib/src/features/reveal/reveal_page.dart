import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/redeem.dart';
import '../../core/result.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../dependencies.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/tilt_card.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/side_back.dart';
import '../../shared/success_seal.dart';
import 'card_faces.dart';
import 'qr_pass.dart';
import '../../core/analytics/events.dart';
import '../../shared/name_text.dart';

/// The moment the purchase pays off. A seal says it worked, the card turns
/// over to show its code (once, on the card itself), and a row of round
/// actions sits under the thumb: copy, QR, send as a gift, recharge, used. The
/// QR action, or tapping the card, lifts the card and scratches the foil off
/// its QR.
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

  /// The card on show, measured to lift the QR pass out of it.
  final _shown = GlobalKey();

  /// While the QR pass is up, the card it lifted out of is gone from the
  /// page: the pass is that card.
  bool _passUp = false;

  /// The codes whose QR has had its foil scratched off, this visit.
  final Set<String> _scratched = {};
  List<CardCode> _codes = const [];
  Set<String> _used = {};
  bool _locked = false;
  bool _loading = true;
  int _page = 0;

  /// Asks again for a code the supplier has not handed over yet.
  Timer? _follow;

  /// Stops telling the app this order is on screen.
  VoidCallback? _unwatch;

  /// Some suppliers take minutes to deliver a paid card (FazerCards took 2m43s
  /// on 2026-11-03). Past this the relay keeps chasing it, and «كروتي» shows
  /// the code once it lands.
  static const _followFor = Duration(minutes: 10);
  static const _followEvery = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _codes = widget.order.codes;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The card's own "code ready" notification stays quiet while it is up.
    _unwatch ??= CardsScope.of(context).push.watch(
      widget.order.id,
      () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
    );
  }

  @override
  void dispose() {
    _unwatch?.call();
    _follow?.cancel();
    _flip.dispose();
    _seal.dispose();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final dependencies = CardsScope.of(context);
    // The first card is in hand: now a notification is worth something.
    if (!widget.fromHistory) {
      unawaited(dependencies.push.offer());
    }
    _locked = widget.fromHistory && !dependencies.lock.isUnlocked;
    if (_codes.isEmpty) {
      _codes = await dependencies.vault.codes(widget.order.id) ?? const [];
    }
    var latest = widget.order;
    if (_codes.isEmpty) {
      final result = await dependencies.orders.order(widget.order.id);
      if (result case Ok(:final value)) {
        latest = value;
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
    if (_codes.isEmpty && _codesComing(latest)) {
      _followCodes(dependencies);
    }
  }

  static bool _codesComing(CardOrder order) =>
      order.codesPending || order.status.isOpen;

  /// The card is paid for and its code is on its way: ask until it comes,
  /// the order closes without it, or [_followFor] runs out.
  void _followCodes(CardsDependencies dependencies) {
    final until = DateTime.now().add(_followFor);
    var asking = false;
    _follow = Timer.periodic(_followEvery, (timer) async {
      if (asking) {
        return;
      }
      if (DateTime.now().isAfter(until)) {
        timer.cancel();
        return;
      }
      asking = true;
      final result = await dependencies.orders.order(widget.order.id);
      asking = false;
      if (!mounted || result is! Ok<CardOrder>) {
        return;
      }
      final order = result.value;
      if (order.codes.isEmpty) {
        if (!_codesComing(order)) {
          timer.cancel();
        }
        return;
      }
      timer.cancel();
      await dependencies.vault.keep(order.id, order.codes);
      if (!mounted) {
        return;
      }
      Haptics.success();
      setState(() => _codes = order.codes);
    });
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

  /// After Face ID the card turns over to its code, the way a new purchase
  /// does, once the system's sheet has cleared the screen.
  Future<void> _unlock() async {
    final l10n = AppLocalizations.of(context);
    if (!await CardsScope.of(context).lock.unlock(l10n.unlockReason) ||
        !mounted) {
      return;
    }
    if (MediaQuery.of(context).disableAnimations) {
      setState(() => _locked = false);
      _flip.value = 1;
      return;
    }
    _flip.value = 0;
    await Future<void>.delayed(_sheetClears);
    if (!mounted) {
      return;
    }
    setState(() => _locked = false);
    Haptics.tap();
    await _flip.forward();
  }

  /// How long Face ID's sheet takes to slide away.
  static const Duration _sheetClears = Duration(milliseconds: 220);

  Future<void> _toggleUsed(String code) async {
    final used = !_used.contains(code);
    await CardsScope.of(context).vault.setUsed(code, used);
    Haptics.select();
    setState(() => used ? _used.add(code) : _used.remove(code));
  }

  Future<void> _showQr(
    CardBrand brand,
    ArtPalette palette,
    CardCode code,
  ) async {
    final box = _shown.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) {
      return;
    }
    // Asked for mid-turn: the card finishes at once.
    _flip.value = 1;
    final from = box.localToGlobal(Offset.zero) & box.size;
    // The page's card is hidden while the pass is up, so it can lose its foil
    // now and be bare when the pass lands back on it.
    final scratch = _scratched.add(code.code);
    setState(() => _passUp = true);
    await QrPass.open(
      context,
      from: from,
      brand: brand,
      palette: palette,
      code: code.code,
      used: _used.contains(code.code),
      onCopy: () => _copy(context, code.code),
      scratch: scratch,
    );
    if (mounted) {
      setState(() => _passUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand =
        widget.brand ??
        CardsScope.of(context).catalog.brandOf(widget.order.brandKey);
    final current = _codes.isEmpty
        ? null
        : _codes[_page.clamp(0, _codes.length - 1)];
    // The page takes the card's own colours, read from its art.
    return ArtPaletteBuilder(
      brand: brand,
      builder: (context, palette) =>
          _scaffold(context, brand, current, palette),
    );
  }

  Widget _scaffold(
    BuildContext context,
    CardBrand? brand,
    CardCode? current,
    ArtPalette palette,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tint = palette.tint;
    return SideBack(
      // The page's colour runs under the column; its SafeArea keeps the
      // content clear of it.
      edgeToEdge: true,
      close: !widget.fromHistory,
      tooltip: widget.fromHistory ? null : l10n.closeAction,
      onPressed: widget.fromHistory
          ? null
          : () => Navigator.of(context).popUntil((route) => route.isFirst),
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(widget.fromHistory ? widget.order.name : ''),
          automaticallyImplyLeading: !SideBack.active(context),
          leading: widget.fromHistory || SideBack.active(context)
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
                      SuccessSeal(animation: _seal),
                      const SizedBox(height: CardsSpace.md),
                      Text(
                        l10n.purchaseSuccess,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      NameText(
                        widget.order.name,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: CardsSpace.xl),
                    ],
                    if (brand != null) _cards(context, brand, palette),
                    const SizedBox(height: CardsSpace.lg),
                    // Whatever sits under the card rises in when it changes:
                    // the codes after Face ID, or after they arrive.
                    AnimatedSwitcher(
                      duration: CardsMotion.emphasized,
                      reverseDuration: CardsMotion.fast,
                      switchInCurve: CardsMotion.curve,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: _rise,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      child: _below(context, brand, current, palette),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _rise(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  /// The country of the item bought, for an issuer whose cards only work on
  /// their own country's site.
  String _countryOf(CardBrand? brand) {
    for (final item in brand?.items ?? const <CardItem>[]) {
      if (item.key == widget.order.itemKey) {
        return item.country;
      }
    }
    return '';
  }

  void _track(String action) =>
      CardsScope.of(context).analytics
          .codeAction(action, brand: widget.order.brandKey);

  /// What sits under the card: loading, locked, waiting, or the code's
  /// actions. Each state has its own key so the switcher moves between them.
  Widget _below(
    BuildContext context,
    CardBrand? brand,
    CardCode? current,
    ArtPalette palette,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_locked) {
      return _LockedPanel(key: const ValueKey('locked'), onUnlock: _unlock);
    }
    if (current == null) {
      return const _PendingCodes(key: ValueKey('pending'));
    }
    return Column(
      key: const ValueKey('codes'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
          step: redeemStep(
            brand?.redeem,
            code: current.code,
            country: _countryOf(brand),
          ),
          used: _used.contains(current.code),
          onToggleUsed: () => _toggleUsed(current.code),
          onQr: brand == null ? null : () => _showQr(brand, palette, current),
          onAction: _track,
        ),
        if ((brand?.redeemHint ?? '').isNotEmpty) ...[
          const SizedBox(height: CardsSpace.xl),
          _HowTo(hint: brand!.redeemHint),
        ],
        if (!widget.fromHistory) ...[
          const SizedBox(height: CardsSpace.xl),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            child: Text(l10n.doneAction),
          ),
        ],
      ],
    );
  }

  /// One card, or a pager of them with dots for several.
  Widget _cards(BuildContext context, CardBrand brand, ArtPalette palette) {
    final l10n = AppLocalizations.of(context);
    final codes = _codes.isEmpty || _locked ? const <CardCode?>[null] : _codes;
    final width = math.min(
      MediaQuery.sizeOf(context).width - CardsSpace.gutter * 2,
      440.0,
    );
    // The card answers the phone's tilt once it has turned to its code.
    Widget card(CardCode? code, {bool shown = true}) => Opacity(
      opacity: shown && _passUp ? 0 : 1,
      child: TiltCard(
        key: shown ? _shown : null,
        radius: CardsRadii.tile,
        strength: _flip,
        child: _FlipCard(
          animation: _flip,
          brand: brand,
          palette: palette,
          code: code?.code,
          used: code != null && _used.contains(code.code),
          qrScratched: code != null && _scratched.contains(code.code),
          onTap: code == null
              ? null
              : () {
                  _track('qr');
                  _showQr(brand, palette, code);
                },
        ),
      ),
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
              child: card(codes[index], shown: index == _page),
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

Future<void> _copy(BuildContext context, String code) =>
    _copyWithNotice(context, code, AppLocalizations.of(context).copiedNotice);

Future<void> _copyWithNotice(
  BuildContext context,
  String text,
  String notice,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  Haptics.tap();
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(notice)));
  }
}

/// The card's art turning over to show its code on the back: its one turn.
class _FlipCard extends StatelessWidget {
  const _FlipCard({
    required this.animation,
    required this.palette,
    required this.brand,
    required this.code,
    required this.used,
    required this.qrScratched,
    this.onTap,
  });

  final Animation<double> animation;
  final CardBrand brand;

  /// The back's colours: the art's own.
  final ArtPalette palette;
  final String? code;
  final bool used;
  final bool qrScratched;
  final VoidCallback? onTap;

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
                  child: CodeCardFace(
                    brand: brand,
                    palette: palette,
                    code: code!,
                    used: used,
                    qrScratched: qrScratched
                        ? kAlwaysCompleteAnimation
                        : kAlwaysDismissedAnimation,
                    onTap: onTap,
                  ),
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
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.code,
    required this.name,
    required this.step,
    required this.used,
    required this.onToggleUsed,
    required this.onAction,
    this.onQr,
  });

  final CardCode code;
  final String name;

  /// The one-tap way to redeem it; null where there is none.
  final RedeemStep? step;
  final bool used;
  final VoidCallback onToggleUsed;

  /// Told which action was taken, for analytics: copy, recharge, redeem_link,
  /// qr, gift, mark_used, mark_unused.
  final ValueChanged<String> onAction;

  /// Lifts the card out as a QR pass; no QR button without it.
  final VoidCallback? onQr;

  Future<void> _gift(BuildContext context) async {
    final text = AppLocalizations.of(context).giftMessage(name, code.code);
    await launchUrl(
      Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Calls the code in. A phone that cannot (an iPad, a browser) gets the
  /// number to dial from another, rather than nothing.
  Future<void> _call(BuildContext context, String dial) async {
    final notice = AppLocalizations.of(context).dialCopiedNotice;
    var called = false;
    try {
      called = await launchUrl(Uri(scheme: 'tel', path: dial));
    } on PlatformException {
      called = false;
    }
    if (!called && context.mounted) {
      await _copyWithNotice(context, dial, notice);
    }
  }

  /// Opens the issuer's page, the code on the clipboard first: not every page
  /// takes it from the link, and the customer leaves the app with it in hand.
  Future<void> _openIssuer(BuildContext context, String link) async {
    await _copyWithNotice(
      context,
      code.code,
      AppLocalizations.of(context).redeemCopiedNotice,
    );
    await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final step = this.step;
    final actions = <Widget>[
      _RoundAction(
        icon: Icons.copy_rounded,
        label: l10n.copyAction,
        primary: step == null,
        onTap: () {
          onAction('copy');
          _copy(context, code.code);
        },
      ),
      if (step != null)
        switch (step.kind) {
          RedeemKind.call => _RoundAction(
            icon: Icons.phone_forwarded_rounded,
            label: l10n.rechargeNow,
            primary: true,
            onTap: () {
              onAction('recharge');
              _call(context, step.value);
            },
          ),
          RedeemKind.link => _RoundAction(
            icon: Icons.open_in_new_rounded,
            label: l10n.redeemAction,
            primary: true,
            onTap: () {
              onAction('redeem_link');
              _openIssuer(context, step.value);
            },
          ),
        },
      if (onQr case final onQr?)
        _RoundAction(
          icon: Icons.qr_code_2_rounded,
          label: l10n.showQr,
          onTap: () {
            onAction('qr');
            onQr();
          },
        ),
      _RoundAction(
        icon: Icons.card_giftcard_rounded,
        label: l10n.sendAsGift,
        onTap: () {
          onAction('gift');
          _gift(context);
        },
      ),
      _RoundAction(
        icon: used ? Icons.undo_rounded : Icons.check_rounded,
        label: used ? l10n.markUnused : l10n.markUsed,
        onTap: () {
          onAction(used ? 'mark_unused' : 'mark_used');
          onToggleUsed();
        },
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
  const _LockedPanel({super.key, required this.onUnlock});

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
  const _PendingCodes({super.key});

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
