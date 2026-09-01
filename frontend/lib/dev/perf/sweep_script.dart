// Dev-only: the list of every screen and dialog the performance sweep visits,
// assembled from one script per navigation group (see surfaces/). Surfaces
// are named after the analytics screen names where one exists so the numbers
// line up with field telemetry.
import 'surfaces/common.dart';
import 'surfaces/people.dart';
import 'surfaces/primary.dart';
import 'surfaces/reports.dart';
import 'surfaces/sales.dart';
import 'surfaces/settings.dart';
import 'surfaces/shell.dart';
import 'surfaces/stock.dart';
import 'sweep_driver.dart';

export 'surfaces/common.dart' show SweepSurface, destinationLabels;

/// Every surface, in visiting order. Each entry is self-contained: it
/// navigates to its screen through the drawer, so a failure in one does not
/// strand the rest. The shell (login first) leads.
List<SweepSurface> sweepSurfaces() => [
  ...shellSurfaces(),
  ...primarySurfaces(),
  ...salesSurfaces(),
  ...stockSurfaces(),
  ...peopleSurfaces(),
  ...reportsSurfaces(),
  ...settingsSurfaces(),
];

Future<void> runSweep(SweepDriver driver, {Iterable<String>? only}) async {
  final wanted = only?.toSet();
  for (final surface in sweepSurfaces()) {
    // Login always runs: nothing else is reachable before it.
    if (surface.name != 'login' &&
        wanted != null &&
        wanted.isNotEmpty &&
        !wanted.contains(surface.name)) {
      continue;
    }
    await surface.run(driver);
  }
}
