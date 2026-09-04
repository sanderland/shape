// Verifies the Dart meta encoding against the Python/KataGo reference, element by
// element across all 192 channels and every profile. Runs without an emulator:
//   flutter test
//
// This is the test that catches the tcIsUnknown default trap and any date/rank
// indexing slip, which would otherwise show up only as a subtly wrong policy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/sgf_metadata.dart';

void main() {
  final ref = jsonDecode(
    File('assets/reference.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final nextPlayer = ref['nextPlayer'] == 'W' ? kWhite : kBlack;
  final profiles = (ref['profiles'] as Map).cast<String, dynamic>();

  test('reference covers the profile families we care about', () {
    expect(profiles.keys, containsAll(['rank_20k', 'rank_9d', 'proyear_1985']));
  });

  for (final entry in profiles.entries) {
    test('meta row matches reference: ${entry.key}', () {
      final expected = (entry.value['meta'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
      expect(expected.length, kMetadataChannels);

      final actual = getProfile(entry.key)
          .getMetadataRow(nextPlayer, kBoardSize * kBoardSize);
      expect(actual.length, kMetadataChannels);

      for (var i = 0; i < kMetadataChannels; i++) {
        expect(
          actual[i],
          closeTo(expected[i], 1e-6),
          reason: 'channel $i of ${entry.key}',
        );
      }
    });
  }

  test('unknown profile throws', () {
    expect(() => getProfile('rank_99z'), throwsArgumentError);
    expect(() => getProfile('nonsense'), throwsArgumentError);
  });
}

const int kBoardSize = 19;
