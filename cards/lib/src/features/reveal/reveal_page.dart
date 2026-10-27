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
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/tilt_card.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/side_back.dart';
import 'card_faces.dart';
import 'qr_pass.dart';

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

  /// The card on show, measured to lift the QR pass out of it.
  final _shown = GlobalKey();

  /// While the QR pass is up, the card it lifted out of is gone from the
  /// page: the pass is that card.
  bool _passUp = false;
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
    final from = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _passUp = true);
    await QrPass.open(
      context,
      from: from,
      brand: brand,
      palette: palette,
      code: code.code,
      used: _used.contains(code.code),
      onCopy: () => _copy(context, code.code),
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
          redeemHint: brand?.redeemHint ?? '',
          used: _used.contains(current.code),
          onToggleUsed: () => _toggleUsed(current.code),
          onQr: brand == null ? null : () => _showQr(brand, palette, current),
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

  /// One flipping card, or a pager of them with dots for several.
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
          onCopy: code == null ? null : () => _copy(context, code.code),
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
    required this.palette,
    required this.brand,
    required this.code,
    required this.used,
    this.onCopy,
  });

  final Animation<double> animation;
  final CardBrand brand;

  /// The back's colours: the art's own.
  final ArtPalette palette;
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
                  child: CodeCardFace(
                    brand: brand,
                    palette: palette,
                    code: code!,
                    used: used,
                    onTap: onCopy,
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
    required this.redeemHint,
    required this.used,
    required this.onToggleUsed,
    this.onQr,
  });

  final CardCode code;
  final String name;
  final String redeemHint;
  final bool used;
  final VoidCallback onToggleUsed;

  /// Lifts the card out as a QR pass; no QR button without it.
  final VoidCallback? onQr;

  Future<void> _gift(BuildContext context) async {
    final text = AppLocalizations.of(context).giftMessage(name, code.code);
    await launchUrl(
      Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
      mode: LaunchMode.externalApplication,
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
      if (onQr case final onQr?)
        _RoundAction(
          icon: Icons.qr_code_2_rounded,
          label: l10n.showQr,
          onTap: onQr,
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
