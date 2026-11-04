/// An installation ID (a UUID, as the relay issues them) found anywhere in
/// [text], lower-cased; null when there is none.
///
/// Whatever was copied is searched, not only a bare ID: an owner may copy the
/// whole line from الإعدادات ← الاشتراك, or a message that carries the ID.
String? installationIdIn(String? text) {
  if (text == null) {
    return null;
  }
  return _installationIdAnywhere.firstMatch(text)?.group(0)?.toLowerCase();
}

final _installationIdAnywhere = RegExp(
  r'(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])',
  caseSensitive: false,
);
