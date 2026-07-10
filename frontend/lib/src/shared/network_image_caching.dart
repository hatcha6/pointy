/// Attachment content URLs carry a signed `?token=` that rotates on every
/// serialization, so the raw URL is useless as a disk-cache key — every
/// catalog refresh would look like a brand-new image. Cache by everything
/// *except* the query (scheme+host+path), which is stable per attachment on a
/// given server; the rotating token still rides along on the actual request.
String? stableImageCacheKey(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.path.isEmpty || !uri.hasQuery) {
    return null; // fall back to the library's default (full-URL) key
  }
  return trimmed.split('?').first;
}
