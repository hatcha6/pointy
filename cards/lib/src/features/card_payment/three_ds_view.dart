import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_tokens.dart';

/// The card's bank asking the payer to confirm (3-D Secure): its page, with
/// the code it texted them, shown inside the app. Only the bank may ask for
/// and check that code, so the page is the bank's own; everything around it
/// is ours.
///
/// When the bank sends the payer back to [returnUrl], the page stops there
/// and [onAnswer] gets the bank's answer from the address, which the charge
/// is sent again with. The relay turns a bank that posts its answer into
/// the same address, so the answer is always in the query.
///
/// The page is Moamalat's, built for a desktop browser. Once it loads, the
/// view fits it to a phone ([_fitPage]): no zoom when the code field takes
/// focus, the field marked as a texted code (iOS offers it from Messages),
/// and the view only as tall as the page.
class ThreeDSView extends StatefulWidget {
  const ThreeDSView({
    super.key,
    required this.url,
    required this.returnUrl,
    required this.onAnswer,
  });

  final Uri url;
  final Uri returnUrl;
  final ValueChanged<Map<String, String>> onAnswer;

  @override
  State<ThreeDSView> createState() => _ThreeDSViewState();
}

class _ThreeDSViewState extends State<ThreeDSView> {
  WebViewController? _controller;
  bool _loading = true;
  bool _failed = false;
  bool _answered = false;

  /// How tall the bank's page is, once it has said; until then the view
  /// takes all the room it is given.
  double? _pageHeight;

  @override
  void initState() {
    super.initState();
    // No web view in widget tests or on the web: the step shows its frame.
    if (WebViewPlatform.instance == null) {
      _loading = false;
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel('PointyBank', onMessageReceived: _onPageMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _answer(request.url)
              ? NavigationDecision.prevent
              : NavigationDecision.navigate,
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) {
              _answer(url);
            }
          },
          onPageStarted: (_) => _setLoading(true),
          onPageFinished: (_) {
            _setLoading(false);
            _controller?.runJavaScript(_fitPage).ignore();
          },
          onWebResourceError: (error) {
            _setLoading(false);
            if (error.isForMainFrame ?? true) {
              setState(() => _failed = true);
            }
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  void _setLoading(bool loading) {
    if (mounted && loading != _loading) {
      setState(() => _loading = loading);
    }
  }

  void _onPageMessage(JavaScriptMessage message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final height = decoded['height'];
    if (height is num && height > 0 && mounted) {
      final next = height.toDouble();
      if ((next - (_pageHeight ?? 0)).abs() > 2) {
        setState(() => _pageHeight = next);
      }
    }
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
    });
    _controller?.loadRequest(widget.url);
  }

  /// true when [raw] is the return address carrying the bank's answer.
  bool _answer(String raw) {
    final url = Uri.tryParse(raw);
    final back = widget.returnUrl;
    if (url == null ||
        url.host != back.host ||
        url.path != back.path ||
        url.queryParameters.isEmpty) {
      return false;
    }
    if (!_answered) {
      _answered = true;
      widget.onAnswer(Map.of(url.queryParameters));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxHeight;
        final height = _failed || _pageHeight == null || !room.isFinite
            ? room
            : math.min(room, math.max(_pageHeight!, _minHeight));
        return AnimatedContainer(
          duration: CardsMotion.standard,
          curve: CardsMotion.curve,
          height: height.isFinite ? height : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
              color: Colors.white,
              child: Stack(
                children: [
                  if (controller != null)
                    Positioned.fill(
                      child: WebViewWidget(controller: controller),
                    )
                  else
                    const Center(
                      child: Icon(
                        Icons.account_balance_rounded,
                        size: 48,
                        color: Color(0x33101828),
                      ),
                    ),
                  if (_failed)
                    Positioned.fill(child: _LoadFailed(onRetry: _retry)),
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
      },
    );
  }
}

/// Never shorter than this, so a page that measures oddly stays usable.
const _minHeight = 240.0;

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // The card stays white in dark mode (the bank's page is), so its text
    // is dark whatever the theme.
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(CardsSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                size: 40,
                color: Color(0x66101828),
              ),
              const SizedBox(height: CardsSpace.md),
              Text(
                l10n.cardErrNetwork,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF344054),
                ),
              ),
              const SizedBox(height: CardsSpace.md),
              FilledButton(onPressed: onRetry, child: Text(l10n.retryAction)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Run on every page the bank shows. Fits a desktop page to the phone, and
/// reports the page's height to [_ThreeDSViewState._onPageMessage].
const _fitPage = r'''
(function () {
  var d = document;
  if (!d.body || !window.PointyBank) return;
  var head = d.head || d.body;

  // A focused field under 16px makes iOS zoom the page in, and it stays
  // zoomed: pin the scale.
  var meta = d.querySelector('meta[name=viewport]');
  if (!meta) {
    meta = d.createElement('meta');
    meta.name = 'viewport';
    head.appendChild(meta);
  }
  meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';

  if (!d.getElementById('pointy-bank')) {
    var style = d.createElement('style');
    style.id = 'pointy-bank';
    style.textContent = [
      'html { -webkit-text-size-adjust: 100%; }',
      'input, select, textarea, button { font-size: 16px !important; }',
      'input[type=text], input[type=tel], input[type=number], input[type=password] {',
      '  min-height: 48px; border-radius: 12px; box-sizing: border-box; }',
      'button, input[type=submit], input[type=button] {',
      '  min-height: 48px; border-radius: 12px !important; font-weight: 600; }',
      '.pointy-otp { width: 100% !important; font-size: 22px !important;',
      '  letter-spacing: 6px; text-align: center; direction: ltr; }'
    ].join('\n');
    head.appendChild(style);
  }

  // The code field: named for it, else the only field on the page. Marked
  // as a texted one-time code, iOS offers the bank's SMS code above the
  // keyboard ("OTP: 123456"), and the keyboard is the number pad.
  var fields = [].slice.call(d.querySelectorAll('input')).filter(function (i) {
    var t = (i.getAttribute('type') || 'text').toLowerCase();
    return (t === 'text' || t === 'tel' || t === 'number' || t === 'password') &&
      i.offsetParent !== null;
  });
  var otp = fields.filter(function (i) {
    return /otp|one.?time|code|pin|pass/i.test([i.name, i.id, i.placeholder].join(' '));
  })[0] || (fields.length === 1 ? fields[0] : null);
  if (otp) {
    // Moamalat's is a password field: iOS offers saved passwords there, not
    // the texted code, and the payer cannot check six digits as dots.
    if (otp.type === 'password') otp.type = 'text';
    otp.setAttribute('autocomplete', 'one-time-code');
    otp.setAttribute('inputmode', 'numeric');
    otp.setAttribute('autocorrect', 'off');
    otp.setAttribute('autocapitalize', 'off');
    otp.classList.add('pointy-otp');
    // Resend leaves the old, now dead, code in the field: empty it, ready
    // for the new one.
    [].forEach.call(d.querySelectorAll('button, input[type=button], input[type=submit], a'), function (b) {
      if (b.__pointyResend || !/resend|إعادة/i.test(b.value || b.textContent || '')) return;
      b.__pointyResend = true;
      b.addEventListener('click', function () { otp.value = ''; });
    });
  }

  // The page's real height: the lowest of its parts, not the window's.
  function report() {
    var bottom = 0;
    [].forEach.call(d.body.children, function (e) {
      var r = e.getBoundingClientRect();
      if (r.height) bottom = Math.max(bottom, r.bottom + window.scrollY);
    });
    if (bottom) PointyBank.postMessage(JSON.stringify({ height: Math.ceil(bottom + 16) }));
  }
  if (!window.__pointyBank) {
    window.__pointyBank = true;
    if (window.ResizeObserver) new ResizeObserver(report).observe(d.body);
  }
  report();
})();
''';
