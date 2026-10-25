import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/phone.dart';
import '../../core/result.dart';
import '../../data/models/customer.dart';
import '../../data/models/order.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/grouped.dart';
import '../../shared/pill.dart';
import '../../shared/money_text.dart';
import '../../shared/relay_error_text.dart';
import '../sign_in/sign_in_sheet.dart';
import '../../shared/haptics.dart';
import 'about_section.dart';
import 'settings_section.dart';

/// The customer: their number, their credit and where it came from, the
/// devices signed in, signing out, and deleting the account (App Store
/// guideline 5.1.1(v)).
class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = CardsScope.of(context).auth;
    return SafeArea(
      child: ValueListenableBuilder(
        valueListenable: auth.session,
        builder: (context, session, _) => session == null
            ? const _SignedOut()
            : _SignedIn(key: ValueKey(session.sessionId), phone: session.phone),
      ),
    );
  }
}

/// Signed out, the tab is still the phone's settings: the way in, then the
/// choices that need no account.
class _SignedOut extends StatelessWidget {
  const _SignedOut();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        CardsSpace.gutter,
        CardsSpace.xl,
        CardsSpace.gutter,
        MediaQuery.paddingOf(context).bottom + 96,
      ),
      children: [
        Text(l10n.tabAccount, style: theme.textTheme.headlineLarge),
        const SizedBox(height: CardsSpace.lg),
        Grouped(
          children: [
            Padding(
              padding: const EdgeInsets.all(CardsSpace.xl),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.phone_iphone_rounded,
                      size: 30,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: CardsSpace.lg),
                  Text(
                    l10n.accountSignedOutTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: CardsSpace.xs),
                  Text(
                    l10n.accountSignedOutBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: CardsSpace.lg),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => ensureSignedIn(context),
                      child: Text(l10n.signInAction),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: CardsSpace.xl),
        const SettingsSection(),
        const SizedBox(height: CardsSpace.xl),
        const AboutSection(),
      ],
    );
  }
}

class _SignedIn extends StatefulWidget {
  const _SignedIn({super.key, required this.phone});

  final String phone;

  @override
  State<_SignedIn> createState() => _SignedInState();
}

class _SignedInState extends State<_SignedIn> {
  CreditStatement? _credit;
  List<DeviceSession> _devices = const [];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Once: this also runs on every keyboard, rotation or theme change.
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final dependencies = CardsScope.of(context);
    final credit = await dependencies.orders.credit();
    final devices = await dependencies.auth.devices();
    if (!mounted) {
      return;
    }
    setState(() {
      if (credit case Ok(:final value)) {
        _credit = value;
      }
      if (devices case Ok(:final value)) {
        _devices = value;
      }
    });
  }

  Future<void> _signOutOthers() async {
    final l10n = AppLocalizations.of(context);
    final result = await CardsScope.of(context).auth.signOutOtherDevices();
    if (!mounted) {
      return;
    }
    final text = result is Ok
        ? l10n.signOutOthersDone
        : relayErrorText(l10n, (result as Error).exception);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    await _load();
  }

  Future<void> _signOut() async {
    final dependencies = CardsScope.of(context);
    await dependencies.auth.signOut();
    await dependencies.vault.clear();
    await dependencies.cards.clear();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    // A step that cannot be undone is felt before it is read.
    Haptics.warning();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteAccountTitle),
        content: Text(l10n.deleteAccountBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelAction),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final dependencies = CardsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await dependencies.auth.deleteAccount();
    if (result is Ok) {
      await dependencies.vault.clear();
      await dependencies.cards.clear();
      messenger.showSnackBar(SnackBar(content: Text(l10n.accountDeleted)));
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(relayErrorText(l10n, (result as Error).exception)),
        ),
      );
    }
  }

  String _entryLabel(AppLocalizations l10n, CreditEntry entry) =>
      switch (entry.kind) {
        'order' => l10n.creditOrder,
        'refund' => l10n.creditRefund,
        'release' => l10n.creditRelease,
        _ => l10n.creditLatePayment,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final national = widget.phone.startsWith('218')
        ? widget.phone.substring(3)
        : widget.phone;
    final credit = _credit;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          CardsSpace.xl,
          CardsSpace.gutter,
          MediaQuery.paddingOf(context).bottom + 96,
        ),
        children: [
          Text(l10n.tabAccount, style: theme.textTheme.headlineLarge),
          const SizedBox(height: CardsSpace.lg),
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_rounded,
                  color: theme.colorScheme.onPrimaryContainer,
                  size: 28,
                ),
              ),
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.phoneLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        LibyanPhone.display(national),
                        textDirection: TextDirection.ltr,
                        style: PointyTypography.numeric(
                          theme.textTheme.titleLarge!,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: CardsSpace.xl),
          _CreditHero(
            balance: credit == null ? null : formatMoney(l10n, credit.balance),
          ),
          if (credit != null && credit.entries.isNotEmpty) ...[
            const SizedBox(height: CardsSpace.xl),
            Grouped(
              title: l10n.creditHistory,
              children: [
                for (final entry in credit.entries.take(5))
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: CardsSpace.lg,
                    ),
                    leading: Icon(
                      entry.amount.isPositive
                          ? Icons.south_west_rounded
                          : Icons.north_east_rounded,
                    ),
                    title: Text(
                      _entryLabel(l10n, entry),
                      style: theme.textTheme.titleSmall,
                    ),
                    trailing: Text(
                      '${entry.amount.isPositive ? '+' : '−'} ${formatMoney(l10n, entry.amount.isPositive ? entry.amount : entry.amount * -1)}',
                      style:
                          PointyTypography.numeric(theme.textTheme.titleSmall!)
                              .copyWith(
                                color: entry.amount.isPositive
                                    ? theme.colorScheme.tertiary
                                    : null,
                              ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: CardsSpace.xl),
          Grouped(
            title: l10n.devicesTitle,
            children: [
              for (final device in _devices)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: CardsSpace.lg,
                  ),
                  leading: Icon(
                    device.platform == 'web'
                        ? Icons.language_rounded
                        : Icons.smartphone_rounded,
                  ),
                  title: Text(
                    device.platform == 'web'
                        ? l10n.deviceBrowser
                        : (device.deviceName.isEmpty
                              ? device.platform
                              : device.deviceName),
                    style: theme.textTheme.titleSmall,
                  ),
                  trailing: device.current ? Pill(text: l10n.thisDevice) : null,
                ),
              if (_devices.length > 1)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: CardsSpace.lg,
                  ),
                  leading: const Icon(Icons.devices_other_rounded),
                  title: Text(
                    l10n.signOutOthers,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: CardsTheme.link(theme),
                    ),
                  ),
                  onTap: _signOutOthers,
                ),
            ],
          ),
          const SizedBox(height: CardsSpace.xl),
          const SettingsSection(),
          const SizedBox(height: CardsSpace.xl),
          const AboutSection(),
          const SizedBox(height: CardsSpace.xl),
          Grouped(
            title: l10n.accountSection,
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: CardsSpace.lg,
                ),
                leading: const Icon(Icons.logout_rounded),
                title: Text(l10n.signOut, style: theme.textTheme.titleSmall),
                onTap: _signOut,
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: CardsSpace.lg,
                ),
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  l10n.deleteAccount,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                onTap: _delete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The credit as a card in the brand's teal, with two soft rings for depth.
class _CreditHero extends StatelessWidget {
  const _CreditHero({required this.balance});

  final String? balance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 2.1,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CardsRadii.card),
          gradient: const LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: [PointyColors.primary, PointyColors.primaryDark],
          ),
          boxShadow: CardsShadows.hero,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            PositionedDirectional(
              end: -40,
              top: -50,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.07),
                ),
              ),
            ),
            PositionedDirectional(
              end: 40,
              bottom: -70,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(CardsSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.creditTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const Spacer(),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      balance ?? '—',
                      style: PointyTypography.numeric(
                        theme.textTheme.headlineLarge!,
                      ).copyWith(color: Colors.white, fontSize: 36),
                    ),
                  ),
                  const SizedBox(height: CardsSpace.xs),
                  Text(
                    l10n.creditBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
