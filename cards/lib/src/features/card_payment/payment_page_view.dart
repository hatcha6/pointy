import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../design/cards_tokens.dart';
import '../../shared/side_back.dart';
import 'payment_frame.dart'
    if (dart.library.js_interop) 'payment_frame_web.dart';
import 'three_ds_view.dart';

/// How the payment page closed.
enum PaymentPageResult {
  /// Dafa's page said paid: its «المتابعة» opened the relay's return page.
  returned,

  /// The relay heard of the payment first ([PaymentPageView.settled]).
  settled,

  /// The payer closed it (✕, back), after paying, cancelling or neither.
  closed,
}

/// Dafa's bank-card page, inside the app, the way the payer's banking apps do
/// it: the page takes the screen, and the app closes it the moment the
/// payment is done, so the payer never has to find their way back.
///
/// It closes on whichever comes first:
/// - the page's «المتابعة» button, which goes to the relay's payment-return
///   page (the `return_url` the relay gave Dafa); the view stops there;
/// - [settled] turning true as [changes] fire: the relay heard from Dafa;
/// - the payer closing it, after paying or not. Whoever opened it then asks
///   the relay at once.
class PaymentPageView extends StatefulWidget {
  const PaymentPageView({
    super.key,
    required this.url,
    required this.changes,
    required this.settled,
  });

  final Uri url;
  final Listenable changes;
  final bool Function() settled;

  /// Shows the page over the app until it closes.
  static Future<PaymentPageResult> open(
    BuildContext context, {
    required Uri url,
    required Listenable changes,
    required bool Function() settled,
    ValueChanged<Route<PaymentPageResult>>? onRoute,
  }) {
    final route = MaterialPageRoute<PaymentPageResult>(
      settings: screenSettings('payment_page'),
      fullscreenDialog: true,
      // A bank card's details: never in a session replay.
      builder: (_) => Sensitive(
        child: PaymentPageView(url: url, changes: changes, settled: settled),
      ),
    );
    onRoute?.call(route);
    return Navigator.of(context)
        .push(route)
        .then((result) => result ?? PaymentPageResult.closed);
  }

  /// The relay's payment-return page, where «المتابعة» goes once paid.
  static const returnPath = '/v1/customers/payment-return';

  /// true when [url] is that page: the payer has paid and pressed «المتابعة».
  static bool isReturn(Uri url) => url.path == returnPath;

  @override
  State<PaymentPageView> createState() => _PaymentPageViewState();
}

class _PaymentPageViewState extends State<PaymentPageView> {
  WebViewController? _controller;
  bool _loading = true;
  bool _failed = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_onChange);
    // On the web the page is a frame ([PaymentFrame]); in widget tests
    // there is no web view and the page shows its outline.
    if (kIsWeb || WebViewPlatform.instance == null) {
      _loading = kIsWeb;
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _allow(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onUrlChange: (change) {
            final url = Uri.tryParse(change.url ?? '');
            if (url != null && PaymentPageView.isReturn(url)) {
              _close(PaymentPageResult.returned);
            }
          },
          onPageStarted: (_) => _setLoading(true),
          onPageFinished: (_) => _setLoading(false),
          onWebResourceError: (error) {
            _setLoading(false);
            if ((error.isForMainFrame ?? true) && mounted) {
              setState(() => _failed = true);
            }
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  @override
  void dispose() {
    widget.changes.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (widget.settled()) {
      _close(PaymentPageResult.settled);
    }
  }

  /// Whether the view may load [raw]. The return address closes it; a link
  /// for another app (a bank's own) goes to that app.
  bool _allow(String raw) {
    final url = Uri.tryParse(raw);
    if (url == null) {
      return false;
    }
    if (PaymentPageView.isReturn(url)) {
      _close(PaymentPageResult.returned);
      return false;
    }
    if (url.scheme != 'http' &&
        url.scheme != 'https' &&
        url.scheme != 'about') {
      launchUrl(url, mode: LaunchMode.externalApplication).ignore();
      return false;
    }
    return true;
  }

  /// This page's own route: closing removes it and nothing else, even when
  /// something else has already taken it away or opened above it.
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _close([PaymentPageResult result = PaymentPageResult.closed]) {
    final route = _route;
    if (_closing || !mounted || route == null || !route.isActive) {
      return;
    }
    _closing = true;
    Navigator.of(context).removeRoute(route, result);
  }

  void _setLoading(bool loading) {
    if (mounted && loading != _loading) {
      setState(() => _loading = loading);
    }
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
    });
    _controller?.loadRequest(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final controller = _controller;
    return SideBack(
      close: true,
      onPressed: _close,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: SideBack.active(context)
              ? null
              : IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _close,
                ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.cardPayTitle),
              // The address the payer would see in a browser: they are on
              // the gateway's page, not a copy of it.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: CardsSpace.xs),
                  Text(
                    widget.url.host,
                    textDirection: TextDirection.ltr,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
          centerTitle: true,
        ),
        body: ColoredBox(
          color: Colors.white,
          child: Stack(
            children: [
              if (kIsWeb)
                Positioned.fill(
                  child: PaymentFrame(
                    url: widget.url,
                    onLoaded: () => _setLoading(false),
                    onReturn: () => _close(PaymentPageResult.returned),
                  ),
                )
              else if (controller != null)
                Positioned.fill(child: WebViewWidget(controller: controller))
              else
                const Center(
                  child: Icon(
                    Icons.credit_card_rounded,
                    size: 48,
                    color: Color(0x33101828),
                  ),
                ),
              if (_failed)
                Positioned.fill(child: GatewayLoadFailed(onRetry: _retry)),
              if (_loading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
