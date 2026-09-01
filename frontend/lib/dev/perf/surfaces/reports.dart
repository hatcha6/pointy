// Dev-only sweep script: reports group — expenses, money position / payments
// hub, reports, activity log.
import 'common.dart';

List<SweepSurface> reportsSurfaces() => [
  screen('expenses'),
  screen('payments_hub'),
  screen('reports'),
  screen('activity_log'),
];
