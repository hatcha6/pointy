import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../design/cards_tokens.dart';
import '../core/analytics/analytics.dart';

/// A code shown as six boxes, typed into one invisible field underneath, so
/// the OS's code autofill and paste keep working. The box being filled is
/// ringed in ink; a filled one holds its digit, left to right.
class PinBoxes extends StatefulWidget {
  const PinBoxes({
    super.key,
    required this.controller,
    this.length = 6,
    this.enabled = true,
    this.error = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final int length;
  final bool enabled;
  final bool error;
  final ValueChanged<String>? onChanged;

  @override
  State<PinBoxes> createState() => _PinBoxesState();
}

class _PinBoxesState extends State<PinBoxes> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _focus.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.controller.text;
    // A code typed here never shows in a session replay.
    return Sensitive(
      child: GestureDetector(
        onTap: () => _focus.requestFocus(),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0,
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: true,
                enabled: widget.enabled,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(widget.length),
                ],
                showCursor: false,
                enableInteractiveSelection: false,
                onChanged: widget.onChanged,
              ),
            ),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.length; i++) ...[
                    if (i > 0)
                      SizedBox(
                        width: i == widget.length ~/ 2
                            ? CardsSpace.md
                            : CardsSpace.sm,
                      ),
                    _box(
                      theme,
                      i < text.length ? text[i] : '',
                      i == text.length && _focus.hasFocus,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _box(ThemeData theme, String digit, bool active) {
    final color = widget.error
        ? theme.colorScheme.error
        : (active ? theme.colorScheme.onSurface : theme.colorScheme.outline);
    return AnimatedContainer(
      duration: CardsMotion.fast,
      width: 46,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.field),
        border: Border.all(
          color: color,
          width: active || widget.error ? 1.8 : 1,
        ),
      ),
      child: AnimatedSwitcher(
        duration: CardsMotion.fast,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Text(
          digit,
          key: ValueKey(digit),
          style: PointyTypography.numeric(theme.textTheme.headlineSmall!),
        ),
      ),
    );
  }
}
