import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_quote.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../view_models/airtime_view_model.dart';
import 'airtime_recents_row.dart';
import 'service_test_mode_banner.dart';
import 'services_unavailable_state.dart';

/// The «الشحن المباشر» tab: one card that opens the stepped top-up dialog, and
/// under it the numbers sold to lately, one tap to repeat. The form itself
/// lives in the dialog ([showAirtimeFlow]), so nothing here is cramped.
class AirtimeLauncher extends StatefulWidget {
  const AirtimeLauncher({
    super.key,
    required this.viewModel,
    required this.onStart,
    this.testMode = false,
  });

  final AirtimeViewModel viewModel;

  /// Opens the dialog; the launcher has already loaded a recent number into
  /// the form when it is tapped.
  final VoidCallback? onStart;
  final bool testMode;

  @override
  State<AirtimeLauncher> createState() => _AirtimeLauncherState();
}

class _AirtimeLauncherState extends State<AirtimeLauncher> {
  AirtimeViewModel get _vm => widget.viewModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_vm.catalog.ensureFresh());
        unawaited(_vm.loadRecents());
      }
    });
  }

  void _useRecent(RecentRecipient recipient) {
    _vm.useRecent(recipient);
    widget.onStart?.call();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _vm.catalog;
    return ListenableBuilder(
      listenable: Listenable.merge([_vm, catalog]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final colors = context.pointyColors;
        final textTheme = Theme.of(context).textTheme;
        final spacing = AdaptiveSpacing.of(context);
        final directory = catalog.directory;
        if (directory == null) {
          if (catalog.hasDirectoryError) {
            return Align(
              alignment: AlignmentDirectional.topCenter,
              child: PointyInlineMessage.error(
                key: const ValueKey('services_error'),
                message: l10n.posServicesLoadError,
                icon: Icons.cloud_off_outlined,
                trailing: TextButton.icon(
                  onPressed: catalog.reload,
                  icon: const Icon(Icons.sync),
                  label: Text(l10n.retryButton),
                ),
              ),
            );
          }
          return const Center(child: PointySpinner());
        }
        if (!directory.available || directory.airtimeCountries.isEmpty) {
          return ServicesUnavailableState(errorCode: directory.errorCode);
        }
        final testMode = widget.testMode || catalog.isTestMode();
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (testMode) ...[
                const ServiceTestModeBanner(compact: true),
                const SizedBox(height: 8),
              ],
              Container(
                key: const ValueKey('airtime_launcher'),
                padding: EdgeInsets.all(spacing.lg),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(PointyRadii.card),
                  border: Border.all(color: colors.line),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.bolt_rounded,
                        size: 30,
                        color: colors.primaryDark,
                      ),
                    ),
                    SizedBox(width: spacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.posAirtimeLauncherTitle,
                            style: textTheme.titleMedium?.copyWith(
                              color: colors.ink,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.posAirtimeLauncherBody,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: spacing.md),
                    FilledButton.icon(
                      key: const ValueKey('airtime_start'),
                      onPressed: widget.onStart,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(l10n.posAirtimeLauncherStart),
                    ),
                  ],
                ),
              ),
              if (_vm.recents.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  l10n.posAirtimeRecentTitle,
                  style: textTheme.labelLarge?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                AirtimeRecentsRow(
                  recents: _vm.recents,
                  catalog: catalog,
                  onSelected: _useRecent,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
