// Medicine matching regression tests for the OCR review pipeline.
//
// Covers the brand+dosage / generic+dosage resolution in
// PriceLookupService.lookup() and the NULL-generic catalog fallback.
// The dictionary cache is seeded directly (MedicineDictionaryService
// .debugSeedCache) so no network/DB is involved — these exercise the
// pure matching logic only.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/services/medicine_dictionary_service.dart';
import 'package:pharmacy_management_system/pharmacist/services/price_lookup_service.dart';

MedicineVariant v(
  int id,
  String name,
  String? brand,
  String? dosage,
  double price,
) => MedicineVariant(
  id: id,
  name: name,
  brandName: brand,
  dosageForm: dosage,
  unitPrice: price,
);

/// Seeds the cache the way getDictionary() would after parsing a
/// /medicines response: every SKU appears under its generic key AND its
/// brand key; genericNameFor(key) returns the entry's generic_name.
void seed(
  Map<String, ({String generic, List<MedicineVariant> skus})> entries,
) {
  final variants = <String, List<MedicineVariant>>{};
  final generics = <String, String>{};
  entries.forEach((key, e) {
    variants[key.toLowerCase()] = e.skus;
    generics[key.toLowerCase()] = e.generic;
  });
  MedicineDictionaryService.debugSeedCache(
    variants: variants,
    generics: generics,
  );
}

void main() {
  tearDown(MedicineDictionaryService.invalidateCache);

  // Standard healthy catalog: Amoxicillin with two brands at 500, Thmiox
  // also at 250.
  void seedHealthy() => seed({
    'amoxicillin': (
      generic: 'Amoxicillin',
      skus: [
        v(123, 'Amoxicillin (Thmiox) 500 MG.', 'Thmiox', '500 MG.', 8.50),
        v(124, 'Amoxicillin (Himox) 500 MG.', 'Himox', '500 MG.', 9.00),
        v(125, 'Amoxicillin (Thmiox) 250 MG.', 'Thmiox', '250 MG.', 6.00),
      ],
    ),
    'thmiox': (
      generic: 'Amoxicillin',
      skus: [
        v(123, 'Amoxicillin (Thmiox) 500 MG.', 'Thmiox', '500 MG.', 8.50),
        v(125, 'Amoxicillin (Thmiox) 250 MG.', 'Thmiox', '250 MG.', 6.00),
      ],
    ),
    'himox': (
      generic: 'Amoxicillin',
      skus: [
        v(124, 'Amoxicillin (Himox) 500 MG.', 'Himox', '500 MG.', 9.00),
      ],
    ),
  });

  test('1. correct medicine + correct brand + dosage -> exact DB row', () {
    seedHealthy();
    final r = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '500mg',
      brand: 'Thmiox',
    );
    expect(r.productId, 123);
    expect(r.canonicalName, 'Amoxicillin');
    expect(r.unitPrice, 8.50);
    expect(r.medicineNotFound, isFalse);
  });

  test('2. JUMBLED medicine + correct brand + dosage -> correct DB row '
      '(critical case)', () {
    seedHealthy();
    for (final jumbled in ['Amoxicilin', 'Amoxcillin', 'Amox', 'Amoxicilln']) {
      final r = PriceLookupService.lookup(
        jumbled,
        dosage: '500mg',
        brand: 'Thmiox',
      );
      expect(r.productId, 123, reason: 'for "$jumbled"');
      expect(r.canonicalName, 'Amoxicillin', reason: 'for "$jumbled"');
      expect(r.unitPrice, 8.50, reason: 'for "$jumbled"');
    }
  });

  test('3. correct medicine + slightly misspelled brand + dosage -> '
      'fuzzy brand match, flagged inexact', () {
    seedHealthy();
    // "Himoox" is one inserted letter from "Himox" and NOT close to any
    // other brand in the seed (3 edits from "Thmiox"), so it stays
    // unambiguous. (An OCR misread that IS ~1 edit from two different
    // brands — e.g. "Hmiox" vs Himox/Thmiox — is deliberately NOT
    // auto-resolved; see the "brand not in catalog" / ambiguity tests.)
    final r = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '500mg',
      brand: 'Himoox',
    );
    expect(r.productId, 124);
    expect(r.canonicalName, 'Amoxicillin');
    expect(r.isExactMatch, isFalse, reason: 'fuzzy brand -> verify flag');
  });

  test('4. correct brand + wrong dosage -> not silently matched to a '
      'different strength', () {
    seedHealthy();
    final r = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '900mg', // Thmiox is only 250/500
      brand: 'Thmiox',
    );
    // brand-first defers; generic path reports the gap rather than
    // resolving 900mg to a 500mg SKU.
    expect(r.dosageNotStocked, isTrue);
    expect(r.variant, isNull);
  });

  test('5. same brand, multiple dosages -> dosage disambiguates', () {
    seedHealthy();
    final r250 = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '250mg',
      brand: 'Thmiox',
    );
    expect(r250.productId, 125);
    expect(r250.unitPrice, 6.00);

    final r500 = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '500mg',
      brand: 'Thmiox',
    );
    expect(r500.productId, 123);
  });

  test('6. same brand + dosage but multiple different products -> '
      'ambiguous, never auto-picked', () {
    seed({
      'unibrand': (
        generic: '', // brand entry spanning two generics
        skus: [
          v(301, 'Cefalexin (Unibrand) 500 MG.', 'Unibrand', '500 MG.', 12.0),
          v(302, 'Cloxacillin (Unibrand) 500 MG.', 'Unibrand', '500 MG.', 13.0),
        ],
      ),
      'cefalexin': (
        generic: 'Cefalexin',
        skus: [
          v(301, 'Cefalexin (Unibrand) 500 MG.', 'Unibrand', '500 MG.', 12.0),
        ],
      ),
      'cloxacillin': (
        generic: 'Cloxacillin',
        skus: [
          v(302, 'Cloxacillin (Unibrand) 500 MG.', 'Unibrand', '500 MG.', 13.0),
        ],
      ),
    });
    final r = PriceLookupService.lookup(
      'Cefalexin',
      dosage: '500mg',
      brand: 'Unibrand',
    );
    expect(r.needsBrandSelection, isTrue);
    expect(r.variant, isNull, reason: 'must not arbitrarily select');
    expect(r.candidates.length, 2);
  });

  test('7. medicine exists but zero stock -> resolves to catalog; '
      'no stock check happens at this layer', () {
    seedHealthy();
    final r = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '500mg',
      brand: 'Thmiox',
    );
    // "not found" is about the CATALOG only. Live stock is a separate,
    // backend concern — this layer never reports "not stocked".
    expect(r.medicineNotFound, isFalse);
    expect(r.productId, 123);
  });

  test('8. medicine does not exist -> medicineNotFound', () {
    seedHealthy();
    final r = PriceLookupService.lookup(
      'Rifampicin',
      dosage: '300mg',
      brand: 'Nonexistent',
    );
    expect(r.medicineNotFound, isTrue);
    expect(r.productId, isNull);
    expect(r.canonicalName, isNull);
  });

  test('9. no brand available -> generic + dosage matching still works', () {
    seedHealthy();
    final r = PriceLookupService.lookup('Amoxicillin', dosage: '250mg');
    // one SKU at 250 -> resolved
    expect(r.productId, 125);
    expect(r.unitPrice, 6.00);
  });

  test('10. product has NULL generic_name (pre-migration) -> still '
      'resolvable via brand+dosage, canonical name = best available', () {
    // getDictionary keys the row under its own name and builds a brand
    // entry whose generic_name is that same fallback name.
    seed({
      'amoxicillin (thmiox) 500 mg.': (
        generic: 'Amoxicillin (Thmiox) 500 MG.',
        skus: [
          v(123, 'Amoxicillin (Thmiox) 500 MG.', 'Thmiox', '500 MG.', 8.50),
        ],
      ),
      'thmiox': (
        generic: 'Amoxicillin (Thmiox) 500 MG.',
        skus: [
          v(123, 'Amoxicillin (Thmiox) 500 MG.', 'Thmiox', '500 MG.', 8.50),
        ],
      ),
    });
    final r = PriceLookupService.lookup(
      'garbledtext',
      dosage: '500mg',
      brand: 'Thmiox',
    );
    expect(r.productId, 123, reason: 'no longer "not found"');
    expect(r.unitPrice, 8.50);
    expect(r.medicineNotFound, isFalse);
    expect(r.canonicalName, isNotNull);
  });

  test('11. product has clean generic_name (post-migration / sheet had '
      'it) -> canonical name is the real generic', () {
    seedHealthy();
    final r = PriceLookupService.lookup(
      'xxx',
      dosage: '500mg',
      brand: 'Thmiox',
    );
    expect(r.canonicalName, 'Amoxicillin');
    expect(r.productId, 123);
  });

  test('12. productId is populated on every positive resolution '
      '(survives into the review result)', () {
    seedHealthy();
    expect(
      PriceLookupService.lookup('a', dosage: '500mg', brand: 'Thmiox').productId,
      123,
    );
    expect(
      PriceLookupService.lookup('a', dosage: '250mg', brand: 'Thmiox').productId,
      125,
    );
    expect(
      PriceLookupService.lookup('Amoxicillin', dosage: '500mg', brand: 'Himox')
          .productId,
      124,
    );
  });

  test('brand not in catalog -> falls through to generic path, not '
      'hijacked', () {
    seedHealthy();
    final r = PriceLookupService.lookup(
      'Amoxicillin',
      dosage: '500mg',
      brand: 'BrandWeNeverStocked',
    );
    // generic "Amoxicillin" has two SKUs at 500 (Thmiox/Himox), brand
    // named isn't one of them -> pharmacist picks.
    expect(r.needsBrandSelection, isTrue);
  });
}
