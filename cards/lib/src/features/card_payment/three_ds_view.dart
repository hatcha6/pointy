import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The card's bank asking the payer to confirm (3-D Secure): its page, with
/// the code it texted them, shown inside the app. Only the bank may ask for
/// and check that code, so the page is the bank's own; everything around it
/// is ours.
///
/// When the bank sends the payer back to [returnUrl], the page stops there
/// and [onAnswer] gets the bank's answer from the address, which the charge
/// is sent again with. The relay turns a bank that posts its answer into
/// the same address, so the answer is always in the query.
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
  bool _answered = false;

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
          onPageFinished: (_) => _setLoading(false),
          onWebResourceError: (_) => _setLoading(false),
        ),
      )
      ..loadRequest(widget.url);
  }

  void _setLoading(bool loading) {
    if (mounted && loading != _loading) {
      setState(() => _loading = loading);
    }
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: Colors.white,
        child: Stack(
          children: [
            if (controller != null)
              Positioned.fill(child: WebViewWidget(controller: controller))
            else
              const Center(
                child: Icon(
                  Icons.account_balance_rounded,
                  size: 48,
                  color: Color(0x33101828),
                ),
              ),
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
    );
  }
}
