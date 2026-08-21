/// Extracts the secret verify token from a scanned/pasted value that's a
/// `.../verify/{token}` URL (the format printed QR codes now encode — see
/// SavedPrescriptionsStore.updateQrToken()). Returns '' if [value] isn't
/// such a URL. Scheme-agnostic (http/https) and ignores query params, since
/// only the path segments are inspected.
///
/// Shared by every QR-scanning entry point in the app so URL detection
/// behaves identically regardless of which scanner (or platform) is used.
String extractTokenFromUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return '';
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length >= 2 && segments[segments.length - 2] == 'verify') {
    return segments.last;
  }
  return '';
}
