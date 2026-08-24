// Platform-conditional key/value persistence for AppSession (session.dart).
// See session_storage_web.dart for why web specifically needs a different
// backend (SharedPreferences/localStorage) than every other platform.
export 'session_storage_stub.dart' if (dart.library.html) 'session_storage_web.dart';
