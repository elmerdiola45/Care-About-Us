// OCR accuracy evaluation for PrescriptionParserService.
//
// Runs every case in test/ocr_eval/cases/*.json through the parser, using
// the real `products` catalog exported to test/ocr_eval/catalog.json, and
// reports medicine-level precision/recall plus dosage/quantity accuracy.
//
//   flutter test test/ocr_eval/ocr_eval_test.dart
//
// Precision = of the medicines the parser produced, how many are real
//             (low precision = "may lumalabas na hindi naman gamot").
// Recall    = of the medicines actually on the prescription, how many
//             were found.
//
// This is a measurement, not a pass/fail gate — it only fails on a
// malformed case file. The full report is also written to
// build/ocr_eval/report.json so before/after runs can be compared.
//
// Adding a real case: scan a prescription in the app, copy the text
// between ---START--- and ---END--- from the "[DEBUG] Raw Gemini text"
// console log into "raw_text", and write what is ACTUALLY on the paper
// into "expected". Set "source" to "real".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/models/prescription_scan_result.dart';
import 'package:pharmacy_management_system/pharmacist/services/medicine_dictionary_service.dart';
import 'package:pharmacy_management_system/pharmacist/services/prescription_parser_service.dart';

const _evalDir = 'test/ocr_eval';

class _Expected {
  final List<String> names;
  final String dosage;
  final String quantity;

  _Expected(this.names, this.dosage, this.quantity);

  factory _Expected.fromJson(Map<String, dynamic> j) => _Expected(
    [j['name'] as String, ...((j['aliases'] as List?)?.cast<String>() ?? [])],
    j['dosage']?.toString() ?? '',
    j['quantity']?.toString() ?? '',
  );
}

class _Case {
  final String id;
  final String source;
  final String rawText;
  final List<_Expected> expected;

  _Case(this.id, this.source, this.rawText, this.expected);

  factory _Case.fromJson(Map<String, dynamic> j) => _Case(
    j['id'] as String,
    j['source']?.toString() ?? 'unknown',
    j['raw_text'] as String,
    (j['expected'] as List)
        .map((e) => _Expected.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

List<_Case> _loadCases() {
  final files =
      Directory('$_evalDir/cases')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final cases = <_Case>[];
  for (final f in files) {
    final decoded = jsonDecode(f.readAsStringSync());
    final list = decoded is List ? decoded : [decoded];
    cases.addAll(list.map((e) => _Case.fromJson(e as Map<String, dynamic>)));
  }
  return cases;
}

/// Seeds MedicineDictionaryService exactly the way getDictionary() would
/// after parsing MedicineController@index: one entry per effective
/// generic, plus one per brand (keyed by the brand's first word) unless
/// that key already exists as a generic.
List<String> _seedCatalog() {
  final products =
      (jsonDecode(File('$_evalDir/catalog.json').readAsStringSync())
              as Map<String, dynamic>)['products']
          as List;

  String effectiveGeneric(Map p) {
    final g = p['generic_name']?.toString().trim() ?? '';
    return g.isNotEmpty ? g : p['name'].toString();
  }

  MedicineVariant toVariant(Map p) =>
      MedicineVariant.fromJson(Map<String, dynamic>.from(p));

  final variants = <String, List<MedicineVariant>>{};
  final generics = <String, String>{};

  for (final p in products.cast<Map>()) {
    final g = effectiveGeneric(p);
    final key = g.trim().toLowerCase();
    (variants[key] ??= []).add(toVariant(p));
    generics[key] = g;
  }
  final genericKeys = variants.keys.toSet();
  for (final p in products.cast<Map>()) {
    final brand = p['brand_name']?.toString().trim() ?? '';
    if (brand.isEmpty) continue;
    final key = brand.split(' ').first.toLowerCase();
    if (genericKeys.contains(key)) continue;
    (variants[key] ??= []).add(toVariant(p));
    generics.putIfAbsent(key, () => effectiveGeneric(p));
  }

  MedicineDictionaryService.debugSeedCache(
    variants: variants,
    generics: generics,
  );
  return variants.keys.toList();
}

String _letters(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

String _normDosage(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[\s.]'), '');

String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

bool _namesMatch(_Expected e, PrescriptionMedicine p) {
  final predicted = [
    p.name,
    p.brand,
    MedicineDictionaryService.genericNameFor(p.name) ?? '',
  ].map(_letters).where((s) => s.isNotEmpty);
  for (final exp in e.names.map(_letters)) {
    for (final got in predicted) {
      if (exp == got) return true;
      // "Ascorbic" vs "Ascorbic Acid", "Neozep" vs "Neozep Forte".
      final shorter = exp.length < got.length ? exp : got;
      if (shorter.length >= 5 && (exp.startsWith(got) || got.startsWith(exp))) {
        return true;
      }
    }
  }
  return false;
}

String _describe(PrescriptionMedicine m) => [
  m.name,
  if (m.brand.isNotEmpty) '(${m.brand})',
  if (m.dosage.isNotEmpty) m.dosage,
  if (m.quantity.isNotEmpty) '#${m.quantity}',
].join(' ');

void main() {
  test('OCR parser accuracy report', () async {
    // Cases captured by capture_cases.py start with a TODO placeholder in
    // "expected"; they can't be scored until someone fills that in.
    final allCases = _loadCases();
    final pending = allCases
        .where((c) => c.expected.any((e) => e.names.first.startsWith('TODO')))
        .toList();
    final cases = allCases.where((c) => !pending.contains(c)).toList();
    expect(cases, isNotEmpty, reason: 'No cases in $_evalDir/cases');
    final dictionary = _seedCatalog();

    var expectedTotal = 0, predictedTotal = 0, truePositives = 0;
    var dosageChecked = 0, dosageCorrect = 0;
    var quantityChecked = 0, quantityCorrect = 0;
    final caseReports = <Map<String, dynamic>>[];
    final out = StringBuffer();

    for (final c in cases) {
      // The parser prints several [DEBUG] lines per medicine; keep the
      // report readable by swallowing them.
      final result = runZoned(
        () => PrescriptionParserService.parse(
          c.rawText,
          engineUsed: 'eval',
          drugDictionary: dictionary,
        ),
        zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
      );

      final predicted = List<PrescriptionMedicine>.from(result.medicines);
      final unmatchedPredicted = List<PrescriptionMedicine>.from(predicted);
      final missed = <_Expected>[];
      final wrongFields = <String>[];

      for (final e in c.expected) {
        final hit = unmatchedPredicted.where((p) => _namesMatch(e, p));
        if (hit.isEmpty) {
          missed.add(e);
          continue;
        }
        final p = hit.first;
        unmatchedPredicted.remove(p);
        truePositives++;

        if (e.dosage.isNotEmpty) {
          dosageChecked++;
          if (_normDosage(p.dosage) == _normDosage(e.dosage)) {
            dosageCorrect++;
          } else {
            wrongFields.add(
              '${e.names.first}: dosage "${p.dosage}" (expected ${e.dosage})',
            );
          }
        }
        if (e.quantity.isNotEmpty) {
          quantityChecked++;
          if (_digits(p.quantity) == _digits(e.quantity)) {
            quantityCorrect++;
          } else {
            wrongFields.add(
              '${e.names.first}: qty "${p.quantity}" (expected ${e.quantity})',
            );
          }
        }
      }

      expectedTotal += c.expected.length;
      predictedTotal += predicted.length;

      final tp = c.expected.length - missed.length;
      out.writeln(
        '${c.id} [${c.source}]  found $tp/${c.expected.length}'
        '${unmatchedPredicted.isEmpty ? '' : ', ${unmatchedPredicted.length} FAKE'}',
      );
      for (final p in unmatchedPredicted) {
        out.writeln('    FAKE    ${_describe(p)}');
      }
      for (final e in missed) {
        out.writeln('    MISSED  ${e.names.first}');
      }
      for (final w in wrongFields) {
        out.writeln('    WRONG   $w');
      }

      caseReports.add({
        'id': c.id,
        'source': c.source,
        'expected': c.expected.length,
        'found': tp,
        'fake': unmatchedPredicted.map(_describe).toList(),
        'missed': missed.map((e) => e.names.first).toList(),
        'wrong_fields': wrongFields,
      });
    }

    double pct(int a, int b) => b == 0 ? 0 : 100 * a / b;
    final precision = pct(truePositives, predictedTotal);
    final recall = pct(truePositives, expectedTotal);
    final f1 = precision + recall == 0
        ? 0.0
        : 2 * precision * recall / (precision + recall);
    final fakes = predictedTotal - truePositives;

    final summary = {
      'cases': cases.length,
      'real_cases': cases.where((c) => c.source == 'real').length,
      'expected_medicines': expectedTotal,
      'predicted_medicines': predictedTotal,
      'correct_medicines': truePositives,
      'fake_medicines': fakes,
      'precision_pct': double.parse(precision.toStringAsFixed(1)),
      'recall_pct': double.parse(recall.toStringAsFixed(1)),
      'f1_pct': double.parse(f1.toStringAsFixed(1)),
      'dosage_accuracy_pct': double.parse(
        pct(dosageCorrect, dosageChecked).toStringAsFixed(1),
      ),
      'quantity_accuracy_pct': double.parse(
        pct(quantityCorrect, quantityChecked).toStringAsFixed(1),
      ),
    };

    for (final c in pending) {
      out.writeln('${c.id} [${c.source}]  SKIPPED — fill in "expected" first');
    }

    out
      ..writeln()
      ..writeln('================ OCR PARSER ACCURACY ================')
      ..writeln(
        'Cases: ${cases.length} (${summary['real_cases']} real)   '
        'Catalog: ${dictionary.length} names',
      )
      ..writeln(
        'Precision: ${precision.toStringAsFixed(1)}%   '
        '($truePositives of $predictedTotal found medicines are real, '
        '$fakes fake)',
      )
      ..writeln(
        'Recall:    ${recall.toStringAsFixed(1)}%   '
        '($truePositives of $expectedTotal prescribed medicines found)',
      )
      ..writeln('F1:        ${f1.toStringAsFixed(1)}%')
      ..writeln(
        'Dosage:    ${summary['dosage_accuracy_pct']}%   '
        '($dosageCorrect/$dosageChecked)',
      )
      ..writeln(
        'Quantity:  ${summary['quantity_accuracy_pct']}%   '
        '($quantityCorrect/$quantityChecked)',
      )
      ..writeln('=====================================================');

    // ignore: avoid_print
    print(out);

    final reportFile = File('build/ocr_eval/report.json');
    reportFile.parent.createSync(recursive: true);
    reportFile.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'summary': summary, 'cases': caseReports}),
    );

    MedicineDictionaryService.invalidateCache();
  });
}
