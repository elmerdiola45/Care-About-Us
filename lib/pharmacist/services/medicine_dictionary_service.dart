import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../common/services/app_config.dart';
import '../../common/session.dart';

/// Where the medicine name comes from when the parser corrects an OCR
/// misread — useful for QA/debugging (e.g. "why did it pick this name").
enum DictionarySource { database, fallback }

/// One priced SKU for a matched generic/brand name — e.g. "500 MG" /
/// "Himox" / 20.00. A single medicine name in the dictionary
/// (e.g. "Amoxicillin") can have many of these.
class MedicineVariant {
  /// The literal products-table `name` for this specific SKU (e.g.
  /// "Amoxicillin (Himox 250/60)") — the exact catalog label, as
  /// opposed to brandName/dosageForm which are just the pieces it was
  /// built from. Null only for entries seeded before this field
  /// existed, or a name-only (no variants) dictionary source.
  final String? name;
  final String? brandName;
  final String? dosageForm;
  final double? unitPrice;

  const MedicineVariant({
    this.name,
    this.brandName,
    this.dosageForm,
    this.unitPrice,
  });

  factory MedicineVariant.fromJson(Map<String, dynamic> json) {
    final price = json['unit_price'];
    return MedicineVariant(
      name: json['name']?.toString(),
      brandName: json['brand_name']?.toString(),
      dosageForm: json['dosage_form']?.toString(),
      unitPrice: price == null ? null : double.tryParse(price.toString()),
    );
  }
}

/// Supplies the drug-name dictionary that [PrescriptionParserService] uses
/// for fuzzy-matching OCR output, AND the pricing data
/// [PriceLookupService] uses for the MDRP price section — both come from
/// the same backend call, since this pharmacy's real inventory
/// (CARE-ABOUT-US-PHARMACY.docx, seeded into `products`) is the only
/// source of truth for either. There is no hardcoded medicine list on
/// the Flutter side.
///
/// Pharmacy inventory (backend API) is the only source: it's this
/// pharmacy's real, priced catalog, used for both name-matching and
/// pricing. If the backend call fails or returns nothing, [getDictionary]
/// falls back to whatever was last cached in-memory, or an empty
/// dictionary if nothing has ever loaded successfully — the parser
/// treats "no dictionary match" as "keep the raw OCR text", not as an
/// error, so this degrades safely rather than crashing.
class MedicineDictionaryService {
  static List<String>? _cache;
  static Map<String, List<MedicineVariant>>? _variantCache;

  /// Maps a dictionary key (lowercased) to its real generic name. For a
  /// generic-type entry this equals the key itself; for a brand-type
  /// entry (e.g. "biogesic") this is the actual underlying medicine
  /// (e.g. "Paracetamol") — the piece of information the parser needs
  /// to show the generic as the primary label instead of the brand.
  static Map<String, String>? _genericNameCache;
  static DateTime? _cachedAt;
  static const _cacheTtl = Duration(minutes: 30);

  static Future<List<String>> getDictionary({
    required String pharmacyId,
    bool forceRefresh = false,
  }) async {
    final cacheIsFresh =
        _cache != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl;

    if (!forceRefresh && cacheIsFresh) {
      // ignore: avoid_print
      print(
        'MedicineDictionaryService: serving cached dictionary '
        '(${_cache!.length} names, cached '
        '${DateTime.now().difference(_cachedAt!).inSeconds}s ago) — '
        'NOT re-fetched from backend this call. If this looks stale '
        '(e.g. a name/generic-name mapping you just added isn\'t '
        'showing up in matches), do a full page reload, not just '
        'Re-capture — this cache is in-memory for the tab\'s lifetime '
        'and only expires after 30 minutes or forceRefresh.',
      );
      return _cache!;
    }

    try {
      final token = AppSession.instance.token;
      final response = await http
          .get(
            Uri.parse('${AppConfig.baseUrl}/pharmacies/$pharmacyId/medicines'),
            headers: {
              'Accept': 'application/json',
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        // Print a visible warning rather than silently swallowing this —
        // the fallback below is intentional and safe, but a 404/500
        // here usually means the backend route or seed data isn't set
        // up yet, which is worth knowing about during development even
        // though it never blocks the scan.
        // ignore: avoid_print
        print(
          'MedicineDictionaryService: GET /pharmacies/$pharmacyId/medicines '
          'returned ${response.statusCode} — no medicines dictionary available this call.',
        );
        return _cache ?? const <String>[];
      }

      final decoded = jsonDecode(response.body);

      final List<dynamic> rawList = decoded is List
          ? decoded
          : (decoded['medicines'] as List<dynamic>? ?? []);
      final rawEntryCount = rawList.length;

      final names = <String>[];
      final variantMap = <String, List<MedicineVariant>>{};
      final genericNameMap = <String, String>{};

      for (final e in rawList) {
        // Backward-compatible with a plain {"name": "..."} shape (no
        // variants/pricing) — still usable for name-matching alone.
        final name = e is String ? e : (e['name']?.toString() ?? '');
        final key = name.trim().toLowerCase();
        if (key.isEmpty) continue;
        names.add(key);

        if (e is Map && e['variants'] is List) {
          variantMap[key] = (e['variants'] as List)
              .whereType<Map<String, dynamic>>()
              .map((v) {
                if (v['name'] == null || v['name'].toString().trim().isEmpty) {
                  return MedicineVariant.fromJson({...v, 'name': name});
                }
                return MedicineVariant.fromJson(v);
              })
              .toList();
        } else if (e is Map) {
          // Reached only when `e` has NO nested `variants` list — i.e. a
          // genuinely flat {name, generic_name, brand_name, dosage_form,
          // unit_price} row with no group wrapper, kept for backward
          // compatibility with that shape.
          //
          // This used to run UNCONDITIONALLY after the block above
          // instead of as its `else` — so for the actual backend shape
          // (see MedicineController@index: every entry, generic-group
          // AND each brand-group, always carries a `variants` list and
          // never its own unit_price/dosage_form/brand_name), `e` itself
          // got converted into a SECOND, phantom "variant" for its own
          // name — e.g. the "FERROUS SULFATE" generic-group entry became
          // MedicineVariant(name: "FERROUS SULFATE", unitPrice: null) on
          // top of the 10 real SKUs already unpacked from its `variants`
          // above, and each brand-group entry ("COM-FEMIC", "SORBIFER",
          // "GLOBIFER"...) became its own bogus zero-priced entry the
          // same way. That's exactly where the "FERROUS SULFATE —
          // ₱0.00" / "COM-FEMIC — ₱0.00" duplicates in the brand picker
          // came from — not stale data in `products` (there's no such
          // row there), purely this loop double-counting every group
          // header as if it were also a priced SKU in its own right.
          (variantMap[key] ??= []).add(
            MedicineVariant.fromJson(Map<String, dynamic>.from(e)),
          );
        }

        String? generic;
        if (e is Map && e['generic_name'] != null) {
          generic = e['generic_name'].toString().trim();
          if (generic.isNotEmpty) genericNameMap[key] = generic;
        }

        // This pharmacy's real catalog can arrive either FLAT — each
        // brand/dosage combo ("Amoxicillin 500mg", "Himiox (Amoxicillin
        // 500mg)", "Amoxicillin 250mg") as its OWN top-level entry with
        // its own generic_name, brand_name, dosage_form and unit_price
        // fields directly on it — or GROUPED, as the actual backend
        // returns it (see MedicineController@index): one entry per
        // generic name plus one per brand, each carrying its real SKUs
        // in a nested `variants` list rather than on itself. Only the
        // flat shape needs this extra registration step — a grouped
        // entry's SKUs are already correctly attributed to their
        // generic_name via its own `variants`, unpacked into
        // `variantMap[key]` above (and, for a brand-group entry like
        // "COM-FEMIC", that SKU already lives under the "ferrous
        // sulfate" bucket too, since the generic-group entry's own
        // `variants` list already includes every brand). Re-registering
        // the group HEADER itself here (as this used to do
        // unconditionally) would just add a second, price-less,
        // brand/dosage-less copy under the generic key — the earlier
        // cause of the "COM-FEMIC — ₱0.00" / "SORBIFER — ₱0.00" /
        // "GLOBIFER — ₱0.00" phantom duplicates in the brand-picker
        // dropdown, on top of the already-correct priced entries.
        if (e is Map &&
            e['variants'] is! List &&
            generic != null &&
            generic.isNotEmpty) {
          final genericKey = generic.toLowerCase();
          if (genericKey != key) {
            (variantMap[genericKey] ??= []).add(
              MedicineVariant.fromJson(Map<String, dynamic>.from(e)),
            );
          }
        }
      }

      final dedupedNames = names.toSet().toList();

      if (dedupedNames.isEmpty) {
        // This was the silent path: a 200 with zero usable entries (e.g.
        // {"medicines": []}, or every row missing generic_name) looked
        // identical to a healthy-but-empty pharmacy from here, with
        // nothing printed to say so — "0 entries" downstream had no
        // trail leading back to this being a real 200 response, as
        // opposed to a network/parse failure or the non-200 case above
        // (which do log). Surface it the same way those do.
        // ignore: avoid_print
        print(
          'MedicineDictionaryService: GET /pharmacies/$pharmacyId/medicines '
          'returned 200 but $rawEntryCount raw entr${rawEntryCount == 1 ? 'y' : 'ies'} '
          'yielded 0 usable dictionary names (every entry had an empty/'
          'missing name, or the response had no entries at all) — '
          '${_cache != null ? 'falling back to the ${_cache!.length}-name cache from ${_cachedAt != null ? DateTime.now().difference(_cachedAt!).inSeconds : '?'}s ago' : 'no prior cache to fall back to, returning an empty dictionary'}.',
        );
        return _cache ?? const <String>[];
      }

      _cache = dedupedNames;
      _variantCache = variantMap;
      _genericNameCache = genericNameMap;
      _cachedAt = DateTime.now();
      return dedupedNames;
    } catch (e, st) {
      // This was ALSO silent — a timeout, a socket error, or a
      // jsonDecode() failure on a malformed body all landed here and
      // vanished with no trace, indistinguishable from "server said 0
      // entries" (the case above) or "server said non-200" (logged
      // separately higher up). This is very likely a chunk of what's
      // actually behind reports of "dictionary, 0 entries" — a
      // fetch that never even got a well-formed response.
      // ignore: avoid_print
      print(
        'MedicineDictionaryService: GET /pharmacies/$pharmacyId/medicines '
        'threw $e — ${_cache != null ? 'falling back to the ${_cache!.length}-name cache from ${_cachedAt != null ? DateTime.now().difference(_cachedAt!).inSeconds : '?'}s ago' : 'no prior cache to fall back to, returning an empty dictionary'}.\n$st',
      );
      return _cache ?? const <String>[];
    }
  }

  /// Priced SKUs for [name] (case-insensitive), as returned by the
  /// pharmacy's own inventory. Call [getDictionary] first so the cache
  /// this reads from is populated.
  static List<MedicineVariant> variantsFor(String name) {
    return _variantCache?[name.trim().toLowerCase()] ?? const [];
  }

  /// The real generic name behind [name] (case-insensitive), if the
  /// dictionary knows one — differs from [name] itself only when [name]
  /// matched a brand-type entry (e.g. "biogesic" -> "Paracetamol").
  /// Null if [name] isn't in the dictionary at all.
  static String? genericNameFor(String name) {
    return _genericNameCache?[name.trim().toLowerCase()];
  }

  /// Searches the already-loaded dictionary/variant cache for [query]
  /// (case-insensitive, matches against each entry's own catalog key).
  /// There is no separate network call here — [getDictionary] must have
  /// already populated the cache earlier in the OCR review pipeline
  /// (see [_upgradeFallbackMatchesWithFuzzyCorrection], which always
  /// runs first), so this pharmacy's full catalog is already in memory
  /// by the time a row needs resolving. Returns the closest matches
  /// first: exact key match, then prefix match, then substring match.
  static Future<List<MedicineVariant>> searchProducts(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final variantCache = _variantCache;
    if (variantCache == null || variantCache.isEmpty) return const [];

    final exact = <MedicineVariant>[];
    final prefix = <MedicineVariant>[];
    final substring = <MedicineVariant>[];

    variantCache.forEach((key, variants) {
      if (key == q) {
        exact.addAll(variants);
      } else if (key.startsWith(q) || q.startsWith(key)) {
        prefix.addAll(variants);
      } else if (key.contains(q) || q.contains(key)) {
        substring.addAll(variants);
      }
    });

    // The same SKU can be registered under both its own key and its
    // generic's key (see getDictionary), so dedupe by the fields that
    // actually distinguish one priced SKU from another.
    final seen = <String>{};
    final results = <MedicineVariant>[];
    for (final v in [...exact, ...prefix, ...substring]) {
      final dedupeKey = '${v.name}|${v.brandName}|${v.dosageForm}';
      if (seen.add(dedupeKey)) results.add(v);
    }
    return results;
  }

  static void invalidateCache() {
    _cache = null;
    _variantCache = null;
    _genericNameCache = null;
    _cachedAt = null;
  }
}
