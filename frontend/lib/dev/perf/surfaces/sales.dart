// Dev-only sweep script: sales group — invoices, returns desk, register
// sessions, discounts.
import 'common.dart';

List<SweepSurface> salesSurfaces() => [
  screen('invoices'),
  screen('returns_exchange'),
  screen('register_sessions'),
  screen('discounts'),
];
