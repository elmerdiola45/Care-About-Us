// Non-web fallback for session_storage.dart — real Flutter platforms
// (mobile/desktop) don't have the "multiple browser tabs of the same
// origin sharing one storage" problem that motivated the web-only
// sessionStorage-backed implementation, so SharedPreferences (its normal,
// already-correct per-app storage) keeps being used here unchanged.
import 'package:shared_preferences/shared_preferences.dart';

Future<String?> storageGet(String key) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(key);
}

Future<void> storageSet(String key, String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, value);
}

Future<void> storageRemove(String key) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(key);
}
