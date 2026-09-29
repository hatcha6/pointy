/// QR codes built to survive a tired thermal printer.
///
/// A receipt QR is read off paper that a worn head printed with dead dots,
/// faded patches and smudged edges, so every choice here trades capacity for
/// robustness: the highest error correction (H, ~30% of the symbol can be
/// lost), the fewest bits for the payload so the symbol stays small and its
/// modules big on the same paper, and a quiet zone the renderers keep clear.
/// The thermal encoder and the PDF documents both draw this one matrix, so
/// the two paths print the same symbol.
library;

import 'package:qr/qr.dart';

/// What a dialled card's QR code holds: a `tel:` link a phone's camera offers
/// to dial.
///
/// `#` is escaped as `%23`. Left bare it starts a URI fragment, and the phone
/// dials the code without it — `*112*…` instead of `*112*…#` — which the
/// network rejects. `*` needs no escape. Null for anything that is not a
/// plain dial string, so a malformed one never becomes a code a customer
/// trusts.
String? dialQrData(String dial) {
  final value = dial.trim();
  if (!_dialString.hasMatch(value)) {
    return null;
  }
  return 'tel:${value.replaceAll('#', '%23')}';
}

final RegExp _dialString = RegExp(r'^[0-9*#]{3,40}$');

/// What the QR code of a card nobody dials holds: its PIN, exactly as printed.
///
/// An ISP's card is typed into a portal and a gift card into a store, and a
/// sixteen-character code copied off a phone's camera is one nobody mistypes
/// — so the code is the PIN itself, which every phone offers to copy. Never a
/// guessed redemption link: a wrong one sends the customer somewhere else with
/// a card they paid for. Null for a PIN a phone could misread (anything but
/// printable ASCII) or too long for a receipt code.
String? pinQrData(String pin) {
  final value = pin.trim();
  if (value.length < 4 ||
      value.length > 64 ||
      !_printableAscii.hasMatch(value)) {
    return null;
  }
  return value;
}

final RegExp _printableAscii = RegExp(r'^[\x20-\x7E]+$');

/// A QR symbol at error-correction level H, in its smallest version.
class PrintQrCode {
  PrintQrCode._(this._image);

  /// Encodes [data], or returns null when it cannot be encoded at all.
  ///
  /// Printable ASCII only. A byte segment names no character set, readers
  /// disagree about what a byte above 127 means (Latin-1 by the standard,
  /// UTF-8 by guesswork), and the `qr` package cannot write the ECI header
  /// that would settle it — so text a phone might misread gets no code.
  static PrintQrCode? tryEncode(String data) {
    if (data.isEmpty || !_printableAscii.hasMatch(data)) {
      return null;
    }
    final segments = _fewestBitSegments(data);
    for (var version = 1; version <= 40; version++) {
      final code = QrCode(version, QrErrorCorrectLevel.H);
      for (final segment in segments) {
        switch (segment.mode) {
          case _Mode.numeric:
            code.addNumeric(segment.text);
          case _Mode.alphanumeric:
            code.addAlphaNumeric(segment.text);
          case _Mode.byte:
            code.addData(segment.text);
        }
      }
      try {
        return PrintQrCode._(QrImage(code));
      } on InputTooLongException {
        continue;
      }
    }
    return null;
  }

  /// Blank modules the standard asks for on every side. Renderers leave this
  /// much paper clear around the symbol; a phone cannot find a code that runs
  /// into the text beside it.
  static const int quietZone = 4;

  final QrImage _image;

  /// Modules along one side of the symbol, quiet zone excluded.
  int get moduleCount => _image.moduleCount;

  /// Modules along one side with the quiet zone on both edges.
  int get moduleCountWithQuietZone => moduleCount + 2 * quietZone;

  /// The QR version (1–40): 1 is 21 modules a side, each step adds four.
  int get version => _image.typeNumber;

  bool isDark(int row, int column) => _image.isDark(row, column);
}

enum _Mode { numeric, alphanumeric, byte }

class _Segment {
  const _Segment(this.mode, this.text);

  final _Mode mode;
  final String text;
}

/// The characters QR's alphanumeric mode can carry: capitals, digits and nine
/// symbols. A dial string (`*112*…%23`) fits it entirely, except the `tel`.
const String _alphanumeric = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/// Splits [data] into numeric, alphanumeric and byte segments using the
/// fewest bits, counting each segment's own header.
///
/// A `tel:` link as one byte segment needs a version bigger than the same
/// link split `tel` + `:*112*…%23`, and a bigger version means smaller
/// modules on the same paper. Exact rather than a heuristic: the payload is
/// a few dozen characters, so trying every split is instant. Header sizes are
/// those of versions 1–9, which every receipt payload fits in; a longer one
/// still encodes, just not optimally.
List<_Segment> _fewestBitSegments(String data) {
  final count = data.length;
  final best = List<int?>.filled(count + 1, null)..[0] = 0;
  final cameFrom = List<(int, _Mode)?>.filled(count + 1, null);
  for (var start = 0; start < count; start++) {
    final before = best[start];
    if (before == null) {
      continue;
    }
    for (final mode in _Mode.values) {
      for (var end = start + 1; end <= count; end++) {
        if (!_carries(mode, data[end - 1])) {
          break;
        }
        final bits =
            before +
            4 +
            _countIndicatorBits(mode) +
            _dataBits(mode, end - start);
        final known = best[end];
        if (known == null || bits < known) {
          best[end] = bits;
          cameFrom[end] = (start, mode);
        }
      }
    }
  }
  final segments = <_Segment>[];
  var end = count;
  while (end > 0) {
    final (start, mode) = cameFrom[end]!;
    segments.add(_Segment(mode, data.substring(start, end)));
    end = start;
  }
  return segments.reversed.toList(growable: false);
}

bool _carries(_Mode mode, String char) => switch (mode) {
  _Mode.numeric => '0123456789'.contains(char),
  _Mode.alphanumeric => _alphanumeric.contains(char),
  _Mode.byte => true,
};

int _countIndicatorBits(_Mode mode) => switch (mode) {
  _Mode.numeric => 10,
  _Mode.alphanumeric => 9,
  _Mode.byte => 8,
};

/// Bits for [length] characters of one segment. ASCII is one byte a
/// character, which is all [PrintQrCode.tryEncode] accepts.
int _dataBits(_Mode mode, int length) => switch (mode) {
  _Mode.numeric => 10 * (length ~/ 3) + const [0, 4, 7][length % 3],
  _Mode.alphanumeric => 11 * (length ~/ 2) + 6 * (length % 2),
  _Mode.byte => 8 * length,
};
