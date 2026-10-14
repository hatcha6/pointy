import 'package:flutter/widgets.dart';

import '../../data/repositories/moamalat_repository.dart';

/// Makes the Moamalat repository reachable from the till's payment sheet.
/// Absent in tests and previews, where the sheet shows no live line.
class MoamalatScope extends InheritedWidget {
  const MoamalatScope({
    super.key,
    required this.repository,
    required super.child,
  });

  final MoamalatRepository repository;

  static MoamalatRepository? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MoamalatScope>()?.repository;

  @override
  bool updateShouldNotify(MoamalatScope oldWidget) =>
      repository != oldWidget.repository;
}
