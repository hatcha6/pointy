/// Tolerant readers for the relay's JSON: a missing or mistyped field reads as
/// empty rather than throwing, so one odd row never blanks a screen.
String readString(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String ? value : (value?.toString() ?? '');
}

int readInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

bool readBool(Map<String, dynamic> json, String key) => json[key] == true;

DateTime? readTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String ? DateTime.tryParse(value) : null;
}

List<Map<String, dynamic>> readList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) {
    return const [];
  }
  return value.whereType<Map<String, dynamic>>().toList(growable: false);
}

Map<String, dynamic> readMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is Map<String, dynamic> ? value : const {};
}
