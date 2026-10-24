// Dev-only (safe to delete): the opening in the preview harness,
// `?screen=splash`, replayable, full or quick. Not shipped.
import 'package:flutter/material.dart';

import '../src/features/shell/cards_shell.dart';
import '../src/features/splash/splash_overlay.dart';

/// The app with the opening played over it, on the real logo pictures, and
/// buttons to play it again as a first open or a repeat one.
/// `?run=quick` sets the first play.
class SplashLab extends StatefulWidget {
  const SplashLab({super.key, this.run});

  final String? run;

  @override
  State<SplashLab> createState() => _SplashLabState();
}

class _SplashLabState extends State<SplashLab> {
  late SplashRun _run = widget.run == 'quick'
      ? SplashRun.quick
      : SplashRun.full;
  SplashArt? _art;
  int _take = 0;
  bool _playing = true;

  @override
  void initState() {
    super.initState();
    SplashArt.load().then((art) {
      if (mounted) {
        setState(() => _art = art);
      }
    });
  }

  void _play(SplashRun run) => setState(() {
    _run = run;
    _take++;
    _playing = true;
  });

  @override
  Widget build(BuildContext context) {
    final art = _art;
    return Stack(
      children: [
        const CardsShell(),
        if (_playing && art != null)
          Positioned.fill(
            child: SplashOverlay(
              key: ValueKey(_take),
              run: _run,
              art: art,
              onDone: () => setState(() => _playing = false),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          bottom: MediaQuery.paddingOf(context).bottom + 96,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  for (final (run, label) in const [
                    (SplashRun.full, 'أول فتح (كامل)'),
                    (SplashRun.quick, 'فتح متكرر (سريع)'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: FilledButton.tonal(
                          onPressed: () => _play(run),
                          child: Text(label),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
