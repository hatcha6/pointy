import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// A keyboard shortcut as a cheat sheet lists it: the keys, and what they do.
class PointyShortcut {
  /// [keys] pressed together — `['Ctrl', 'Enter']` — drawn joined by "+".
  const PointyShortcut(this.keys, this.description) : either = false;

  /// [keys] that each do it alone, usually one per direction —
  /// `['Page ↓', 'Page ↑']` — drawn joined by "/".
  const PointyShortcut.either(this.keys, this.description) : either = true;

  /// Key captions, drawn as keycaps.
  final List<String> keys;
  final String description;

  /// Whether any one of [keys] does it, rather than all of them together.
  final bool either;
}

/// A titled run of related shortcuts in a cheat sheet.
class PointyShortcutGroup {
  const PointyShortcutGroup(this.title, this.shortcuts);

  final String title;
  final List<PointyShortcut> shortcuts;
}

/// The command key's caption: ⌘ on an Apple keyboard, Ctrl on every other.
String pointyCommandKeyLabel(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.macOS || platform == TargetPlatform.iOS
      ? '⌘'
      : 'Ctrl';
}

/// Opens a keyboard-shortcuts cheat sheet: grouped rows of keycaps and what
/// each one does, with an optional [subtitle] under the title for where the
/// keys work, and an optional [note] under them for what is not a key.
///
/// A shortcut nobody can find is a shortcut nobody uses, so a screen that has
/// any offers this from a keyboard button, the way the command palette
/// advertises Ctrl+K.
Future<void> showPointyShortcutsSheet(
  BuildContext context, {
  required String title,
  required List<PointyShortcutGroup> groups,
  String? subtitle,
  String? note,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => PointyShortcutsSheet(
      title: title,
      subtitle: subtitle,
      groups: groups,
      note: note,
    ),
  );
}

class PointyShortcutsSheet extends StatelessWidget {
  const PointyShortcutsSheet({
    super.key,
    required this.title,
    required this.groups,
    this.subtitle,
    this.note,
  });

  final String title;
  final List<PointyShortcutGroup> groups;
  final String? subtitle;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: colors.ink,
                          ),
                        ),
                        if (subtitle case final subtitle?) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
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
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            shortcut.description,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        PointyKeyCombo(
                          keys: shortcut.keys,
                          either: shortcut.either,
                        ),
                      ],
                    ),
                  ),
                SizedBox(height: spacing.md),
              ],
              if (note case final note?)
                Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The keys of one shortcut as keycaps joined by "+", or by "/" when [either]
/// key does it alone.
///
/// Always laid out left to right, even inside an RTL screen, so "Ctrl + Enter"
/// never reads as "Enter + Ctrl".
class PointyKeyCombo extends StatelessWidget {
  const PointyKeyCombo({
    super.key,
    required this.keys,
    this.either = false,
    this.dense = false,
  });

  final List<String> keys;

  /// Whether any one of [keys] does it alone, as with ↑ / ↓. A "+" between
  /// them would read as "press both".
  final bool either;

  /// The small size, for a caption under a button.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: dense ? 2 : 4),
                child: Text(
                  either ? '/' : '+',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ),
            PointyKeycap(label: keys[i], dense: dense),
          ],
        ],
      ),
    );
  }
}

/// One key, drawn as a keycap chip — the look of the command palette's ⌘K
/// hint.
class PointyKeycap extends StatelessWidget {
  const PointyKeycap({super.key, required this.label, this.dense = false});

  final String label;
  final bool dense;

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
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 5 : 8,
          vertical: dense ? 1 : 3,
        ),
        child: Text(
          label,
          style:
              (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
                  ?.copyWith(color: colors.ink, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
