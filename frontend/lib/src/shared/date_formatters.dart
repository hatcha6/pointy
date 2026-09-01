import 'package:intl/intl.dart';

String formatDateTime(DateTime dateTime) {
  return DateFormat('yyyy/MM/dd HH:mm').format(dateTime.toLocal());
}

String formatDate(DateTime dateTime) {
  return DateFormat('yyyy/MM/dd').format(dateTime.toLocal());
}

String formatTime(DateTime dateTime) {
  return DateFormat('HH:mm').format(dateTime.toLocal());
}

/// Formats a timestamp that carries a device's wall clock rather than a real
/// instant.
///
/// BioTime reports punches as bare local wall-clock times ("2023-02-28
/// 17:33:50") and the backend stores them verbatim, labelled UTC, so that the
/// shift schedule -- also plain wall-clock times -- can be compared against
/// them directly. Running such a value through [formatTime] converts an
/// instant that was never UTC into the viewer's zone and shifts every punch by
/// the local offset (a 17:33 clock-out read 19:33 in Tripoli). Read the wall
/// clock back out instead of translating it.
String formatClockTime(DateTime dateTime) {
  return DateFormat('HH:mm').format(dateTime.toUtc());
}

String formatMonthYear(DateTime dateTime) {
  return DateFormat('yyyy/MM').format(dateTime);
}
