/// Compile-time configuration for the API backend URL.
///
/// The URL is provided at build time via:
///   flutter build web --dart-define=API_BASE_URL=https://your-backend.example.com/api
///
/// ---
/// Development (debug/profile builds):
///   If API_BASE_URL is not provided, the app falls back to the local
///   Laravel backend at http://127.0.0.1:8000/api. This only works when
///   running the backend locally (e.g. `php artisan serve`).
///
/// Production (release builds):
///   API_BASE_URL MUST be explicitly provided. There is no localhost
///   fallback — falling back to 127.0.0.1 in production is unsafe because
///   that address resolves to the user's own machine on a web browser or
///   the device itself on a physical phone, silently breaking every
///   API call with connection failures. If the URL is missing, a clear
///   StateError is thrown the first time a request is made.
///
///   The Vercel → Render deployment provides the Render backend URL
///   through --dart-define=API_BASE_URL at build time.
class AppConfig {
  static String get baseUrl {
    const providedUrl = String.fromEnvironment('API_BASE_URL');
    if (providedUrl.isNotEmpty) return providedUrl;

    // dart.vm.product is true only in release (production) builds.
    const isProduction = bool.fromEnvironment('dart.vm.product');
    if (!isProduction) {
      return 'http://127.0.0.1:8000/api';
    }

    throw StateError(
      'API_BASE_URL is not configured. Production (release) builds must '
      'provide it via --dart-define=API_BASE_URL=<your-backend-url>/api '
      'during compilation. Falling back to http://127.0.0.1:8000/api is '
      'unsafe in production because 127.0.0.1 resolves to the device '
      'itself on a physical phone or deployed environment.',
    );
  }
}
