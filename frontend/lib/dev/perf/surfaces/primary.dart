// Dev-only sweep script: primary group — dashboard, POS, AI assistant,
// operations, assets.
import 'common.dart';

List<SweepSurface> primarySurfaces() => [
  screen('dashboard'),
  screen('pos'),
  screen('ai_assistant'),
  screen('operations'),
  screen('assets'),
];
