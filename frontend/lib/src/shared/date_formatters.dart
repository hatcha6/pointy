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

String formatMonthYear(DateTime dateTime) {
  return DateFormat('yyyy/MM').format(dateTime);
}
