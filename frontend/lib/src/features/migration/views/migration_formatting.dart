import 'package:file_picker/file_picker.dart';

/// The picked file, as much of it as the UI needs.
typedef PickedFileInfo = PlatformFile;

/// Bytes as a person would say them, in Arabic units.
///
/// Migration deals in gigabytes, and "1610612736" is not a size anybody can
/// judge a download against.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes بايت';
  const units = ['كيلوبايت', 'ميجابايت', 'جيجابايت', 'تيرابايت'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below ten, none above: "1.4 جيجابايت", "340 ميجابايت".
  final text = value >= 10 ? value.round().toString() : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// A short "about this long left" phrase. Deliberately coarse — a countdown
/// accurate to the second on a twenty-minute upload just looks unstable.
String formatDuration(Duration duration) {
  if (duration.inMinutes < 1) return 'أقل من دقيقة';
  if (duration.inMinutes < 60) return '${duration.inMinutes} دقيقة';
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  return minutes == 0 ? '$hours ساعة' : '$hours ساعة و$minutes دقيقة';
}

/// Thousands separators, so 892441 reads as a quantity rather than a serial.
String formatCount(int count) {
  final digits = count.abs().toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return count < 0 ? '-$buffer' : buffer.toString();
}
