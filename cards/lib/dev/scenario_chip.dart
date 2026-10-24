// Dev-only (safe to delete): the preview's "next purchase" chip. Not shipped.
import 'package:flutter/material.dart';

import 'preview_scenarios.dart';

/// Floats over every screen of the preview: how the next purchase will end.
/// Tap it to choose another; each purchase then moves it on by itself.
class ScenarioChip extends StatefulWidget {
  const ScenarioChip({super.key, required this.scenarios});

  final PreviewScenarios scenarios;

  @override
  State<ScenarioChip> createState() => _ScenarioChipState();
}

class _ScenarioChipState extends State<ScenarioChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.scenarios,
      builder: (context, _) {
        final next = widget.scenarios.next;
        return Material(
          color: const Color(0xE6101418),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          elevation: 6,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.science_outlined,
                          size: 16,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'الشراء التالي: ${next.short}',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _open
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: Colors.white70,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_open)
                  for (final outcome in PreviewOutcome.values)
                    InkWell(
                      onTap: () {
                        widget.scenarios.choose(outcome);
                        setState(() => _open = false);
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              outcome == next
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              size: 16,
                              color: Colors.white70,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '${outcome.short} · ${outcome.description}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}
