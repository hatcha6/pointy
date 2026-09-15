import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Opens the POS keyboard-shortcuts cheat sheet: a labeled, keycap-styled list
/// of every till shortcut, so cashiers who don't use shortcuts can still see
/// and recognise them (mirroring how the command palette advertises ⌘/Ctrl K).
Future<void> showPosShortcutsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _PosShortcutsSheet(),
  );
}

/// One shortcut: its key(s) and what it does.
class _PosShortcut {
  const _PosShortcut(this.keys, this.description);

  /// Key captions, shown as separate keycaps (e.g. `['Page ↓', 'Page ↑']` or
  /// `['Ctrl', 'Enter']`). Always drawn left-to-right, even in the RTL sheet.
  final List<String> keys;
  final String description;
}

class _PosShortcutGroup {
  const _PosShortcutGroup(this.title, this.shortcuts);

  final String title;
  final List<_PosShortcut> shortcuts;
}

class _PosShortcutsSheet extends StatelessWidget {
  const _PosShortcutsSheet();

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
      _PosShortcutGroup(l10n.posShortcutsSectionInvoices, [
        _PosShortcut(const ['F1'], l10n.posShortcutNewInvoice),
        _PosShortcut(const ['Page ↓', 'Page ↑'], l10n.posShortcutCycleInvoices),
      ]),
      _PosShortcutGroup(l10n.posShortcutsSectionItems, [
        _PosShortcut(const ['F2'], l10n.posShortcutCycleUnit),
        _PosShortcut(const ['F4'], l10n.posShortcutDeleteLine),
      ]),
      _PosShortcutGroup(l10n.posShortcutsSectionCheckout, [
        _PosShortcut([commandKey, 'Enter'], l10n.posShortcutCheckout),
      ]),
      // The payment keys are modifier-prefixed so a bare digit always lands in
      // the amount field — which makes them worth spelling out here, since a
      // cashier will not discover them by accident.
      _PosShortcutGroup(l10n.posShortcutsSectionPayment, [
        _PosShortcut([commandKey, '1'], l10n.posShortcutPayCash),
        _PosShortcut([commandKey, '2'], l10n.posShortcutPayCard),
        _PosShortcut([commandKey, '3'], l10n.posShortcutPayTransfer),
        _PosShortcut(const ['Enter'], l10n.posShortcutConfirmPayment),
        _PosShortcut(const ['Esc'], l10n.posShortcutCancelPayment),
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
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Text(
                      l10n.posShortcutsTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                l10n.posShortcutsSubtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
              SizedBox(height: spacing.md),
              for (final group in groups) ...[
                Padding(
                  padding: EdgeInsetsDirectional.only(bottom: spacing.xs),
                  child: Text(
                    group.title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.mutedInk,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                for (final shortcut in group.shortcuts)
                  _ShortcutRow(shortcut: shortcut),
                SizedBox(height: spacing.md),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.shortcut});

  final _PosShortcut shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shortcut.description,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.ink),
            ),
          ),
          const SizedBox(width: 12),
          // Keys are always laid out left-to-right, even inside the RTL sheet,
          // so "Ctrl Enter" / "Page ↓" never reorder.
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < shortcut.keys.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '/',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                  _KeyCap(label: shortcut.keys[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single keycap chip, styled like the command-palette ⌘K hint.
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
