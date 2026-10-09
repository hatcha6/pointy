import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_quote.dart';
import '../../../../shared/components/components.dart';

/// What a service screen says when there is nothing to sell: the company
/// switched the services off for every shop, the shop has not set them up, or
/// the directory simply has no country for it right now.
class ServicesUnavailableState extends StatelessWidget {
  const ServicesUnavailableState({
    super.key,
    required this.errorCode,
    this.icon = Icons.bolt_rounded,
  });

  /// The directory's `error_code`; empty when it just has nothing listed.
  final String errorCode;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyEmptyState(
      icon: icon,
      title: l10n.posServicesUnavailableTitle,
      message: switch (errorCode) {
        ServiceRefusalCode.switchedOff =>
          l10n.posServicesUnavailableSwitchedOff,
        ServiceRefusalCode.notConfigured =>
          l10n.posServicesUnavailableNotConfigured,
        _ => l10n.posServicesUnavailableEmpty,
      },
    );
  }
}
