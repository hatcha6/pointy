import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'logo_geometry.dart';
import 'logo_morph_painter.dart';

/// The tile's size: the native splash draws the same tile at the same size
/// in the same place (`tool/render_splash_test.dart`), so the hand-over from
/// the system's splash to this one cannot be seen.
const double kSplashTileSize = 128;

/// The two logo pictures the opening starts and ends on, decoded before the
/// first frame so they are there from it. Either may be missing (a decode
/// failure); the drawn mark stands in.
class SplashArt {
  const SplashArt({this.daftar, this.cards});

  final ui.Image? daftar;
  final ui.Image? cards;

  static const _daftar = 'assets/branding/daftar_mark.png';
  static const _cards = 'assets/branding/cards_mark.png';

  /// Both pictures at the tile's size on this screen.
  static Future<SplashArt> load() async {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final ratio = views.isEmpty ? 3.0 : views.first.devicePixelRatio;
    final pixels = (kSplashTileSize * ratio).round();
    Future<ui.Image?> decode(String asset) async {
      try {
        final data = await rootBundle.load(asset);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(),
          targetWidth: pixels,
          targetHeight: pixels,
        );
        return (await codec.getNextFrame()).image;
      } catch (_) {
        return null;
      }
    }

    final (daftar, cards) = await (decode(_daftar), decode(_cards)).wait;
    return SplashArt(daftar: daftar, cards: cards);
  }
}

/// What the app opens with: how much plays, and the pictures it plays on.
class SplashOpening {
  const SplashOpening(this.run, {this.art = const SplashArt()});

  final SplashRun run;
  final SplashArt art;
}

/// How much of the opening plays.
enum SplashRun {
  /// The whole story with the name: the first open, and again after a while.
  full,

  /// The mark turning over, quickly: every other open.
  quick,
}

/// When the full opening was last played, so an app opened many times a day
/// shows it once and then gets out of the way.
abstract final class SplashMemory {
  static const _key = 'cards.splash.full_at';
  static const fullEvery = Duration(hours: 6);

  /// This open's run, remembered as it is decided. Never holds the start up:
  /// storage that is slow or broken gives the quick run.
  static Future<SplashRun> next({DateTime? now}) async {
    final at = now ?? DateTime.now();
    try {
      final prefs = SharedPreferencesAsync();
      final last = await prefs
          .getInt(_key)
          .timeout(const Duration(milliseconds: 300));
      if (last != null &&
          at.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
              fullEvery) {
        return SplashRun.quick;
      }
      unawaited(
        prefs.setInt(_key, at.millisecondsSinceEpoch).catchError((_) {}),
      );
      return SplashRun.full;
    } catch (_) {
      return SplashRun.quick;
    }
  }
}

/// The opening over the app: the Daftar tile from the system's splash turns
/// into the card app's, the name follows, then the tile swells a touch and
/// everything fades into the app, which has been building underneath all
/// along. A tap skips it; reduced motion skips straight to the end.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({
    super.key,
    required this.run,
    this.art = const SplashArt(),
    this.onDone,
  });

  final SplashRun run;
  final SplashArt art;
  final VoidCallback? onDone;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with TickerProviderStateMixin {
  late final bool _full = widget.run == SplashRun.full;
  late final AnimationController _story = AnimationController(
    vsync: this,
    // The full story ends on a short hold, so the finished name can be read.
    duration: Duration(milliseconds: _full ? 1190 : 420),
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _full ? 300 : 220),
  );

  /// The mark's share of the story: the name comes in at its end.
  late final Animation<double> _mark = CurvedAnimation(
    parent: _story,
    curve: Interval(0, _full ? 0.69 : 1),
  );

  @override
  void initState() {
    super.initState();
    // Start once the first frame is up: that frame also builds the app
    // underneath, and the tile stands still while it does, exactly as the
    // system's splash left it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _play());
  }

  Future<void> _play() async {
    if (!mounted) {
      return;
    }
    if (MediaQuery.of(context).disableAnimations) {
      _story.value = 1;
    } else {
      await _story.forward().orCancel.catchError((_) {});
    }
    await _leave();
  }

  Future<void> _leave() async {
    if (!mounted || _exit.isAnimating || _exit.isCompleted) {
      return;
    }
    await _exit.forward().orCancel.catchError((_) {});
    widget.onDone?.call();
  }

  void _skip() {
    _story.stop();
    _leave();
  }

  @override
  void dispose() {
    _story.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final fade = CurvedAnimation(parent: _exit, curve: Curves.easeIn);
    final swell = Tween(begin: 1.0, end: 1.14).animate(fade);
    final nameStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: FadeTransition(
        opacity: ReverseAnimation(fade),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: Stack(
            children: [
              // The tile stays dead centre, where the system's splash put it.
              Center(
                child: ScaleTransition(
                  scale: swell,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: const Size.square(kSplashTileSize),
                      painter: LogoMorphPainter(
                        progress: _mark,
                        daftar: widget.art.daftar,
                        cards: widget.art.cards,
                      ),
                    ),
                  ),
                ),
              ),
              if (_full)
                Align(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.only(top: kSplashTileSize + 84),
                    child: _Name(
                      story: _story,
                      daftar: l10n.splashDaftar,
                      cards: l10n.splashCards,
                      style: nameStyle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «دفتر», then «كروت» joining it in amber as the cards land.
class _Name extends StatelessWidget {
  const _Name({
    required this.story,
    required this.daftar,
    required this.cards,
    required this.style,
  });

  final Animation<double> story;
  final String daftar;
  final String cards;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final first = CurvedAnimation(
      parent: story,
      curve: const Interval(0, 0.27, curve: Curves.easeOut),
    );
    final second = CurvedAnimation(
      parent: story,
      curve: const Interval(0.49, 0.82, curve: Curves.easeOutCubic),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: first,
          child: Text(daftar, style: style),
        ),
        const SizedBox(width: 8),
        FadeTransition(
          opacity: second,
          child: SlideTransition(
            // From the far side, the way the line reads.
            position: Tween(
              begin: const Offset(-0.25, 0),
              end: Offset.zero,
            ).animate(second),
            child: Text(
              cards,
              style: style?.copyWith(color: LogoGeometry.amber),
            ),
          ),
        ),
      ],
    );
  }
}
