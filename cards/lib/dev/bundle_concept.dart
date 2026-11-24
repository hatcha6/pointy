// A design concept for «باقة اللاعب» (a PUBG top-up and a phone recharge
// bought together): its art, its tile on the shelf, and its own page. Dev
// only, safe to delete: reached from the preview harness (?screen=bundle,
// bundle-art, bundle-home), never imported by lib/main.dart, so it does not
// ship. Its words are the concept's, not yet in the localization files.

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../src/core/money.dart';
import '../src/data/models/catalog.dart';
import '../src/design/cards_layout.dart';
import '../src/design/cards_tokens.dart';
import '../src/shared/card_art.dart';
import '../src/shared/glass_bar.dart';
import '../src/shared/grouped.dart';
import '../src/shared/haptics.dart';
import '../src/shared/pill.dart';
import '../src/shared/pressable.dart';
import '../src/shared/section_header.dart';
import '../src/shared/side_back.dart';

// --- the offer ---------------------------------------------------------------

/// A PUBG top-up the bundle offers: UC and the app's price for it.
typedef _Uc = ({int uc, int dirhams});

const List<_Uc> _ucs = [
  (uc: 60, dirhams: 5500),
  (uc: 325, dirhams: 27000),
  (uc: 660, dirhams: 53000),
  (uc: 1800, dirhams: 135000),
];

/// Phone recharges, sold at face value.
const List<int> _recharges = [5000, 10000, 20000, 50000];

/// What the bundle saves: 3.5% of the PUBG top-up and a quarter dinar, down
/// to a quarter dinar. It is funded from the PUBG margin only: the phone
/// recharge, whose margin is the supplier's thin discount, is never
/// discounted.
Money bundleSaving(int ucDirhams) {
  final raw = 250 + ucDirhams * 35 ~/ 1000;
  return Money(raw - raw % 250);
}

String _dinars(Money m) => '${(m.dirhams / 1000).toStringAsFixed(2)} د.ل';

// --- the art -------------------------------------------------------------------

/// The bundle's art, at a card's proportions: a night sky lit amber, a PUBG
/// top-up card and a phone recharge card fanned over each other, a coin
/// with a plus between them, and the bundle's name.
class BundleArt extends StatelessWidget {
  const BundleArt({
    super.key,
    this.radius = CardsRadii.card,
    this.hero = false,
  });

  final double radius;

  /// The page's header: the name larger, the saving under it.
  final bool hero;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: kCardAspect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: CardsShadows.art,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: LayoutBuilder(
            builder: (context, c) {
              final s = c.maxWidth / 320;
              return Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: AlignmentDirectional.topEnd,
                        end: AlignmentDirectional.bottomStart,
                        colors: [Color(0xFF2A1458), Color(0xFF120A26)],
                      ),
                    ),
                  ),
                  // The amber glow the cards stand in.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: AlignmentDirectional(-0.55, -0.15),
                        radius: 0.9,
                        colors: [Color(0xAAF59E0B), Color(0x00F59E0B)],
                      ),
                    ),
                  ),
                  CustomPaint(painter: _Stars(seed: 7)),
                  // The phone recharge, behind.
                  PositionedDirectional(
                    end: 14 * s,
                    top: 22 * s,
                    child: Transform.rotate(
                      angle: -0.16,
                      child: _MiniCard(
                        width: 104 * s,
                        colors: const [Color(0xFF14B8A6), Color(0xFF065F55)],
                        icon: Icons.sim_card_rounded,
                        label: 'رصيد',
                      ),
                    ),
                  ),
                  // The PUBG top-up, in front.
                  PositionedDirectional(
                    end: 44 * s,
                    top: 50 * s,
                    child: Transform.rotate(
                      angle: 0.12,
                      child: _MiniCard(
                        width: 110 * s,
                        colors: const [Color(0xFFF5B83D), Color(0xFF9A5B0B)],
                        icon: Icons.sports_esports_rounded,
                        label: 'شدّات',
                      ),
                    ),
                  ),
                  // The plus that makes it one.
                  PositionedDirectional(
                    end: 26 * s,
                    top: 104 * s,
                    child: _Coin(size: 34 * s),
                  ),
                  PositionedDirectional(
                    start: 18 * s,
                    bottom: 16 * s,
                    end: 150 * s,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'باقة اللاعب',
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: (hero ? 30 : 26) * s,
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                          ),
                        ),
                        SizedBox(height: 4 * s),
                        Text(
                          'ببجي + رصيد هاتفك',
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 14 * s,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PositionedDirectional(
                    start: 14 * s,
                    top: 14 * s,
                    child: Transform.scale(
                      scale: math.max(s, 0.75),
                      alignment: AlignmentDirectional.topStart,
                      child: const Pill(
                        text: 'وفّر حتى 4.75 د.ل',
                        tone: PillTone.offer,
                        icon: Icons.local_offer_rounded,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard({
    required this.width,
    required this.colors,
    required this.icon,
    required this.label,
  });

  final double width;
  final List<Color> colors;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final h = width / kCardAspect;
    final s = width / 130;
    return Container(
      width: width,
      height: h,
      padding: EdgeInsets.all(10 * s),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12 * s),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white, size: 22 * s),
          const Spacer(),
          // The card's stripe.
          Container(
            height: 5 * s,
            margin: EdgeInsets.only(bottom: 6 * s),
            color: Colors.white.withValues(alpha: 0.35),
          ),
          Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15 * s,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _Coin extends StatelessWidget {
  const _Coin({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const LinearGradient(
        colors: [Color(0xFFFFE08A), Color(0xFFE09B12)],
      ),
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 10)],
    ),
    child: Icon(
      Icons.add_rounded,
      color: const Color(0xFF5B3305),
      size: size * 0.7,
    ),
  );
}

/// A few faint stars, the same on every paint.
class _Stars extends CustomPainter {
  const _Stars({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.45);
    for (var i = 0; i < 26; i++) {
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height * 0.7,
        ),
        random.nextDouble() * 1.2 + 0.3,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Stars old) => old.seed != seed;
}

// --- on the shelf ------------------------------------------------------------

/// The bundle as a shelf tile: its art, its name, and what it starts at
/// against the two bought apart.
class BundleTile extends StatelessWidget {
  const BundleTile({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = _ucs[1];
    final apart = Money(first.dirhams + _recharges[1]);
    final price = Money(apart.dirhams - bundleSaving(first.dirhams).dirhams);
    return Pressable(
      semanticLabel: 'باقة اللاعب',
      onTap: onTap ?? () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BundleArt(radius: CardsRadii.art),
          const SizedBox(height: CardsSpace.sm),
          Text('باقة اللاعب', maxLines: 1, style: theme.textTheme.titleSmall),
          Row(
            children: [
              Text(
                'من ${_dinars(price)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: CardsSpace.xs),
              Text(
                _dinars(apart),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The shelf with a «الباقات» row at its top, as it would open.
class BundleShelfConcept extends StatelessWidget {
  const BundleShelfConcept({super.key, required this.telecom});

  final List<CardBrand> telecom;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final tile = width < 600 ? 248.0 : 300.0;
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + CardsSpace.lg,
          bottom: CardsSpace.xxl,
        ),
        children: [
          const SectionHeader(title: 'الباقات'),
          SizedBox(
            height: tile / kCardAspect + 64,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.gutter,
              ),
              children: [
                SizedBox(
                  width: tile,
                  child: BundleTile(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BundlePageConcept(telecom: telecom),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: CardsSpace.md),
                SizedBox(width: tile, child: const _NextBundle()),
              ],
            ),
          ),
          const SectionHeader(title: 'اتصالات'),
          SizedBox(
            height: 164 / kCardAspect + 58,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.gutter,
              ),
              itemCount: telecom.length,
              separatorBuilder: (_, _) => const SizedBox(width: CardsSpace.md),
              itemBuilder: (context, i) => SizedBox(
                width: 164,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CardArt(brand: telecom[i], radius: CardsRadii.art),
                    const SizedBox(height: CardsSpace.sm),
                    Text(telecom[i].name),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The row's second place, waiting for the next bundle.
class _NextBundle extends StatelessWidget {
  const _NextBundle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: kCardAspect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(CardsRadii.art),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: Center(
              child: Text(
                'باقة السهرة\nنتفليكس + إنترنت',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// --- its page ----------------------------------------------------------------

/// The bundle's own page: built from two choices (how many UC, and which
/// network and how much credit), with the player's ID asked for once,
/// and a summary that keeps the saving in view as the choices change.
class BundlePageConcept extends StatefulWidget {
  const BundlePageConcept({super.key, required this.telecom});

  /// The networks it recharges, as the shelf has them.
  final List<CardBrand> telecom;

  @override
  State<BundlePageConcept> createState() => _BundlePageConceptState();
}

class _BundlePageConceptState extends State<BundlePageConcept> {
  int _uc = 1;
  int _network = 0;
  int _recharge = 1;

  void _pick(VoidCallback change) {
    Haptics.select();
    setState(change);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uc = _ucs[_uc];
    final recharge = _recharges[_recharge];
    final apart = Money(uc.dirhams + recharge);
    final saving = bundleSaving(uc.dirhams);
    final price = Money(apart.dirhams - saving.dirhams);
    final network = widget.telecom[_network];
    return SideBack(
      child: Scaffold(
        extendBodyBehindAppBar: GlassBar.extendsBody,
        appBar: const GlassBar(title: Text('باقة اللاعب')),
        bottomNavigationBar: _BuyBar(price: price, apart: apart),
        body: Builder(
          builder: (context) => ListView(
            padding: CardsLayout.page(
              context,
              top: CardsSpace.sm,
              bottom: CardsSpace.xl,
            ),
            children: [
              // On a wide screen (the iPhone Duo open) the art keeps a
              // card's size rather than filling the column.
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: const BundleArt(hero: true),
                ),
              ),
              const SizedBox(height: CardsSpace.lg),
              Text(
                'شدّات ببجي ورصيد هاتفك، بدفعة واحدة وبسعر أقل.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: CardsSpace.sm),
              const Wrap(
                spacing: CardsSpace.sm,
                runSpacing: CardsSpace.sm,
                children: [
                  Pill(
                    text: 'تصل الشدّات لحسابك مباشرة',
                    icon: Icons.bolt_rounded,
                    tone: PillTone.success,
                  ),
                  Pill(
                    text: 'الرصيد كرت يصلك فوراً',
                    icon: Icons.sim_card_rounded,
                    tone: PillTone.muted,
                  ),
                ],
              ),
              const SizedBox(height: CardsSpace.xl),
              _Step(
                number: '١',
                title: 'شدّات ببجي',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: CardsSpace.sm,
                      crossAxisSpacing: CardsSpace.sm,
                      childAspectRatio: 1.75,
                      children: [
                        for (var i = 0; i < _ucs.length; i++)
                          _Choice(
                            selected: i == _uc,
                            onTap: () => _pick(() => _uc = i),
                            title: '${_ucs[i].uc} شدّة',
                            subtitle: _dinars(Money(_ucs[i].dirhams)),
                            note:
                                'توفّر ${_dinars(bundleSaving(_ucs[i].dirhams))}',
                          ),
                      ],
                    ),
                    const SizedBox(height: CardsSpace.md),
                    const _PlayerField(),
                  ],
                ),
              ),
              const SizedBox(height: CardsSpace.lg),
              _Step(
                number: '٢',
                title: 'رصيد هاتفك',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        for (var i = 0; i < widget.telecom.length; i++) ...[
                          if (i > 0) const SizedBox(width: CardsSpace.sm),
                          Expanded(
                            child: _NetworkChoice(
                              brand: widget.telecom[i],
                              selected: i == _network,
                              onTap: () => _pick(() => _network = i),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: CardsSpace.md),
                    Wrap(
                      spacing: CardsSpace.sm,
                      runSpacing: CardsSpace.sm,
                      children: [
                        for (var i = 0; i < _recharges.length; i++)
                          ChoiceChip(
                            label: Text('${_recharges[i] ~/ 1000} دينار'),
                            selected: i == _recharge,
                            onSelected: (_) => _pick(() => _recharge = i),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: CardsSpace.xl),
              Grouped(
                title: 'باقتك',
                children: [
                  _Line(
                    label: '${uc.uc} شدّة ببجي',
                    value: _dinars(Money(uc.dirhams)),
                  ),
                  _Line(
                    label: 'رصيد ${network.name} ${recharge ~/ 1000} دينار',
                    value: _dinars(Money(recharge)),
                  ),
                  _Line(
                    label: 'وفّرت مع الباقة',
                    value: '− ${_dinars(saving)}',
                    color: const Color(0xFF079455),
                  ),
                  _Line(
                    label: 'المطلوب دفعه',
                    value: _dinars(price),
                    bold: true,
                  ),
                ],
              ),
              const SizedBox(height: CardsSpace.md),
              Text(
                'إن تعذّر شحن الشدّات يُعاد ثمن الباقة كاملاً لرصيدك، ولا يُحتسب كرت الرصيد منفصلاً.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title, required this.child});

  final String number;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: theme.colorScheme.primary,
              child: Text(
                number,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
            const SizedBox(width: CardsSpace.sm),
            Text(title, style: theme.textTheme.titleLarge),
          ],
        ),
        const SizedBox(height: CardsSpace.md),
        child,
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.selected,
    required this.onTap,
    required this.title,
    required this.subtitle,
    required this.note,
  });

  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String subtitle;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Pressable(
      semanticLabel: title,
      onTap: onTap,
      child: AnimatedContainer(
        duration: CardsMotion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.md,
          vertical: CardsSpace.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(CardsRadii.tile),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 1.6 : 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: theme.textTheme.titleSmall, maxLines: 1),
            Text(subtitle, style: theme.textTheme.bodySmall, maxLines: 1),
            const SizedBox(height: 2),
            Text(
              note,
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                color: const Color(0xFF079455),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkChoice extends StatelessWidget {
  const _NetworkChoice({
    required this.brand,
    required this.selected,
    required this.onTap,
  });

  final CardBrand brand;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pressable(
      semanticLabel: brand.name,
      onTap: onTap,
      child: AnimatedContainer(
        duration: CardsMotion.fast,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CardsRadii.art + 4),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            CardArt(brand: brand, radius: CardsRadii.art, shadow: false),
            const SizedBox(height: 4),
            Text(
              brand.name,
              style: Theme.of(context).textTheme.labelMedium,
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// The player's ID, as the app's top-ups ask for it, with the account's name
/// read back so a wrong number shows before paying.
class _PlayerField extends StatelessWidget {
  const _PlayerField();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          initialValue: '5123456789',
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'معرّف اللاعب (ID)',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: CardsSpace.sm),
        Row(
          children: [
            const Icon(
              Icons.verified_rounded,
              size: 16,
              color: Color(0xFF079455),
            ),
            const SizedBox(width: CardsSpace.xs),
            Text(
              'الحساب: ShadowFox_LY',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF079455),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.color,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        (bold ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)
            ?.copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.lg,
        vertical: CardsSpace.md,
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: PointyTypography.numeric(style!)),
        ],
      ),
    );
  }
}

/// The frosted bar under the thumb, as a brand page's: the price, what the
/// two would cost apart, and the one button.
class _BuyBar extends StatelessWidget {
  const _BuyBar({required this.price, required this.apart});

  final Money price;
  final Money apart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.86),
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline, width: 0.8),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.gutter,
                CardsSpace.md,
                CardsSpace.gutter,
                CardsSpace.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _dinars(price),
                          style: PointyTypography.numeric(
                            theme.textTheme.titleLarge!,
                          ),
                        ),
                        Text(
                          'بدلاً من ${_dinars(apart)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 148,
                    child: FilledButton(
                      onPressed: () => Haptics.tap(),
                      child: const Text('اشترِ الباقة'),
                    ),
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

// --- the board ----------------------------------------------------------------

/// The art at the sizes it is shown: a phone's shelf tile, a desktop's, the
/// page's header.
class BundleArtBoard extends StatelessWidget {
  const BundleArtBoard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget labelled(String label, double width, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: CardsSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: CardsSpace.sm),
          SizedBox(width: width, child: child),
        ],
      ),
    );
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(CardsSpace.xl),
        child: Wrap(
          spacing: CardsSpace.xl,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            labelled('رأس صفحة الباقة', 420, const BundleArt(hero: true)),
            labelled('بلاطة على الرف (248)', 248, const BundleTile()),
            labelled('بلاطة الهاتف (164)', 164, const BundleTile()),
          ],
        ),
      ),
    );
  }
}
