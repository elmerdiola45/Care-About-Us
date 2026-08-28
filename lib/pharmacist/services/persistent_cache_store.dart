import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Tiny persistent key/value store for resilience-fallback caches (right
/// now: the medicine dictionary — see [MedicineDictionaryService]).
///
/// Backed by `shared_preferences`, which is already a dependency. On web
/// that is `window.localStorage`; on mobile/desktop it is the platform's
/// normal per-app store. Both survive an app restart / browser-tab reload,
/// which the services' `static` in-memory caches do not — that gap is the
/// whole reason this exists.
///
/// This is strictly a FALLBACK layer. The owning service still attempts
/// the network first on every cold start, and a successful fetch
/// overwrites whatever is stored here. Anything unreadable — corrupt
/// bytes, a value written by an older/incompatible app version, a storage
/// error — is treated as "absent" (never thrown, never allowed to crash
/// the app) and is replaced on the next successful fetch.
class PersistentCacheStore {
  PersistentCacheStore._();

  /// Bump this whenever the shape of ANY persisted payload changes. Every
  /// entry written under an older schema version then reads back as null,
  /// so stale/incompatible data is discarded rather than mis-parsed.
  static const int _schemaVersion = 1;

  static String _prefsKey(String name) => 'pcache.v$_schemaVersion.$name';

  /// Persists [data] (must be JSON-encodable) under [name]. Best effort:
  /// any failure (quota, unavailable platform, encode error) is swallowed
  /// so persistence can never break the caller's happy path.
  static Future<void> write(String name, Object? data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final envelope = jsonEncode({
        'schema': _schemaVersion,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      });
      await prefs.setString(_prefsKey(name), envelope);
    } catch (_) {
      // Persistence is optional — never surface or rethrow.
    }
  }

  /// Reads back what [write] stored under [name]. Returns null if nothing
  /// is stored, the stored bytes are corrupt, or they were written under
  /// a different schema version. Never throws.
  static Future<Object?> read(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey(name));
      if (raw == null) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['schema'] != _schemaVersion) return null;
      return decoded['data'];
    } catch (_) {
      return null; // corrupt / incompatible -> ignore
    }
  }

  static Future<void> remove(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey(name));
    } catch (_) {
      // best effort
    }
  }
}
