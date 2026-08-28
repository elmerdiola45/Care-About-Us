// Phase 3: the pharmacist tierFor() must map the backend `status` vocabulary
// (not tier/level names) to AdherenceTier. Before the fix, `pending` and
// `partially_dispensed` fell through to `good`.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/models/adherence.dart';

void main() {
  group('tierFor - backend status vocabulary', () {
    const cases = <String, AdherenceTier>{
      'no_data': AdherenceTier.critical,
      'pending': AdherenceTier.critical,
      'partially_dispensed': AdherenceTier.atRisk,
      'fully_dispensed': AdherenceTier.fullyDispensed,
      'overdispensing': AdherenceTier.overDispensing,
      'over_dispensing': AdherenceTier.overDispensing,
      'good': AdherenceTier.good,
      'at_risk': AdherenceTier.atRisk,
      'critical': AdherenceTier.critical,
    };

    cases.forEach((status, expected) {
      test('$status -> $expected', () {
        expect(tierFor(status), expected);
      });
    });

    test('pending does NOT map to good (regression)', () {
      expect(tierFor('pending'), isNot(AdherenceTier.good));
    });

    test('partially_dispensed does NOT map to good (regression)', () {
      expect(tierFor('partially_dispensed'), isNot(AdherenceTier.good));
    });

    test('unknown status falls back to good', () {
      expect(tierFor('something_else'), AdherenceTier.good);
      expect(tierFor(null), AdherenceTier.good);
    });
  });

  group('AdherenceStatus.tier - end to end from JSON', () {
    AdherenceTier tierFromStatus(String status) =>
        AdherenceStatus.fromJson({'status': status}).tier;

    test('pending -> critical', () => expect(tierFromStatus('pending'), AdherenceTier.critical));
    test('partially_dispensed -> atRisk',
        () => expect(tierFromStatus('partially_dispensed'), AdherenceTier.atRisk));
    test('no_data -> critical', () => expect(tierFromStatus('no_data'), AdherenceTier.critical));
    test('fully_dispensed -> fullyDispensed',
        () => expect(tierFromStatus('fully_dispensed'), AdherenceTier.fullyDispensed));

    test('raw status is preserved for label disambiguation', () {
      expect(AdherenceStatus.fromJson({'status': 'no_data'}).status, 'no_data');
      expect(AdherenceStatus.fromJson({'status': 'pending'}).status, 'pending');
    });
  });
}
