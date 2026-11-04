import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/remote_session.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/remote_sessions_view_model.dart';

/// «الجلسات عن بُعد»: every sign-in from outside the shop, with its device,
/// where it came from and when it ends, and a way to end it. The same
/// section on «إعداداتي» (one's own) and on a user's page in user management.
class RemoteSessionsSection extends StatefulWidget {
  const RemoteSessionsSection({
    super.key,
    required this.viewModel,
    required this.canRevoke,
    required this.isOwn,
  });

  final RemoteSessionsViewModel viewModel;

  /// Whether the end button shows: always for one's own sessions, and for
  /// someone else's only to whoever may change users.
  final bool canRevoke;
  final bool isOwn;

  @override
  State<RemoteSessionsSection> createState() => _RemoteSessionsSectionState();
}

class _RemoteSessionsSectionState extends State<RemoteSessionsSection> {
  @override
  void initState() {
    super.initState();
    // Every visit reads afresh: a session may have ended, or a device signed
    // in, since the last one. What was read before stays up meanwhile.
    widget.viewModel.load();
  }

  @override
  void didUpdateWidget(covariant RemoteSessionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewModel, widget.viewModel)) {
      widget.viewModel.load();
    }
  }

  Future<void> _revoke(RemoteSession session) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PointyDestructiveConfirmationDialog(
        icon: Icons.logout,
        title: l10n.remoteSessionRevokeTitle,
        message: session.isCurrent
            ? l10n.remoteSessionRevokeCurrentMessage
            : l10n.remoteSessionRevokeMessage(
                remoteSessionTitle(l10n, session),
              ),
        confirmLabel: l10n.remoteSessionRevokeConfirm,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final ended = await widget.viewModel.revoke(session);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          ended ? l10n.remoteSessionRevoked : l10n.remoteSessionRevokeError,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        return PointyDetailSection(
          icon: Icons.devices_other_outlined,
          title: l10n.remoteSessionsTitle,
          trailing: viewModel.isLoading
              ? const SizedBox.square(
                  dimension: 20,
                  child: PointySpinner(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: l10n.remoteSessionsRefreshTooltip,
                  onPressed: viewModel.load,
                  icon: const Icon(Icons.sync),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.isOwn
                    ? l10n.remoteSessionsOwnSubtitle
                    : l10n.remoteSessionsUserSubtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
              const SizedBox(height: 12),
              _RemoteSessionsBody(
                viewModel: viewModel,
                canRevoke: widget.canRevoke,
                onRevoke: _revoke,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RemoteSessionsBody extends StatelessWidget {
  const _RemoteSessionsBody({
    required this.viewModel,
    required this.canRevoke,
    required this.onRevoke,
  });

  final RemoteSessionsViewModel viewModel;
  final bool canRevoke;
  final ValueChanged<RemoteSession> onRevoke;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!viewModel.hasLoaded) {
      if (viewModel.hasError) {
        return PointyInlineMessage.error(
          message: l10n.remoteSessionsLoadError,
          trailing: TextButton(
            onPressed: viewModel.load,
            child: Text(l10n.retryButton),
          ),
        );
      }
      return const Column(
        children: [PointySkeletonListTile(), PointySkeletonListTile()],
      );
    }
    if (viewModel.sessions.isEmpty) {
      return PointyEmptyState(
        icon: Icons.devices_outlined,
        title: l10n.remoteSessionsEmpty,
        message: l10n.remoteSessionsEmptyDescription,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (viewModel.hasError)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PointyInlineMessage.error(
              message: l10n.remoteSessionsLoadError,
              compact: true,
            ),
          ),
        for (final (index, session) in viewModel.sessions.indexed) ...[
          if (index > 0) const SizedBox(height: 8),
          RemoteSessionTile(
            session: session,
            isRevoking: viewModel.isRevoking(session.id),
            onRevoke: canRevoke && session.isActive
                ? () => onRevoke(session)
                : null,
          ),
        ],
      ],
    );
  }
}

class RemoteSessionTile extends StatelessWidget {
  const RemoteSessionTile({
    super.key,
    required this.session,
    required this.isRevoking,
    required this.onRevoke,
  });

  final RemoteSession session;
  final bool isRevoking;
  final VoidCallback? onRevoke;

  /// Narrower than this, facts stack one per line and the end button moves
  /// to the card's foot.
  static const double _compactWidth = 520;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final now = DateTime.now();
    final endedBy = session.endedByName.trim();
    final facts = [
      if (session.ipAddress.isNotEmpty)
        _Fact(
          icon: Icons.public,
          label: l10n.remoteSessionFactAddress,
          value: ltrIsolated(session.ipAddress),
        ),
      if (session.isActive && session.lastSeenAt != null)
        _Fact(
          icon: Icons.bolt_outlined,
          label: l10n.remoteSessionFactLastSeen,
          value: _ago(l10n, session.lastSeenAt!, now),
          exact: session.lastSeenAt,
        ),
      if (session.createdAt != null)
        _Fact(
          icon: Icons.login,
          label: l10n.remoteSessionFactSignedIn,
          value: _when(session.createdAt!),
        ),
      if (session.isActive && session.expiresAt != null)
        _Fact(
          icon: Icons.hourglass_bottom_outlined,
          label: l10n.remoteSessionFactExpires,
          value: _ahead(l10n, session.expiresAt!, now),
          exact: session.expiresAt,
        ),
      if (!session.isActive && session.endedAt != null)
        _Fact(
          icon: Icons.event_busy_outlined,
          label: l10n.remoteSessionFactEnded,
          value: _when(session.endedAt!),
        ),
      if (!session.isActive && endedBy.isNotEmpty)
        _Fact(
          icon: Icons.person_outline,
          label: l10n.remoteSessionFactEndedBy,
          value: endedBy,
        ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(
          color: session.isCurrent ? colors.primaryStrong : colors.line,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < _compactWidth;
          final revoke = _RevokeAction(
            isRevoking: isRevoking,
            onRevoke: onRevoke,
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DeviceBadge(session: session),
                    const SizedBox(width: 10),
                    Expanded(child: _Heading(session: session)),
                    if (!compact && onRevoke != null) revoke,
                  ],
                ),
                const SizedBox(height: 10),
                _FactGrid(facts: facts, compact: compact),
                if (compact && onRevoke != null) ...[
                  const SizedBox(height: 4),
                  Divider(height: 1, color: colors.line),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: revoke,
                  ),
                ] else
                  const SizedBox(height: 4),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The device's kind, in a tinted square: live sessions in the brand
/// colour, ended ones muted.
class _DeviceBadge extends StatelessWidget {
  const _DeviceBadge({required this.session});

  final RemoteSession session;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tint = session.isActive ? colors.primaryStrong : colors.mutedInk;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Icon(_platformIcon(session.platform), color: tint, size: 22),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.session});

  final RemoteSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final status = _statusPresentation(context, session.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          remoteSessionTitle(l10n, session),
          style: Theme.of(context).textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            PointyStatusPill(
              label: status.label,
              icon: status.icon,
              color: status.color,
              compact: true,
            ),
            if (session.isCurrent)
              PointyStatusPill(
                label: l10n.remoteSessionThisDevice,
                icon: Icons.my_location_outlined,
                color: colors.primaryStrong,
                compact: true,
              ),
          ],
        ),
      ],
    );
  }
}

class _Fact {
  const _Fact({
    required this.icon,
    required this.label,
    required this.value,
    this.exact,
  });

  final IconData icon;
  final String label;
  final String value;

  /// The moment a relative [value] stands for, shown on hover or long press.
  final DateTime? exact;
}

/// A session's facts as label and value pairs: one per line on a phone, with
/// the values in one column; side by side in cells on a wider screen.
class _FactGrid extends StatelessWidget {
  const _FactGrid({required this.facts, required this.compact});

  final List<_Fact> facts;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cells = [
      for (final fact in facts)
        _FactCell(fact: fact, labelWidth: compact ? 72 : null),
    ];
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final cell in cells)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: cell,
            ),
        ],
      );
    }
    return Wrap(
      spacing: 20,
      runSpacing: 6,
      children: [for (final cell in cells) SizedBox(width: 220, child: cell)],
    );
  }
}

class _FactCell extends StatelessWidget {
  const _FactCell({required this.fact, required this.labelWidth});

  final _Fact fact;
  final double? labelWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final label = Text(
      fact.label,
      style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
    );
    Widget value = Text(
      fact.value,
      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
    );
    if (fact.exact case final exact?) {
      value = Tooltip(message: _when(exact), child: value);
    }
    return Row(
      children: [
        Icon(fact.icon, size: 16, color: colors.mutedInk),
        const SizedBox(width: 6),
        if (labelWidth case final width?)
          SizedBox(width: width, child: label)
        else ...[
          label,
          const SizedBox(width: 8),
        ],
        Flexible(child: value),
      ],
    );
  }
}

class _RevokeAction extends StatelessWidget {
  const _RevokeAction({required this.isRevoking, required this.onRevoke});

  final bool isRevoking;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    if (isRevoking) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(
          dimension: 20,
          child: PointySpinner(strokeWidth: 2),
        ),
      );
    }
    return Tooltip(
      message: l10n.remoteSessionRevokeTooltip,
      child: TextButton.icon(
        onPressed: onRevoke,
        style: TextButton.styleFrom(foregroundColor: colors.danger),
        icon: const Icon(Icons.logout, size: 18),
        label: Text(l10n.remoteSessionRevokeButton),
      ),
    );
  }
}

/// A moment as one unbreakable, left-to-right run: «2026/10/29 18:29».
String _when(DateTime moment) =>
    ltrIsolated(formatDateTime(moment).replaceAll(' ', '\u00A0'));

/// How long ago [moment] was, as a person says it: «منذ 4 دقائق».
String _ago(AppLocalizations l10n, DateTime moment, DateTime now) {
  final elapsed = now.difference(moment);
  if (elapsed.inMinutes < 1) {
    return l10n.remoteSessionJustNow;
  }
  if (elapsed.inHours < 1) {
    return l10n.remoteSessionMinutesAgo(elapsed.inMinutes);
  }
  if (elapsed.inDays < 1) {
    return l10n.remoteSessionHoursAgo(elapsed.inHours);
  }
  return l10n.remoteSessionDaysAgo(elapsed.inDays);
}

/// How long until [moment]: «بعد 13 يومًا».
String _ahead(AppLocalizations l10n, DateTime moment, DateTime now) {
  final left = moment.difference(now);
  if (left.inDays >= 1) {
    return l10n.remoteSessionInDays(left.inDays);
  }
  return l10n.remoteSessionInHours(math.max(left.inHours, 1));
}

/// A session's device as a person reads it: the name it paired under, or
/// its kind of device and browser.
String remoteSessionTitle(AppLocalizations l10n, RemoteSession session) {
  if (session.deviceName.isNotEmpty) {
    return session.deviceName;
  }
  final platform = switch (session.platform) {
    'iphone' => l10n.remoteSessionPlatformIphone,
    'ipad' => l10n.remoteSessionPlatformIpad,
    'android' => l10n.remoteSessionPlatformAndroid,
    'windows' => l10n.remoteSessionPlatformWindows,
    'mac' => l10n.remoteSessionPlatformMac,
    'chromeos' => l10n.remoteSessionPlatformChromeOs,
    'linux' => l10n.remoteSessionPlatformLinux,
    _ => l10n.remoteSessionPlatformOther,
  };
  final browser = switch (session.browser) {
    'safari' => l10n.remoteSessionBrowserSafari,
    'chrome' => l10n.remoteSessionBrowserChrome,
    'edge' => l10n.remoteSessionBrowserEdge,
    'firefox' => l10n.remoteSessionBrowserFirefox,
    'samsung' => l10n.remoteSessionBrowserSamsung,
    'opera' => l10n.remoteSessionBrowserOpera,
    _ => '',
  };
  return browser.isEmpty
      ? platform
      : l10n.remoteSessionDeviceTitle(platform, browser);
}

IconData _platformIcon(String platform) {
  return switch (platform) {
    'iphone' || 'android' => Icons.smartphone_outlined,
    'ipad' => Icons.tablet_mac_outlined,
    'windows' || 'linux' || 'chromeos' => Icons.computer_outlined,
    'mac' => Icons.laptop_mac_outlined,
    _ => Icons.devices_other_outlined,
  };
}

({String label, IconData icon, Color color}) _statusPresentation(
  BuildContext context,
  RemoteSessionStatus status,
) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  return switch (status) {
    RemoteSessionStatus.active => (
      label: l10n.remoteSessionStatusActive,
      icon: Icons.check_circle_outline,
      color: colors.primaryStrong,
    ),
    RemoteSessionStatus.expired => (
      label: l10n.remoteSessionStatusExpired,
      icon: Icons.schedule_outlined,
      color: colors.mutedInk,
    ),
    RemoteSessionStatus.signedOut => (
      label: l10n.remoteSessionStatusSignedOut,
      icon: Icons.logout,
      color: colors.mutedInk,
    ),
    RemoteSessionStatus.revoked => (
      label: l10n.remoteSessionStatusRevoked,
      icon: Icons.block_outlined,
      color: colors.danger,
    ),
    RemoteSessionStatus.remoteSignInDisabled => (
      label: l10n.remoteSessionStatusDisabled,
      icon: Icons.public_off_outlined,
      color: colors.warning,
    ),
  };
}
