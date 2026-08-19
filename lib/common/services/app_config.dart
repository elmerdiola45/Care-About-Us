class AppConfig {
  // Override at build time: flutter run --dart-define=API_BASE_URL=http://your-server/api
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    // defaultValue: 'http://192.168.100.225:8000/api',
    defaultValue: 'http://127.0.0.1:8000/api',
  );
}
