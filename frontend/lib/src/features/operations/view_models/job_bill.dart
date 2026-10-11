import 'dart:math' as math;

import '../../../data/models/operations_job.dart';

/// What a job's invoice will come to, worked out once for every screen that
/// shows it — the job's «الحساب» card and the invoice dialog read the same
/// numbers, so what the counter sees on the job is what the invoice says.
///
/// A job is priced in two ways at once: the lines (parts fitted, services and
/// labour charged) and the price the customer was told — approved, or failing
/// that the first quote. The lines bill; the price does not. When the lines come
/// to less than the price, the rest is billed as labour so the invoice equals
/// the price. Annaseem, 2026-10-12: a 250 repair with a 100 labour line opened
/// the invoice with an empty «أجور العمل» box; the 250 typed into it billed 350.
class JobBill {
  const JobBill({
    required this.parts,
    required this.services,
    this.agreedPrice,
    this.agreedIsApproved = false,
  });

  factory JobBill.of(OperationsJob job) {
    final approved = job.approvedPrice;
    return JobBill(
      parts: job.materialsTotal,
      services: job.servicesTotal,
      agreedPrice: approved ?? job.quotedPrice,
      agreedIsApproved: approved != null,
    );
  }

  final double parts;

  /// Services and labour lines already charged on the job.
  final double services;

  /// What the customer was told it costs: approved, else quoted. Null when
  /// nobody has named a price.
  final double? agreedPrice;
  final bool agreedIsApproved;

  double get lines => parts + services;

  /// The part of the agreed price no line accounts for: billed as labour.
  double get remainder {
    final agreed = agreedPrice;
    if (agreed == null) return 0;
    return _cents(math.max(0, agreed - lines));
  }

  /// How far the lines already run past the agreed price.
  double get overAgreedBy {
    final agreed = agreedPrice;
    if (agreed == null) return 0;
    return _cents(math.max(0, lines - agreed));
  }

  double get total => _cents(lines + remainder);

  bool get isEmpty => lines <= 0 && agreedPrice == null;

  static double _cents(double value) => (value * 100).roundToDouble() / 100;
}
