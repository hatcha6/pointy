import 'print_transport.dart';

/// The page sizes a CUPS queue's driver will take, as `lpoptions -l` lists
/// them on its `PageSize` line:
///
///     PageSize/Media Size: Custom.WIDTHxHEIGHT *w288h432 w144h72 w142h85
///
/// **Why a job has to name its page here, not only as `media`.** A queue's
/// saved default — set in the system's printer settings, by `lpadmin`, or in a
/// user's `lpoptions` — travels with every job as `PageSize=…`, and a driver
/// takes its page from `PageSize`, not from `media`. A job that only says
/// `media=Custom.50x30mm` is rendered at 50 × 30 mm, but the driver is told the
/// label is whatever the default says: 4 × 6 in on the XP-235B that showed
/// this, which then printed every sticker shrunk and pushed aside, ignoring the
/// sticker's size and its offsets alike. Naming the page as `PageSize` too
/// overrides the saved default — but only with a value the driver can take: a
/// `Custom.…` size on a driver without custom sizes is thrown out, and the
/// default comes back.
class CupsPageSizes {
  const CupsPageSizes({
    required this.choices,
    required this.acceptsCustom,
    this.defaultChoice,
  });

  /// The driver's own sizes, by keyword.
  final List<String> choices;

  /// Whether the driver takes any size (`Custom.WIDTHxHEIGHT`).
  final bool acceptsCustom;

  /// The size every job gets unless it names another.
  final String? defaultChoice;

  /// Reads the `PageSize` line of `lpoptions -l` output; null when there is
  /// none (no driver options to speak of, so nothing to override).
  static CupsPageSizes? parse(String lpoptionsOutput) {
    for (final line in lpoptionsOutput.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) {
        continue;
      }
      final option = line.substring(0, colon).split('/').first.trim();
      if (option != 'PageSize') {
        continue;
      }
      final choices = <String>[];
      String? defaultChoice;
      var acceptsCustom = false;
      for (final word
          in line.substring(colon + 1).trim().split(RegExp(r'\s+'))) {
        if (word.isEmpty) {
          continue;
        }
        final isDefault = word.startsWith('*');
        final choice = isDefault ? word.substring(1) : word;
        if (choice.startsWith('Custom.')) {
          acceptsCustom = true;
          continue;
        }
        choices.add(choice);
        if (isDefault) {
          defaultChoice = choice;
        }
      }
      return CupsPageSizes(
        choices: choices,
        acceptsCustom: acceptsCustom,
        defaultChoice: defaultChoice,
      );
    }
    return null;
  }

  /// The `PageSize` value that names a [widthMm] × [heightMm] page to this
  /// driver: the page itself when the driver takes custom sizes, else the size
  /// of its own that is the page to within half a millimetre — a preset is
  /// kept in whole points, which rounds a millimetre size by up to a fifth of
  /// a millimetre. Null when the driver has no way to say this page at all.
  String? choiceFor(double widthMm, double heightMm) {
    if (acceptsCustom) {
      return cupsCustomMediaName(widthMm, heightMm);
    }
    for (final choice in choices) {
      final size = cupsPageSizeMm(choice);
      if (size != null &&
          (size.widthMm - widthMm).abs() <= 0.5 &&
          (size.heightMm - heightMm).abs() <= 0.5) {
        return choice;
      }
    }
    return null;
  }

  /// What a job of [widthMm] × [heightMm] prints on when the driver cannot
  /// take that page ([choiceFor] is null): its default size, when the
  /// default's keyword says how big that is.
  PrintPaperMismatch mismatchFor(double widthMm, double heightMm) {
    final fallback = defaultChoice == null
        ? null
        : cupsPageSizeMm(defaultChoice!);
    return PrintPaperMismatch(
      requestedWidthMm: widthMm,
      requestedHeightMm: heightMm,
      printedWidthMm: fallback?.widthMm,
      printedHeightMm: fallback?.heightMm,
    );
  }
}

/// The `lp` options that name a [widthMm] × [heightMm] page to a queue whose
/// driver takes [sizes] — or, when that is unknown, as `media` alone, which is
/// all a job ever said before. `PageSize` goes too whenever the driver has a
/// value for the page: it is the option a saved default would otherwise win.
List<String> cupsPageOptions(
  CupsPageSizes? sizes,
  double widthMm,
  double heightMm,
) {
  final pageSize = sizes?.choiceFor(widthMm, heightMm);
  return [
    '-o',
    'media=${pageSize ?? cupsCustomMediaName(widthMm, heightMm)}',
    if (pageSize != null) ...['-o', 'PageSize=$pageSize'],
  ];
}

/// The size a `PageSize` keyword names, in millimetres, when the keyword says:
/// Adobe's `w<points>h<points>` (`w288h432`), or the `<w>x<h>` that label
/// drivers use with or without a unit (`4x6`, `4x6in`, `50x30mm`,
/// `Label60x40`). A bare pair is inches when both numbers are small enough to
/// be (no label is 13 mm across), millimetres otherwise. Null for a name that
/// is only a name (`Roll80mm`, `Letter`).
({double widthMm, double heightMm})? cupsPageSizeMm(String keyword) {
  final points = RegExp(
    r'^w(\d+(?:\.\d+)?)h(\d+(?:\.\d+)?)',
  ).firstMatch(keyword);
  if (points != null) {
    const mmPerPoint = 25.4 / 72;
    return (
      widthMm: double.parse(points.group(1)!) * mmPerPoint,
      heightMm: double.parse(points.group(2)!) * mmPerPoint,
    );
  }
  final pair = RegExp(
    r'(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)(mm|in)?',
  ).firstMatch(keyword);
  if (pair == null) {
    return null;
  }
  final width = double.parse(pair.group(1)!);
  final height = double.parse(pair.group(2)!);
  final inches = switch (pair.group(3)) {
    'in' => true,
    'mm' => false,
    _ => width <= 12 && height <= 12,
  };
  final scale = inches ? 25.4 : 1.0;
  return (widthMm: width * scale, heightMm: height * scale);
}

/// CUPS custom media name for a `width × height` mm page. Whole millimetres
/// print as integers (`Custom.40x25mm`) — the form every CUPS version parses.
String cupsCustomMediaName(double widthMm, double heightMm) {
  String fmt(double mm) {
    final rounded = (mm * 100).round() / 100;
    return rounded == rounded.roundToDouble()
        ? '${rounded.round()}'
        : rounded.toString();
  }

  return 'Custom.${fmt(widthMm)}x${fmt(heightMm)}mm';
}

/// Outcome of a `lp` spool attempt. [unsupported] means "this platform has no
/// CUPS" — distinct from a real failure, because the caller then falls back to
/// the printing plugin instead of reporting an error.
class CupsSpoolResult {
  const CupsSpoolResult.spooled({this.paperMismatch})
    : supported = true,
      error = null;
  const CupsSpoolResult.failed(String this.error)
    : supported = true,
      paperMismatch = null;
  const CupsSpoolResult.unsupported()
    : supported = false,
      error = null,
      paperMismatch = null;

  final bool supported;
  final String? error;

  /// Set when the job went to a driver that could not take its page, so it
  /// printed on the driver's default instead; see [CupsPageSizes].
  final PrintPaperMismatch? paperMismatch;

  bool get succeeded => supported && error == null;
}
