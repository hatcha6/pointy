import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';
import '../../shared/pressable.dart';
import 'push.dart';

/// Shows the message that arrived while the app is open, where a phone's own
/// notification would be: it drops in along the top, opens what it is about
/// when tapped, and leaves on its own, or when swiped up.
class InAppNotices extends StatefulWidget {
  const InAppNotices({super.key, required this.push, required this.child});

  final Push push;
  final Widget child;

  /// How long a message stays up untouched.
  static const shownFor = Duration(seconds: 6);

  @override
  State<InAppNotices> createState() => _InAppNoticesState();
}

class _InAppNoticesState extends State<InAppNotices>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: CardsMotion.emphasized,
    reverseDuration: CardsMotion.standard,
  );
  PushNotice? _notice;
  Timer? _leave;

  /// Made once: one made in `build` would listen to [_shown] for good.
  late final Animation<Offset> _slide =
      Tween(begin: const Offset(0, -1.2), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _shown,
          curve: CardsMotion.spring,
          reverseCurve: Curves.easeInCubic,
        ),
      );

  @override
  void initState() {
    super.initState();
    widget.push.notice.addListener(_changed);
  }

  @override
  void didUpdateWidget(InAppNotices old) {
    super.didUpdateWidget(old);
    if (old.push != widget.push) {
      old.push.notice.removeListener(_changed);
      widget.push.notice.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.push.notice.removeListener(_changed);
    _leave?.cancel();
    _shown.dispose();
    super.dispose();
  }

  void _changed() {
    final notice = widget.push.notice.value;
    if (notice == null) {
      _hide();
      return;
    }
    Haptics.tap();
    setState(() => _notice = notice);
    _shown.forward(from: _shown.isDismissed ? 0 : _shown.value);
    _leave?.cancel();
    _leave = Timer(InAppNotices.shownFor, _dismiss);
  }

  /// Takes the message down; the next one may come up.
  void _dismiss() {
    if (widget.push.notice.value != null) {
      widget.push.notice.value = null;
    } else {
      _hide();
    }
  }

  void _hide() {
    _leave?.cancel();
    _shown.reverse().whenComplete(() {
      if (mounted && widget.push.notice.value == null) {
        setState(() => _notice = null);
      }
    });
  }

  void _open() {
    final open = _notice?.onOpen;
    _dismiss();
    open?.call();
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;
    return Stack(
      children: [
        widget.child,
        if (notice != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: SlideTransition(
                position: _slide,
                child: FadeTransition(
                  opacity: _shown,
                  child: Dismissible(
                    key: ObjectKey(notice),
                    direction: DismissDirection.up,
                    onDismissed: (_) {
                      _shown.value = 0;
                      _dismiss();
                    },
                    child: _NoticeCard(
                      notice: notice,
                      onOpen: notice.onOpen == null ? null : _open,
                      onClose: _dismiss,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice, this.onOpen, required this.onClose});

  final PushNotice notice;
  final VoidCallback? onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.md,
            CardsSpace.sm,
            CardsSpace.md,
            0,
          ),
          child: Semantics(
            liveRegion: true,
            container: true,
            button: onOpen != null,
            onTapHint: onOpen == null ? null : l10n.notificationOpenAction,
            child: Material(
              color: scheme.surfaceContainerHighest,
              elevation: 8,
              shadowColor: Colors.black38,
              borderRadius: BorderRadius.circular(CardsRadii.card),
              clipBehavior: Clip.antiAlias,
              child: Pressable(
                onTap: onOpen ?? onClose,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    CardsSpace.lg,
                    CardsSpace.md,
                    CardsSpace.xs,
                    CardsSpace.md,
                  ),
                  child: Row(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(CardsSpace.sm),
                          child: Icon(
                            Icons.notifications_active_rounded,
                            size: 22,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: CardsSpace.md),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (notice.title.isNotEmpty)
                              Text(
                                notice.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            if (notice.body.isNotEmpty)
                              Text(
                                notice.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      // Above the navigator there is no overlay for a
                      // tooltip: the label is for screen readers.
                      Semantics(
                        label: l10n.closeAction,
                        button: true,
                        excludeSemantics: true,
                        child: IconButton(
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
