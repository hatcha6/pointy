import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/collapse_view_model.dart';
import 'collapse_review_view.dart';

/// The collapse review, on its own screen.
///
/// A page rather than a section of the wizard because reviewing 340 rows is not
/// a step somebody takes between two other steps — it is the work, and it wants
/// the whole width.
class CollapseReviewPage extends StatelessWidget {
  const CollapseReviewPage({super.key, required this.viewModel});

  final CollapseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.collapseTitle),
            isLoading: viewModel.isLoading || viewModel.isProposing,
          ),
          body: SingleChildScrollView(
            padding: spacing.pagePadding,
            child: AdaptiveMaxWidth(
              width: AppContentWidth.form,
              child: CollapseReviewView(viewModel: viewModel),
            ),
          ),
        );
      },
    );
  }
}
