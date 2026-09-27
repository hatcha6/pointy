/// A wall-clock time of day — hours and minutes — as a Django `TimeField`
/// sends it ("22:00:00").
///
/// Deliberately not Flutter's `TimeOfDay`: models stay free of widget imports,
/// and all the app does with one of these is show it and send it back.
class ClockTime {
  const ClockTime(this.hour, this.minute)
    : assert(hour >= 0 && hour < 24),
      assert(minute >= 0 && minute < 60);

  final int hour;
  final int minute;

  static final _pattern = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$');

  /// Parses "HH:MM" or "HH:MM:SS" (seconds dropped). Null for anything else —
  /// including null and the empty string, which is how an unset field arrives.
  static ClockTime? tryParse(Object? value) {
    final match = _pattern.firstMatch(value?.toString().trim() ?? '');
    if (match == null) {
      return null;
    }
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) {
      return null;
    }
    return ClockTime(hour, minute);
  }

  /// "HH:MM:SS", the shape the backend stores.
  String toJson() => '$label:00';

  /// "HH:MM", 24-hour, the way the rest of the app prints a time.
  String get label => '${_twoDigits(hour)}:${_twoDigits(minute)}';

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => label;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
