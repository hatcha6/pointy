import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../date_formatters.dart';

/// Reads an expiry the way it is printed on a pack and typed by a receiver.
///
/// A foil says `EXP 08/27` or `08/2027`, a carton `31.08.2027`: the month is
/// the fact and the day, when there is one, is a detail. So:
///
/// * `MM/YY`, `MM/YYYY` (or the same digits run together, `0827`, `082027`)
///   → the **last** day of that month, the day the pack actually stops;
/// * `DD/MM/YY`, `DD/MM/YYYY` (or `310827`, `31082027`) → that day;
/// * `YYYY-MM-DD` and `YYYY-MM`, as the API writes them.
///
/// Separators may be `/`, `-`, `.` or spaces, and Arabic-Indic digits are read
/// as digits, because a till set to an Arabic keyboard types `٠٨/٢٧`.
/// Anything else — a month of 13, the 31st of a 30-day month — is null.
DateTime? parseTypedExpiry(String input) {
  final text = _latinDigits(input).trim();
  if (text.isEmpty) {
    return null;
  }
  final parts = text
      .split(RegExp(r'[\s/.\-]+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.any((part) => int.tryParse(part) == null)) {
    return null;
  }
  if (parts.length == 1) {
    final digits = parts.single;
    return switch (digits.length) {
      4 => _monthEnd(digits.substring(2), digits.substring(0, 2)),
      6 =>
        // 082027 is August 2027; 310827 is 31 August 2027. A month-year read
        // wins whenever the last four digits make a plausible year.
        _isFourDigitYear(digits.substring(2))
            ? _monthEnd(digits.substring(2), digits.substring(0, 2))
            : _day(
                digits.substring(4),
                digits.substring(2, 4),
                digits.substring(0, 2),
              ),
      8 => _day(
        digits.substring(4),
        digits.substring(2, 4),
        digits.substring(0, 2),
      ),
      _ => null,
    };
  }
  if (parts.length == 2) {
    final [first, second] = parts;
    if (first.length == 4) {
      return _monthEnd(first, second);
    }
    return _monthEnd(second, first);
  }
  if (parts.length == 3) {
    final [first, second, third] = parts;
    if (first.length == 4) {
      return _day(first, second, third);
    }
    return _day(third, second, first);
  }
  return null;
}

/// How [ExpiryDateField] writes a date back: month/year when it is the last
/// day of its month (what was typed, most likely), the full day otherwise.
String formatTypedExpiry(DateTime date) {
  final monthEnd = DateTime(date.year, date.month + 1, 0);
  if (monthEnd.day == date.day) {
    return formatExpiry(date);
  }
  final day = date.day.toString().padLeft(2, '0');
  return '$day/${formatExpiry(date)}';
}

bool _isFourDigitYear(String value) {
  final year = int.parse(value);
  return year >= 2000 && year <= 2199;
}

int? _year(String value) {
  final year = int.parse(value);
  if (value.length == 2) {
    return 2000 + year;
  }
  if (value.length == 4 && year >= 1900 && year <= 2199) {
    return year;
  }
  return null;
}

DateTime? _monthEnd(String yearText, String monthText) {
  final year = _year(yearText);
  final month = int.parse(monthText);
  if (year == null || month < 1 || month > 12) {
    return null;
  }
  return DateTime(year, month + 1, 0);
}

DateTime? _day(String yearText, String monthText, String dayText) {
  final year = _year(yearText);
  final month = int.parse(monthText);
  final day = int.parse(dayText);
  if (year == null || month < 1 || month > 12 || day < 1) {
    return null;
  }
  final date = DateTime(year, month, day);
  // DateTime rolls 31/04 over into May; a typo must not become a real date.
  return date.month == month ? date : null;
}

String _latinDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// A typed expiry date with a calendar beside it.
///
/// Typed first because a receiver with forty lines and a foil edge in hand
/// should not open a calendar forty times: `12/27` and Enter is the whole
/// interaction. The picker is still one click away for whoever prefers it.
class ExpiryDateField extends StatefulWidget {
  const ExpiryDateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.required = false,
    this.focusNode,
    this.autofocus = false,
    this.onSubmitted,
    this.enabled = true,
    this.textInputAction,
  });

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final String? label;
  final bool required;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;
  final TextInputAction? textInputAction;

  /// Enter in the field — the hook a fast-entry flow uses to move on.
  final ValueChanged<DateTime?>? onSubmitted;

  @override
  State<ExpiryDateField> createState() => _ExpiryDateFieldState();
}

class _ExpiryDateFieldState extends State<ExpiryDateField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value == null ? '' : formatTypedExpiry(widget.value!),
  );
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode());
  FocusNode? _listened;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _listened?.removeListener(_onFocus);
    _listened = _focusNode..addListener(_onFocus);
  }

  /// Arriving selects what is there, so a typed date replaces it; leaving
  /// writes what was understood back in its plain form — «0827» becomes
  /// «08/2027» — which is how the receiver sees it was read right, without a
  /// second line under the field saying so.
  void _onFocus() {
    if (_focusNode.hasFocus) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
      return;
    }
    final parsed = parseTypedExpiry(_controller.text);
    if (parsed != null) {
      final canonical = formatTypedExpiry(parsed);
      if (_controller.text != canonical) {
        setState(() => _controller.text = canonical);
      }
    }
  }

  @override
  void didUpdateWidget(covariant ExpiryDateField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      _listen();
    }
    // Programmatic changes (a +12 months shortcut, a picker, a lot copied from
    // the line above) are shown; the text being typed is never rewritten.
    if (_focusNode.hasFocus) {
      return;
    }
    final value = widget.value;
    if (value == parseTypedExpiry(_controller.text)) {
      return;
    }
    _controller.text = value == null ? '' : formatTypedExpiry(value);
  }

  @override
  void dispose() {
    _listened?.removeListener(_onFocus);
    _ownFocusNode?.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.value ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
    );
    if (picked != null && mounted) {
      _controller.text = formatTypedExpiry(picked);
      widget.onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = _controller.text.trim();
    final parsed = parseTypedExpiry(text);
    final String? error;
    if (text.isNotEmpty && parsed == null) {
      error = l10n.expiryFieldInvalid;
    } else if (widget.required && text.isEmpty) {
      error = l10n.batchCaptureExpiryRequired;
    } else {
      error = null;
    }
    final label = widget.label ?? l10n.batchCaptureExpiry;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      keyboardType: TextInputType.datetime,
      textInputAction: widget.textInputAction,
      // Dates are numbers read left to right, even on an Arabic screen.
      textDirection: TextDirection.ltr,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩۰-۹/.\- ]')),
        LengthLimitingTextInputFormatter(10),
      ],
      decoration: InputDecoration(
        isDense: true,
        labelText: widget.required ? '$label *' : label,
        hintText: l10n.expiryFieldHint,
        hintTextDirection: TextDirection.ltr,
        errorText: error,
        // The calendar sits where the cost field keeps its icon, so the two
        // fields of a line read as one row of the same kind of thing.
        prefixIcon: IconButton(
          tooltip: l10n.expiryFieldPickTooltip,
          icon: const Icon(Icons.event_outlined, size: 20),
          onPressed: widget.enabled ? _pick : null,
        ),
      ),
      onChanged: (value) {
        setState(() {});
        final date = parseTypedExpiry(value);
        if (date != null || value.trim().isEmpty) {
          widget.onChanged(date);
        }
      },
      // Whoever listens to Enter decides where focus goes next.
      onEditingComplete: widget.onSubmitted == null ? null : () {},
      onSubmitted: (value) => widget.onSubmitted?.call(parseTypedExpiry(value)),
    );
  }
}
