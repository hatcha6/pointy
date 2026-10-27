import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_logo.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';

/// The web app on a phone: a bar across the top, as Safari's own app banner
/// is, offering the app from its store. Every page has it (a shared link
/// lands on a brand's page, not the shelf). Closed, it stays away for two
/// weeks; never shown where the app has no listing yet, nor on a computer.
class GetAppBanner extends StatefulWidget {
  const GetAppBanner({super.key, required this.child});

  final Widget child;

  /// The listing for this phone, or null where there is none to offer.
  static Uri? storeFor(BuildContext context) {
    if (!kIsWeb) {
      return null;
    }
    final config = CardsScope.of(context).config;
    final url = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => config.iosStoreUrl,
      TargetPlatform.android => config.androidStoreUrl,
      _ => '',
    };
    return url.isEmpty ? null : Uri.tryParse(url);
  }

  @override
  State<GetAppBanner> createState() => _GetAppBannerState();
}

class _GetAppBannerState extends State<GetAppBanner> {
  static const _closedKey = 'get_app.closed_at';
  static const _away = Duration(days: 14);

  Uri? _store;
  bool _shown = false;
  bool _read = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_read) {
      return;
    }
    _read = true;
    _store = GetAppBanner.storeFor(context);
    if (_store != null) {
      _decide();
    }
  }

  Future<void> _decide() async {
    final preferences = CardsScope.of(context).preferences;
    int? closed;
    try {
      closed = await preferences?.getInt(_closedKey);
    } on Object {
      // Unreadable: offer it.
    }
    final away =
        closed != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(closed)) <
            _away;
    if (mounted && !away) {
      setState(() => _shown = true);
    }
  }

  void _close() {
    setState(() => _shown = false);
    final dependencies = CardsScope.of(context);
    dependencies.analytics.capture('get_app_closed');
    dependencies.preferences
        ?.setInt(_closedKey, DateTime.now().millisecondsSinceEpoch)
        .catchError((Object _) {});
  }

  void _open() {
    CardsScope.of(context).analytics
        .capture('get_app_tapped', {'platform': defaultTargetPlatform.name});
    launchUrl(_store!, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Column(
      children: [
        AnimatedSize(
          duration: CardsMotion.standard,
          curve: CardsMotion.curve,
          alignment: Alignment.topCenter,
          child: _shown
              ? _Bar(top: media.padding.top, onOpen: _open, onClose: _close)
              : const SizedBox(width: double.infinity),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            // The bar has taken the top inset.
            removeTop: _shown,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.top, required this.onOpen, required this.onClose});

  final double top;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          CardsSpace.xs,
          top + CardsSpace.sm,
          CardsSpace.md,
          CardsSpace.sm,
        ),
        child: Row(
          children: [
            // A label, not a tooltip: the bar sits above the navigator,
            // where there is no overlay for a tooltip to float in.
            Semantics(
              label: MaterialLocalizations.of(context).closeButtonTooltip,
              button: true,
              excludeSemantics: true,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ),
            const CardsLogo(size: 44),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                  ),
                  Text(
                    l10n.getAppBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: CardsSpace.sm),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: CardsSpace.lg),
                shape: const StadiumBorder(),
              ),
              onPressed: onOpen,
              child: Text(l10n.getAppAction),
            ),
          ],
        ),
      ),
    );
  }
}
