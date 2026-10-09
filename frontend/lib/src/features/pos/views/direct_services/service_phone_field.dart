import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/design/design.dart';
import '../../direct_services/arabic_search_text.dart';
import '../../direct_services/phone_entry.dart';

/// Keeps a phone field to digits, grouped in pairs from the left as they are
/// typed — and lets a leading `+` through, so a whole international number can
/// be pasted and recognised. The caret stays after the digit it was after.
class PhoneGroupFormatter extends TextInputFormatter {
  const PhoneGroupFormatter({this.maxDigits = 15});

  final int maxDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = asciiDigits(newValue.text);
    // The plus counts when it leads the number, however the text around it was
    // dressed (direction marks, brackets, no-break spaces).
    final plus = PhoneEntry.cleanInput(text).startsWith('+');
    var digits = digitsOnly(text);
    if (digits.length > maxDigits) {
      digits = digits.substring(0, maxDigits);
    }
    final result = '${plus ? '+' : ''}${PhoneEntry.groupNational(digits)}';
    if (result == newValue.text) {
      return newValue;
    }
    // How many digits stood before the caret, and where that is in the result.
    final caret = newValue.selection.baseOffset.clamp(0, text.length);
    final before = digitsOnly(
      text.substring(0, caret),
    ).length.clamp(0, digits.length);
    var offset = plus ? 1 : 0;
    var seen = 0;
    if (before > 0) {
      for (var i = 0; i < result.length; i++) {
        if (RegExp(r'[0-9]').hasMatch(result[i])) {
          seen++;
          if (seen == before) {
            offset = i + 1;
            break;
          }
        }
      }
    }
    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// The number field of the airtime form: the country's calling code fixed in
/// front, the number after it left to right in pairs, paste-aware.
///
/// A [ScanWedgeTarget]: the till's barcode listener must neither roll back
/// digits typed here nor take them for a scan.
class ServicePhoneField extends StatefulWidget {
  const ServicePhoneField({
    super.key,
    required this.dial,
    required this.national,
    required this.revision,
    required this.focusRevision,
    required this.hint,
    required this.label,
    required this.onChanged,
    this.onSubmitted,
    this.onDialTap,
    this.enabled = true,
    this.autofocus = false,
  });

  /// The calling code, digits only; empty before a country is chosen.
  final String dial;

  /// The digits the view model holds, shown whenever [revision] changes.
  final String national;
  final int revision;

  /// A change asks the field to take focus.
  final int focusRevision;
  final String hint;
  final String label;
  final bool enabled;
  final bool autofocus;

  /// The text changed; [pasted] says several digits arrived at once.
  final void Function(String raw, {required bool pasted}) onChanged;
  final VoidCallback? onSubmitted;
  final VoidCallback? onDialTap;

  @override
  State<ServicePhoneField> createState() => _ServicePhoneFieldState();
}

class _ServicePhoneFieldState extends State<ServicePhoneField> {
  late final TextEditingController _controller = TextEditingController(
    text: PhoneEntry.groupNational(widget.national),
  );
  final FocusNode _focus = FocusNode(debugLabel: 'service_phone');
  int _lastDigits = 0;

  @override
  void initState() {
    super.initState();
    _lastDigits = widget.national.length;
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ServicePhoneField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      final text = PhoneEntry.groupNational(widget.national);
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _lastDigits = widget.national.length;
    }
    if (oldWidget.focusRevision != widget.focusRevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String raw) {
    final digits = digitsOnly(raw).length;
    // Several digits at once is a paste (or an autofill), never a keystroke.
    final pasted = digits - _lastDigits >= 3;
    _lastDigits = digits;
    widget.onChanged(raw, pasted: pasted);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    // The whole row left to right: «+223 [70 12 34 56]», as a number is read.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Semantics(
            button: widget.onDialTap != null,
            child: InkWell(
              key: const ValueKey('service_dial_chip'),
              onTap: widget.onDialTap,
              borderRadius: BorderRadius.circular(PointyRadii.input),
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.subtleFill,
                  borderRadius: BorderRadius.circular(PointyRadii.input),
                  border: Border.all(color: colors.lineStrong),
                ),
                child: Text(
                  widget.dial.isEmpty ? '+' : '+${widget.dial}',
                  style: PointyTypography.numeric(
                    (textTheme.titleMedium ?? const TextStyle()).copyWith(
                      color: widget.dial.isEmpty ? colors.mutedInk : colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ScanWedgeTarget(
              child: TextField(
                key: const ValueKey('service_phone_field'),
                controller: _controller,
                focusNode: _focus,
                enabled: widget.enabled,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.start,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                inputFormatters: const [PhoneGroupFormatter()],
                onChanged: _changed,
                // Enter is the caller's to answer: where the cursor goes next
                // depends on what is chosen, not on the next field in the tree.
                onEditingComplete: widget.onSubmitted == null ? null : () {},
                onSubmitted: (_) => widget.onSubmitted?.call(),
                style: PointyTypography.numeric(
                  (textTheme.titleMedium ?? const TextStyle()).copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: PointyTypography.numeric(
                    (textTheme.titleMedium ?? const TextStyle()).copyWith(
                      color: colors.mutedInk.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
