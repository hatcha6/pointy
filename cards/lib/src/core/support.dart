/// How a customer reaches us: the same WhatsApp line and site as Daftar's
/// own (marketing/website).
abstract final class Support {
  /// International form without the plus, as wa.me wants it.
  static const String whatsApp = '218920010991';

  /// The number as people read it, left to right.
  static const String whatsAppDisplay = '+218 92 001 0991';

  static final Uri whatsAppUrl = Uri.parse('https://wa.me/$whatsApp');

  static final Uri website = Uri.parse('https://dftr.ly');
}
