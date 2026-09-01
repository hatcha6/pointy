import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Opens the purchasing keyboard-shortcuts cheat sheet.
///
/// Purchasing has had a scan-then-arrow unit cycle for a while and no way to
/// discover it. A shortcut nobody can find is a shortcut nobody uses, so the
/// keys are listed the same way the POS lists its own — and the same way the
/// command palette advertises Ctrl+K.
Future<void> showPurchasingShortcutsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _PurchasingShortcutsSheet(),
  );
}

class _Shortcut {
  const _Shortcut(this.keys, this.description);

  /// Key captions, drawn as separate keycaps and always left-to-right, even in
  /// the RTL sheet.
  final List<String> keys;
  final String description;
}

class _ShortcutGroup {
  const _ShortcutGroup(this.title, this.shortcuts);

  final String title;
  final List<_Shortcut> shortcuts;
}

class _PurchasingShortcutsSheet extends StatelessWidget {
  const _PurchasingShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final isApple =
        theme.platform == TargetPlatform.macOS ||
        theme.platform == TargetPlatform.iOS;
    final commandKey = isApple ? '⌘' : 'Ctrl';

    final groups = [
      _ShortcutGroup(l10n.purchasingShortcutsSectionLines, [
        _Shortcut(const ['F2'], l10n.purchasingShortcutCycleUnit),
        _Shortcut(const ['F3'], l10n.purchasingShortcutOpenPricing),
        _Shortcut(const ['F4'], l10n.purchasingShortcutDeleteLine),
        _Shortcut(const ['↑', '↓'], l10n.purchasingShortcutCycleUnitArrows),
      ]),
      _ShortcutGroup(l10n.purchasingShortcutsSectionQuantity, [
        _Shortcut(const ['0-9', '↵'], l10n.purchasingShortcutTypeQuantity),
        _Shortcut(const ['+', '−'], l10n.purchasingShortcutStepQuantity),
        _Shortcut(const ['Esc'], l10n.purchasingShortcutClearEntry),
      ]),
      _ShortcutGroup(l10n.purchasingShortcutsSectionOrder, [
        _Shortcut(const ['F1'], l10n.purchasingShortcutOpenSettings),
        _Shortcut([commandKey, 'Enter'], l10n.purchasingShortcutSubmit),
      ]),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.lg,
            spacing.xs,
            spacing.lg,
            spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.keyboard_outlined, color: colors.primaryStrong),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.purchasingShortcutsTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colors.ink,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: spacing.md),
              for (final group in groups) ...[
                Text(
                  group.title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: spacing.xs),
                for (final shortcut in group.shortcuts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        // The keycaps read as keys, not text, so they stay
                        // left-to-right inside the RTL sheet.
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final key in shortcut.keys) ...[
                                _Keycap(label: key),
                                const SizedBox(width: 4),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            shortcut.description,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                SizedBox(height: spacing.md),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Keycap extends StatelessWidget {
  const _Keycap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Container(
      constraints: const BoxConstraints(minWidth: 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: colors.lineStrong),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: colors.ink,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
