import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'components/components.dart';

class AuthorizationDeniedView extends StatelessWidget {
  const AuthorizationDeniedView({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyPermissionDeniedView(
      title: l10n.unauthorizedTitle,
      message: l10n.unauthorizedMessage,
      compact: compact,
    );
  }
}
