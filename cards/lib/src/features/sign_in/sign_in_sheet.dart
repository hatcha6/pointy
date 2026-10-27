import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/phone.dart';
import '../../core/result.dart';
import '../../data/models/customer.dart';
import '../../design/cards_logo.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/pin_boxes.dart';
import '../../shared/relay_error_text.dart';
import '../../shared/haptics.dart';
import '../../shared/shake.dart';
import '../legal/legal_consent.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';

/// Signs in when needed: true at once for a signed-in customer, otherwise
/// the sheet decides. Called at the moment it matters (paying, opening
/// «كروتي»), never as a wall in front of the shelf.
Future<bool> ensureSignedIn(BuildContext context) async {
  final auth = CardsScope.of(context).auth;
  if (auth.isSignedIn) {
    return true;
  }
  auth.analytics.signInStarted();
  final done = await showModalBottomSheet<bool>(
    context: context,
    routeSettings: screenSettings('sign_in'),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const SignInSheet(),
  );
  if (done == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).signInDone)),
    );
  }
  return done == true;
}

/// Phone, then the 6-digit code from the SMS. One field each; the code field
/// takes the OS's autofill and goes on its own at the sixth digit.
class SignInSheet extends StatefulWidget {
  const SignInSheet({super.key, this.initialChallenge});

  /// Opens on the code step (the preview harness).
  final CodeChallenge? initialChallenge;

  @override
  State<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<SignInSheet> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _codeShake = ShakeController();
  late CodeChallenge? _challenge = widget.initialChallenge;
  String? _phoneError;
  String? _codeError;
  bool _busy = false;
  Timer? _ticker;
  int _resendIn = 0;

  @override
  void initState() {
    super.initState();
    if (_challenge != null) {
      _startCountdown();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _phone.dispose();
    _code.dispose();
    _codeShake.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _ticker?.cancel();
    final resendAt = _challenge?.resendAt;
    int remaining() => resendAt == null
        ? 0
        : resendAt.difference(DateTime.now()).inSeconds.clamp(0, 999);
    _resendIn = remaining();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        return;
      }
      setState(() => _resendIn = remaining());
      if (_resendIn == 0) {
        timer.cancel();
      }
    });
  }

  Future<void> _sendCode() async {
    final l10n = AppLocalizations.of(context);
    final national = LibyanPhone.national(_phone.text);
    if (national == null) {
      setState(() => _phoneError = l10n.errInvalidPhone);
      return;
    }
    setState(() {
      _busy = true;
      _phoneError = null;
      _codeError = null;
    });
    final result = await CardsScope.of(context).auth.requestCode('0$national');
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    switch (result) {
      case Ok(:final value):
        setState(() {
          _challenge = value;
          _code.clear();
          // A development relay answers the code; fill it in for the tester.
          if (kDebugMode && value.testCode.isNotEmpty) {
            _code.text = value.testCode;
          }
        });
        _startCountdown();
      case Error(:final exception):
        final text = relayErrorText(l10n, exception);
        setState(
          () => _challenge == null ? _phoneError = text : _codeError = text,
        );
    }
  }

  Future<void> _verify() async {
    final challenge = _challenge;
    if (challenge == null || _busy || _code.text.length != 6) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _codeError = null;
    });
    final result = await CardsScope.of(context).auth
        .verify(challenge.phone, _code.text);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    switch (result) {
      case Ok():
        Haptics.success();
        Navigator.of(context).pop(true);
      case Error(:final exception):
        relayErrorIsPassing(exception) ? Haptics.warning() : Haptics.error();
        _codeShake.shake();
        setState(() => _codeError = relayErrorText(l10n, exception));
        _code.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          CardsSpace.xl,
        ),
        child: AnimatedSwitcher(
          duration: CardsMotion.standard,
          child: _challenge == null
              ? _phoneStep(context)
              : _codeStep(context, _challenge!),
        ),
      ),
    );
  }

  Widget _phoneStep(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('phone'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: CardsLogo(size: 48),
        ),
        const SizedBox(height: CardsSpace.lg),
        Text(
          l10n.signInTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: CardsSpace.xs),
        Text(
          l10n.signInSubtitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: CardsSpace.xl),
        TextField(
          controller: _phone,
          autofocus: true,
          keyboardType: TextInputType.phone,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          autofillHints: const [AutofillHints.telephoneNumber],
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ٠-٩]')),
            LengthLimitingTextInputFormatter(16),
          ],
          style: PointyTypography.numeric(theme.textTheme.titleLarge!)
              .copyWith(letterSpacing: 1),
          decoration: InputDecoration(
            labelText: l10n.phoneLabel,
            hintText: '09X XXX XXXX',
            hintTextDirection: TextDirection.ltr,
            errorText: _phoneError,
            prefixIcon: const Icon(Icons.phone_iphone_rounded),
          ),
          onSubmitted: (_) => _sendCode(),
        ),
        const SizedBox(height: CardsSpace.xl),
        FilledButton(
          onPressed: _busy ? null : _sendCode,
          child: _busy ? const _ButtonSpinner() : Text(l10n.sendCode),
        ),
        const SizedBox(height: CardsSpace.md),
        const LegalConsent(),
      ],
    );
  }

  Widget _codeStep(BuildContext context, CodeChallenge challenge) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final shown = LibyanPhone.national(challenge.phone);
    return Column(
      key: const ValueKey('code'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.codeTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: CardsSpace.xs),
        Text(
          l10n.codeSentTo,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Its own left-to-right line: inside an Arabic sentence the digit
        // groups of a spaced number would read in reverse.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            shown == null ? challenge.phoneMasked : LibyanPhone.display(shown),
            textDirection: TextDirection.ltr,
            style: PointyTypography.numeric(theme.textTheme.titleMedium!)
                .copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: CardsSpace.xl),
        AutofillGroup(
          child: Shake(
            controller: _codeShake,
            child: PinBoxes(
              controller: _code,
              enabled: !_busy,
              error: _codeError != null,
              onChanged: (value) {
                if (_codeError != null) {
                  setState(() => _codeError = null);
                }
                if (value.length == 6) {
                  _verify();
                }
              },
            ),
          ),
        ),
        AnimatedSize(
          duration: CardsMotion.fast,
          child: _codeError == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: CardsSpace.sm),
                  child: Text(
                    _codeError!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: CardsSpace.lg),
        FilledButton(
          onPressed: _busy || _code.text.length != 6 ? null : _verify,
          child: _busy ? const _ButtonSpinner() : Text(l10n.continueAction),
        ),
        const SizedBox(height: CardsSpace.sm),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _challenge = null;
                      _codeError = null;
                      _ticker?.cancel();
                    }),
              child: Text(l10n.changeNumber),
            ),
            _resendIn > 0
                ? Text(
                    l10n.resendIn(_resendIn),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : TextButton(
                    onPressed: _busy ? null : _sendCode,
                    child: Text(l10n.resendCode),
                  ),
          ],
        ),
      ],
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 22,
    height: 22,
    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
  );
}
