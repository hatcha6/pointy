import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/contact.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Pick (or create) the customer for a brand-new SMS conversation. Reuses the
/// shared customer picker — which already searches existing customers and offers
/// inline creation — and returns the chosen [Customer] once the user confirms,
/// or null if they cancel. A phone number is required, since a conversation is
/// keyed on one, so the confirm button stays disabled until the customer has one.
Future<Customer?> showNewConversationDialog({
  required BuildContext context,
  required ContactRepository contactRepository,
}) {
  return showDialog<Customer?>(
    context: context,
    builder: (context) =>
        _NewConversationDialog(contactRepository: contactRepository),
  );
}

class _NewConversationDialog extends StatefulWidget {
  const _NewConversationDialog({required this.contactRepository});

  final ContactRepository contactRepository;

  @override
  State<_NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  Customer? _customer;

  bool get _hasPhone => _customer?.phone.trim().isNotEmpty ?? false;

  Future<void> _selectCustomer() async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (customer == null || !mounted) return;
    setState(() => _customer = customer);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final customer = _customer;

    return AlertDialog(
      icon: const Icon(Icons.forum_outlined),
      title: Text(l10n.newConversationTitle),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ContactSelectionTile(
                key: const ValueKey('new_conversation_customer_tile'),
                label: l10n.newConversationCustomerLabel,
                value: customer?.fullName ?? '',
                placeholder: l10n.newConversationSelectCustomer,
                icon: Icons.person_pin_circle_outlined,
                enabled: true,
                onSelect: _selectCustomer,
                onClear: () => setState(() => _customer = null),
                allowClear: customer != null,
                selectActionIcon: Icons.edit_outlined,
              ),
              if (customer != null) ...[
                SizedBox(height: spacing.sm),
                if (_hasPhone)
                  Row(
                    children: [
                      Icon(
                        Icons.phone_outlined,
                        size: 16,
                        color: colors.mutedInk,
                      ),
                      SizedBox(width: spacing.xs),
                      Expanded(
                        child: Text(
                          customer.phone,
                          // A phone number reads left-to-right even in an RTL UI.
                          textDirection: TextDirection.ltr,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  )
                else
                  PointyInlineMessage.warning(
                    key: const ValueKey('new_conversation_no_phone'),
                    message: l10n.newConversationNoPhoneWarning,
                    icon: Icons.phone_disabled_outlined,
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          key: const ValueKey('new_conversation_start_button'),
          onPressed: _hasPhone
              ? () => Navigator.of(context).pop(customer)
              : null,
          icon: const Icon(Icons.send_outlined),
          label: Text(l10n.newConversationStartButton),
        ),
      ],
    );
  }
}
