import 'package:intl/intl.dart';

String formatDateTime(DateTime dateTime) {
  return DateFormat('yyyy/MM/dd HH:mm').format(dateTime.toLocal());
}

String formatDate(DateTime dateTime) {
  return DateFormat('yyyy/MM/dd').format(dateTime.toLocal());
}
