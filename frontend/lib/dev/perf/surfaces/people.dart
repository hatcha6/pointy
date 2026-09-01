// Dev-only sweep script: people group — contacts, conversations, campaigns,
// employees & payroll.
import 'common.dart';

List<SweepSurface> peopleSurfaces() => [
  screen('contacts'),
  screen('conversations'),
  screen('campaigns'),
  screen('employees'),
];
