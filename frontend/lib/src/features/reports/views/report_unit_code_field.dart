import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/barcode/barcode_scan_listener.dart';
import '../view_models/reports_view_model.dart';

/// Where a unit ledger is told which article it is about.
///
/// A field rather than a picker: the article is in the owner's hand with its
/// serial or IMEI printed on it or its box, so scanning or typing the code is
/// faster than searching a list for it. Enter runs the report, which takes a
/// scanner that ends its burst with Enter straight from the barcode to the
/// article's history.
class ReportUnitCodeField extends StatefulWidget {
  const ReportUnitCodeField({
    super.key,
    required this.viewModel,
    required this.onSubmitted,
  });

  final ReportsViewModel viewModel;
  final VoidCallback onSubmitted;

  @override
  State<ReportUnitCodeField> createState() => _ReportUnitCodeFieldState();
}

class _ReportUnitCodeFieldState extends State<ReportUnitCodeField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.unitCode,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ScanWedgeTarget(
      child: TextField(
        key: const ValueKey('report_unit_code_field'),
        controller: _controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.qr_code_scanner_outlined),
          hintText: l10n.reportUnitCodeHint,
        ),
        onChanged: widget.viewModel.selectUnitCode,
        onSubmitted: (_) => widget.onSubmitted(),
      ),
    );
  }
}
