// Web implementation of session_storage.dart. Uses window.sessionStorage
// instead of SharedPreferences (which on web is just window.localStorage)
// specifically because localStorage is shared across every tab of the same
// origin — logging into a different role/account in one tab silently
// overwrote every other open tab's session on next reload. sessionStorage
// is scoped per tab (but still survives a same-tab reload, which is the
// behavior that actually needs to be preserved), so each tab keeps its own
// logged-in user independently.
import 'package:web/web.dart' as web;

Future<String?> storageGet(String key) async => web.window.sessionStorage.getItem(key);

Future<void> storageSet(String key, String value) async {
  web.window.sessionStorage.setItem(key, value);
}

Future<void> storageRemove(String key) async {
  web.window.sessionStorage.removeItem(key);
}
