import 'dart:io';
import 'dart:typed_data';

/// Spools a PDF straight to CUPS with an **exact** media size.
///
/// The printing plugin can't express label or roll media on Linux or macOS: its
/// Linux job builder ignores the page size entirely (`gtk_page_setup_new()` →
/// the locale default, i.e. A4) and its macOS one flags any page wider than tall
/// as landscape. Either way the driver falls back to the queue's own page — for
/// a label/receipt printer that is typically an 80 × 297 mm roll page, so a
/// single 40 × 25 mm sticker is rotated to fit and followed by ~270 mm of blank
/// feed ("one label printed, then a handful skipped"), and an 86 mm receipt is
/// padded out to the same 297 mm as a 117 mm one (the "compact and standard
/// receipts come out the same length" symptom).
///
/// `lp` takes the media size per job (`-o media=Custom.40x25mm`), which pins the
/// page to the die-cut sticker — or to the measured receipt — so nothing is left
/// for the driver to fit, rotate or pad.
///
/// Set [registerLabelTop] for die-cut label media, and only for die-cut media:
/// the job is then preceded by a gap seek that parks the roll on a sticker's
/// leading edge, but only when this process cannot already vouch for the roll
/// (see [seekLabelTopViaCups] and [CupsLabelRegistration]).
Future<CupsSpoolResult> spoolPdfToCups({
  required Uint8List bytes,
  required String? queue,
  required String jobName,
  required double mediaWidthMm,
  required double mediaHeightMm,
  int copies = 1,
  bool registerLabelTop = false,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return const CupsSpoolResult.unsupported();
  }
  if (bytes.isEmpty || mediaWidthMm <= 0 || mediaHeightMm <= 0) {
    return const CupsSpoolResult.unsupported();
  }

  // Anything that is not a whole-pitch label strip — a receipt, a calibration
  // sheet — leaves the roll wherever its content ended, so whatever this
  // process knew about the label phase is now worthless.
  if (!registerLabelTop) {
    cupsLabelRegistration.forget(queue);
  }

  Directory? workDir;
  try {
    workDir = await Directory.systemTemp.createTemp('pointy-label-');

    // Register first, print second. Both go to the same queue, and CUPS runs a
    // queue's jobs in submission order, so the roll is on a label edge by the
    // time the artwork arrives.
    var registered =
        !registerLabelTop || !cupsLabelRegistration.needsSeek(queue);
    if (registerLabelTop && !registered) {
      // The seek never reaching the printer means the artwork is about to land
      // on whatever phase the roll happens to be in — worth printing anyway,
      // but not worth remembering as a registered roll.
      registered = await seekLabelTopViaCups(queue: queue, workDir: workDir);
    }

    final file = File('${workDir.path}/$jobName.pdf');
    await file.writeAsBytes(bytes, flush: true);

    final result = await Process.run('lp', [
      if (queue != null && queue.trim().isNotEmpty) ...['-d', queue.trim()],
      '-t', jobName,
      '-n', '${copies < 1 ? 1 : copies}',
      // The whole point of this path: the media as loaded in the printer.
      '-o', 'media=${cupsCustomMediaName(mediaWidthMm, mediaHeightMm)}',
      // Portrait, unscaled: the page already *is* the media, so any auto-rotate
      // or fit-to-page the filter chain might apply would only distort it.
      '-o', 'orientation-requested=3',
      '-o', 'print-scaling=none',
      // Feed the WHOLE page, blank tail included. Receipt-derived drivers
      // default to trimming the trailing white off a page ("bottom paper save"
      // — on the LPQ80's PPD it is on by default and cut 5.5 mm off an 81.7 mm
      // strip). On a receipt that only costs the closing tagline its breathing
      // room before the cut; on die-cut labels it means every job stops short of
      // the page it was given, so the roll ends a little behind where the next
      // job assumes it starts, and the labels walk down the strip. Unknown to
      // other PPDs, where CUPS ignores it.
      '-o', 'PaperSaveBottom=0',
      '-o', 'PaperSaveMode=0',
      file.path,
    ]).timeout(timeout);

    if (result.exitCode != 0) {
      cupsLabelRegistration.forget(queue);
      final message = '${result.stderr}'.trim().isEmpty
          ? '${result.stdout}'.trim()
          : '${result.stderr}'.trim();
      return CupsSpoolResult.failed(
        message.isEmpty ? 'lp exited with ${result.exitCode}' : message,
      );
    }
    if (registerLabelTop && registered) {
      // A label strip is a whole number of pitches, so the roll ends in the
      // phase it started: registered, until something else moves the paper.
      cupsLabelRegistration.markRegistered(queue);
    }
    return const CupsSpoolResult.spooled();
  } on ProcessException {
    // No `lp` on this box (CUPS client not installed) — let the caller fall
    // back to the printing plugin.
    cupsLabelRegistration.forget(queue);
    return const CupsSpoolResult.unsupported();
  } on Object catch (error) {
    cupsLabelRegistration.forget(queue);
    return CupsSpoolResult.failed('$error');
  } finally {
    try {
      await workDir?.delete(recursive: true);
    } on Object {
      // Best effort: a leftover temp file must never fail a print.
    }
  }
}

/// Parks the roll on a die-cut sticker's leading edge, the way the FEED button
/// does, by sending the printer a bare `GS FF` (`1D 0C`) as a raw job. Returns
/// whether the seek was accepted by CUPS.
///
/// **Why the driver can't be trusted to do this.** The HPRT LPQ80's bundled PPD
/// is a receipt PPD (`*Product: "(LPQ80ESC)"`, model `POS80`) and its filter
/// reports `islabelprinter = NO`. Parsing what it actually emits confirms it:
/// `ESC @`, a run of `GS v 0` raster blocks, and nothing else — no form feed, no
/// gap seek, at either end of the job. The print lands wherever the paper
/// happens to be sitting. Absent this seek the only thing keeping the artwork on
/// the stickers is that every job feeds a whole number of pitches and so ends in
/// the phase it started, which holds right up until anything moves the roll —
/// a torn label, a new roll, a receipt, a FEED press, the lid.
///
/// It is not free: it is a **second CUPS job**, and CUPS runs a queue's jobs
/// strictly one at a time, tearing the backend down and bringing it back up
/// between them. What the cashier sees is a blank sticker feeding, a pause of a
/// second or more, and only then the label. That is why
/// [CupsLabelRegistration] spends it once per roll registration rather than
/// once per print.
///
/// Die-cut media only. On continuous stock there is no gap to find and the
/// printer feeds until it gives up — the caller gates this on the endpoint's
/// media being a sticker.
///
/// Best effort throughout: a printer that ignores `GS FF` is no worse off than
/// before, so a failure here must never stop the labels from printing.
Future<bool> seekLabelTopViaCups({
  required String? queue,
  required Directory workDir,
}) async {
  try {
    final file = File('${workDir.path}/label-top-seek.bin');
    await file.writeAsBytes(const [0x1d, 0x0c], flush: true);
    final result = await Process.run('lp', [
      if (queue != null && queue.trim().isNotEmpty) ...['-d', queue.trim()],
      '-t', 'label-top-seek',
      // Straight to the device: the raster filter would swallow these two bytes
      // as if they were a document to render.
      '-o', 'raw',
      file.path,
    ]).timeout(const Duration(seconds: 5));
    return result.exitCode == 0;
  } on Object {
    // See above: the labels still print, just without the re-registration.
    return false;
  }
}

/// Which CUPS queues this process has parked on a label's leading edge, and
/// when — the state that lets a label job skip the gap seek.
///
/// A label strip is laid out as a whole number of pitches and is spooled with
/// the driver's paper-save trimming off, so a job ends the roll in the phase it
/// started: once registered, the roll stays registered across back-to-back
/// prints. What breaks that is a human or another job — a torn label, a new
/// roll, a FEED press, the lid, a receipt down the same queue — so the seek is
/// spent when this process cannot vouch for the roll, not once per print.
///
/// Process-lifetime only: a restart re-registers, which is right, because the
/// roll may well have been changed while the app was down.
class CupsLabelRegistration {
  CupsLabelRegistration({
    DateTime Function()? clock,
    this.ttl = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// How long a registration is trusted, measured from the seek that earned it
  /// — not from the last print. Printing is not evidence that the paper is
  /// still where we left it, so a shop that prints a label every few minutes
  /// all day still re-registers on this cadence.
  final Duration ttl;

  final Map<String, DateTime> _registeredAt = <String, DateTime>{};

  static String _key(String? queue) => (queue ?? '').trim();

  bool needsSeek(String? queue) {
    final key = _key(queue);
    final registeredAt = _registeredAt[key];
    if (registeredAt == null) {
      return true;
    }
    if (_clock().difference(registeredAt) >= ttl) {
      _registeredAt.remove(key);
      return true;
    }
    return false;
  }

  /// Records that the roll is parked on a label edge. Anchored to the first
  /// such record after a seek: [needsSeek] drops a stale entry, so a later
  /// print inside the window keeps the original timestamp rather than pushing
  /// the deadline out.
  void markRegistered(String? queue) =>
      _registeredAt.putIfAbsent(_key(queue), _clock);

  void forget(String? queue) => _registeredAt.remove(_key(queue));

  void clear() => _registeredAt.clear();
}

/// The process-wide registration state used by [spoolPdfToCups].
final CupsLabelRegistration cupsLabelRegistration = CupsLabelRegistration();

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
  const CupsSpoolResult.spooled() : supported = true, error = null;
  const CupsSpoolResult.failed(String this.error) : supported = true;
  const CupsSpoolResult.unsupported() : supported = false, error = null;

  final bool supported;
  final String? error;

  bool get succeeded => supported && error == null;
}
