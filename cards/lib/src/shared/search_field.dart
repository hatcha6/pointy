import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../design/cards_tokens.dart';

/// The app's search field: a glass capsule the page shows through, with a
/// clear button once something is typed.
class CardsSearchField extends StatelessWidget {
  const CardsSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.focus,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final FocusNode? focus;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final glass = theme.colorScheme.surface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.62 : 0.74,
    );
    final capsule = OutlineInputBorder(
      borderRadius: BorderRadius.circular(CardsRadii.pill),
      borderSide: BorderSide.none,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CardsRadii.pill),
        boxShadow: CardsShadows.raised,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CardsRadii.pill),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => TextField(
              controller: controller,
              focusNode: focus,
              autofocus: autofocus,
              textInputAction: TextInputAction.search,
              onChanged: onChanged,
              decoration: InputDecoration(
                filled: true,
                fillColor: glass,
                hintText: l10n.homeSearchHint,
                prefixIcon: const Icon(Icons.search_rounded),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: capsule,
                enabledBorder: capsule,
                focusedBorder: capsule.copyWith(
                  borderSide: BorderSide(
                    color: theme.colorScheme.onSurface,
                    width: 1.4,
                  ),
                ),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.cancelAction,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
