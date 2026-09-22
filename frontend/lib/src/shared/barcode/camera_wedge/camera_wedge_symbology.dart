/// How much a symbology protects itself, and therefore how many looks a
/// camera needs before a till may believe it.
///
/// This is the whole reason a camera can be *fast* on a payment-terminal QR
/// and has to be *careful* on a bag of rice. It is not a preference: it is
/// what the symbologies actually carry.
///
/// * **2-D codes carry Reed-Solomon error correction.** A QR, Data Matrix,
///   Aztec or PDF417 does not merely detect damage, it corrects it, and a
///   decode that cannot be reconciled fails rather than returning something
///   plausible. They also carry far more redundancy per unit of area, which is
///   why a camera reads them so easily. One good read is worth believing.
///
/// * **Retail 1-D codes carry one check digit, and it is not enough.**
///   Measured on a real product (`tools/camera-wedge-lab`), one EAN-13 read as
///   three different wrong values in 24 scans — 12% — and every one of them
///   passed the mod-10 check digit. The errors were all in the parity-encoded
///   left group with the right half correct, which is what half a barcode
///   blurred or curved away from the lens produces. A single read of these
///   must never be believed.
///
/// * **Some 1-D codes carry nothing at all.** Codabar has no checksum; Code 39
///   and ITF have optional ones that are usually absent, and ITF in particular
///   can produce a clean, short, entirely wrong read when its edges are
///   clipped. These get the most suspicion.
library;

enum CameraWedgeSymbologyClass {
  /// Reed-Solomon corrected. A decode that survives is trustworthy.
  errorCorrected(requiredAgreement: 1),

  /// One check digit, demonstrably passable by a wrong value.
  checkDigit(requiredAgreement: 2),

  /// No meaningful self-protection, or a known partial-read failure mode.
  unprotected(requiredAgreement: 3);

  const CameraWedgeSymbologyClass({required this.requiredAgreement});

  /// How many agreeing reads this kind needs before it may reach a cart.
  final int requiredAgreement;
}

class CameraWedgeSymbology {
  const CameraWedgeSymbology._();

  static const _errorCorrected = {
    'qrcode',
    'qr_code',
    'qr',
    'microqrcode',
    'micro_qr_code',
    'rmqrcode',
    'datamatrix',
    'data_matrix',
    'aztec',
    'pdf417',
  };

  static const _checkDigit = {
    'ean13',
    'ean_13',
    'ean8',
    'ean_8',
    'upca',
    'upc_a',
    'upce',
    'upc_e',
    // Mandatory mod-103; stronger than EAN's mod-10 but still a single check
    // over a code a camera may have read half of.
    'code128',
    'code_128',
    // Two check characters.
    'code93',
    'code_93',
  };

  /// Normalise a decoder's spelling and say how much to trust it.
  ///
  /// An unrecognised name is [CameraWedgeSymbologyClass.unprotected] on
  /// purpose: a symbology this code has never heard of is not one it can
  /// vouch for, and the cost of being wrong in that direction is a slower
  /// scan rather than a wrong sale.
  static CameraWedgeSymbologyClass classify(String name) {
    final key = name.trim().toLowerCase().replaceAll('-', '_');
    final compact = key.replaceAll('_', '');
    if (_errorCorrected.contains(key) || _errorCorrected.contains(compact)) {
      return CameraWedgeSymbologyClass.errorCorrected;
    }
    if (_checkDigit.contains(key) || _checkDigit.contains(compact)) {
      return CameraWedgeSymbologyClass.checkDigit;
    }
    return CameraWedgeSymbologyClass.unprotected;
  }

  /// True when this is a 2-D code, which is what the camera is *for*: a
  /// payment terminal's receipt QR is something the counter wedge cannot read
  /// at all, at any speed.
  static bool isTwoDimensional(String name) =>
      classify(name) == CameraWedgeSymbologyClass.errorCorrected;
}
