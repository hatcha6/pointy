import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'theme_controller.dart';

/// One-tap light/dark toggle, intended for the drawer or an app bar. Reads the
/// [ThemeController] from the nearest [ThemeControllerScope] and rebuilds when
/// the mode changes.
class ThemeModeToggleButton extends StatelessWidget {
  const ThemeModeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeControllerScope.maybeOf(context);
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final isDark = controller.resolvedIsDark;
    return IconButton(
      tooltip: isDark ? l10n.switchToLightAction : l10n.switchToDarkAction,
      icon: Icon(
        isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      ),
      onPressed: controller.toggleLightDark,
    );
  }
}

/// Drawer row that names the current appearance and flips light/dark on tap.
class ThemeModeDrawerTile extends StatelessWidget {
  const ThemeModeDrawerTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeControllerScope.maybeOf(context);
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final isDark = controller.resolvedIsDark;
    return ListTile(
      leading: Icon(
        isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
      ),
      title: Text(
        l10n.appearanceSectionTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _modeLabel(l10n, controller.mode),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const ThemeModeToggleButton(),
      onTap: controller.toggleLightDark,
    );
  }
}

/// Full light / dark / system control for the settings surface.
class ThemeModeSelector extends StatelessWidget {
  const ThemeModeSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeControllerScope.maybeOf(context);
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    return SegmentedButton<ThemeMode>(
      segments: [
        ButtonSegment(
          value: ThemeMode.light,
          icon: const Icon(Icons.light_mode_outlined),
          label: Text(l10n.themeModeLight),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: const Icon(Icons.dark_mode_outlined),
          label: Text(l10n.themeModeDark),
        ),
        ButtonSegment(
          value: ThemeMode.system,
          icon: const Icon(Icons.brightness_auto_outlined),
          label: Text(l10n.themeModeSystem),
        ),
      ],
      selected: {controller.mode},
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        controller.setMode(selection.first);
      },
    );
  }
}

String _modeLabel(AppLocalizations l10n, ThemeMode mode) {
  return switch (mode) {
    ThemeMode.light => l10n.themeModeLight,
    ThemeMode.dark => l10n.themeModeDark,
    ThemeMode.system => l10n.themeModeSystem,
  };
}
