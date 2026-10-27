import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/settings/app_settings.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../card_payment/saved_cards_page.dart';

/// The phone's own choices, signed in or not: the code lock, light or dark,
/// and (once [AppSettings.languageChoice] is on) the language.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key});

  /// Each language named in itself, the way every phone's picker does: a
  /// customer who cannot read the current one still finds their own.
  static const Map<String, String> languageNames = {
    'ar': 'العربية',
    'en': 'English',
    'fr': 'Français',
  };

  /// Turning the lock off asks for Face ID first: otherwise anyone holding
  /// the phone could switch it off and read the codes.
  static Future<void> _setLock(BuildContext context, bool on) async {
    final dependencies = CardsScope.of(context);
    if (!on) {
      final reason = AppLocalizations.of(context).codeLockOffReason;
      if (!await dependencies.lock.unlock(reason)) {
        return;
      }
    }
    Haptics.select();
    dependencies.settings.setCodeLock(on);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = CardsScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Grouped(
        title: l10n.settingsSection,
        children: [
          // The web keeps no codes behind a lock.
          if (!kIsWeb)
            SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.lg,
              ),
              secondary: const Icon(Icons.lock_outline_rounded),
              title: Text(
                l10n.codeLockTitle,
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(l10n.codeLockBody),
              value: settings.codeLock,
              onChanged: (on) => _setLock(context, on),
            ),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: CardsSpace.lg,
            ),
            secondary: const Icon(Icons.insights_rounded),
            title: Text(
              l10n.shareUsageTitle,
              style: theme.textTheme.titleSmall,
            ),
            value: settings.shareUsage,
            onChanged: settings.setShareUsage,
          ),
          const _NotificationsSwitch(),
          // Cards are kept only on a phone.
          if (CardsScope.of(context).cards.available)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.lg,
              ),
              leading: const Icon(Icons.credit_card_rounded),
              title: Text(
                l10n.savedCardsSettings,
                style: theme.textTheme.titleSmall,
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => SavedCardsPage.open(context),
            ),
          _ChoiceRow(
            icon: Icons.contrast_rounded,
            title: l10n.themeTitle,
            child: SegmentedPill<ThemeMode>(
              segments: [
                (ThemeMode.system, l10n.themeSystem),
                (ThemeMode.light, l10n.themeLight),
                (ThemeMode.dark, l10n.themeDark),
              ],
              selected: settings.themeMode,
              onChanged: (mode) {
                Haptics.select();
                settings.setThemeMode(mode);
              },
            ),
          ),
          if (AppSettings.languageChoice)
            _ChoiceRow(
              icon: Icons.translate_rounded,
              title: l10n.languageTitle,
              child: SegmentedPill<String>(
                segments: [
                  for (final code in AppSettings.languages)
                    (code, languageNames[code]!),
                ],
                selected: settings.language,
                onChanged: (code) {
                  Haptics.select();
                  settings.setLanguage(code);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// A setting with a few choices: its name, then the choices across the row.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CardsSpace.lg,
        CardsSpace.md,
        CardsSpace.lg,
        CardsSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: CardsSpace.lg),
              Text(title, style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: CardsSpace.md),
          child,
        ],
      ),
    );
  }
}

/// The customer's notifications, where the build has them.
class _NotificationsSwitch extends StatelessWidget {
  const _NotificationsSwitch();

  @override
  Widget build(BuildContext context) {
    final push = CardsScope.of(context).push;
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: push,
      builder: (context, _) {
        if (!push.available) {
          return const SizedBox.shrink();
        }
        return SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(horizontal: CardsSpace.lg),
          secondary: const Icon(Icons.notifications_none_rounded),
          title: Text(
            l10n.notificationsTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          value: push.enabled,
          onChanged: (on) async {
            final messenger = ScaffoldMessenger.of(context);
            if (!await push.setEnabled(on) && on) {
              messenger.showSnackBar(
                SnackBar(content: Text(l10n.notificationsBlockedNotice)),
              );
            }
          },
        );
      },
    );
  }
}
