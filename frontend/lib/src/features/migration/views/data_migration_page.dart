import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/migration_view_model.dart';
import 'migration_steps.dart';

/// Bringing a shop's old POS data across, as a guided flow.
///
/// The screen this replaces was an admin console: it asked for a host, a port, a
/// database name, a username, a password, an ODBC driver, a TDS version and a
/// text codepage — nine things the person in front of it does not know, before
/// anything could happen at all.
///
/// This asks for one thing: the file. Everything after that is the app working
/// and saying what it is doing.
class DataMigrationPage extends StatefulWidget {
  const DataMigrationPage({super.key, required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  State<DataMigrationPage> createState() => _DataMigrationPageState();
}

class _DataMigrationPageState extends State<DataMigrationPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.migrationTitle),
            isLoading: viewModel.isLoading,
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.catalog == null) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.catalog == null) {
      return PointyErrorState(
        title: l10n.migrationLoadError,
        icon: Icons.cloud_sync_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return SingleChildScrollView(
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyStepRail(
              steps: [
                PointyStepRailItem(label: l10n.migrationStepChoose),
                PointyStepRailItem(label: l10n.migrationStepUpload),
                PointyStepRailItem(label: l10n.migrationStepPrepare),
                PointyStepRailItem(label: l10n.migrationStepReview),
                PointyStepRailItem(label: l10n.migrationStepImport),
              ],
              currentIndex: _railIndex(viewModel.step),
            ),
            SizedBox(height: spacing.lg),
            if (viewModel.errorMessage != null) ...[
              PointyInlineMessage.error(
                message: _errorText(l10n, viewModel.errorMessage!),
              ),
              SizedBox(height: spacing.md),
            ],
            MigrationStepView(viewModel: viewModel),
          ],
        ),
      ),
    );
  }

  /// Which rail dot is lit. Failure keeps the rail where the work stopped rather
  /// than snapping it back, so the picture still reads as "this got that far".
  int _railIndex(MigrationStep step) => switch (step) {
    MigrationStep.choose => 0,
    MigrationStep.uploading => 1,
    MigrationStep.preparing => 2,
    MigrationStep.failed => 2,
    MigrationStep.review => 3,
    MigrationStep.running => 4,
    MigrationStep.done => 4,
  };

  String _errorText(AppLocalizations l10n, String raw) {
    // The view model raises a token for the one error it detects itself; every
    // other message comes from the server already phrased for a person.
    if (raw == 'tooLarge') return l10n.migrationFileTooLarge;
    return raw;
  }
}
