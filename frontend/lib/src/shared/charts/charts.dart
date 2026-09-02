/// Shared, theme-driven chart widgets.
///
/// Every chart here takes data and a value kind, never colours or styling. The
/// palette resolves series colours from the active theme so charts match the
/// product in light and dark mode, and so generated UI cannot drift.
library;

export 'chart_formatting.dart';
export 'chart_palette.dart';
export 'chart_scaffold.dart' show PointyChartScaffold;
export 'pointy_bar_chart.dart';
export 'pointy_chart_data.dart';
export 'pointy_donut_chart.dart';
export 'pointy_line_chart.dart';
export 'pointy_sparkline.dart';
