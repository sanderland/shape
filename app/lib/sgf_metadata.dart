// Dart port of KataGo's human-SL metadata encoding.
//
// Sources:
//   katago/game/sgfmetadata.py  -> getMetadataRow  (the 192-channel encoding)
//   cpp/neuralnet/sgfmetadata.cpp:265 SGFMetadata::getProfile  (string -> profile)
//
// Trap carried over from the Python/C++ split: C++ defaults tcIsUnknown=false while
// the Python dataclass defaults it to true. Every profile sets it explicitly here.

import 'dart:math' as math;
import 'dart:typed_data';

const int kMetadataChannels = 192;

const int kBlack = 1;
const int kWhite = 2;

const int kSourceOgs = 1;
const int kSourceKgs = 2;
const int kSourceFox = 3;
const int kSourceTygem = 4;
const int kSourceGogod = 5;
const int kSourceGo4go = 6;

class SgfMetadata {
  final int inverseBRank;
  final int inverseWRank;
  final bool bIsUnranked;
  final bool wIsUnranked;
  final bool bRankIsUnknown;
  final bool wRankIsUnknown;
  final bool bIsHuman;
  final bool wIsHuman;

  final bool gameIsUnrated;
  final bool gameRatednessIsUnknown;

  final bool tcIsUnknown;
  final bool tcIsNone;
  final bool tcIsAbsolute;
  final bool tcIsSimple;
  final bool tcIsByoYomi;
  final bool tcIsCanadian;
  final bool tcIsFischer;

  final double mainTimeSeconds;
  final double periodTimeSeconds;
  final int byoYomiPeriods;
  final int canadianMoves;

  final DateTime gameDate;
  final int source;

  const SgfMetadata({
    this.inverseBRank = 0,
    this.inverseWRank = 0,
    this.bIsUnranked = false,
    this.wIsUnranked = false,
    this.bRankIsUnknown = false,
    this.wRankIsUnknown = false,
    this.bIsHuman = false,
    this.wIsHuman = false,
    this.gameIsUnrated = false,
    this.gameRatednessIsUnknown = false,
    this.tcIsUnknown = false,
    this.tcIsNone = false,
    this.tcIsAbsolute = false,
    this.tcIsSimple = false,
    this.tcIsByoYomi = false,
    this.tcIsCanadian = false,
    this.tcIsFischer = false,
    this.mainTimeSeconds = 0.0,
    this.periodTimeSeconds = 0.0,
    this.byoYomiPeriods = 0,
    this.canadianMoves = 0,
    required this.gameDate,
    this.source = 0,
  });

  Float32List getMetadataRow(int nextPlayer, int boardArea) {
    final row = Float32List(kMetadataChannels);
    final isWhite = nextPlayer == kWhite;

    row[0] = (isWhite ? wIsHuman : bIsHuman) ? 1.0 : 0.0;
    row[1] = (isWhite ? bIsHuman : wIsHuman) ? 1.0 : 0.0;

    final plaIsUnranked = isWhite ? wIsUnranked : bIsUnranked;
    final oppIsUnranked = isWhite ? bIsUnranked : wIsUnranked;
    row[2] = plaIsUnranked ? 1.0 : 0.0;
    row[3] = oppIsUnranked ? 1.0 : 0.0;

    row[4] = (isWhite ? wRankIsUnknown : bRankIsUnknown) ? 1.0 : 0.0;
    row[5] = (isWhite ? bRankIsUnknown : wRankIsUnknown) ? 1.0 : 0.0;

    const rankStartIdx = 6;
    const rankLenPerPla = 34;
    final invPlaRank = isWhite ? inverseWRank : inverseBRank;
    final invOppRank = isWhite ? inverseBRank : inverseWRank;
    if (!plaIsUnranked) {
      for (var i = 0; i < math.min(invPlaRank, rankLenPerPla); i++) {
        row[rankStartIdx + i] = 1.0;
      }
    }
    if (!oppIsUnranked) {
      for (var i = 0; i < math.min(invOppRank, rankLenPerPla); i++) {
        row[rankStartIdx + rankLenPerPla + i] = 1.0;
      }
    }

    row[74] = gameRatednessIsUnknown ? 0.5 : (gameIsUnrated ? 1.0 : 0.0);

    row[75] = tcIsUnknown ? 1.0 : 0.0;
    row[76] = tcIsNone ? 1.0 : 0.0;
    row[77] = tcIsAbsolute ? 1.0 : 0.0;
    row[78] = tcIsSimple ? 1.0 : 0.0;
    row[79] = tcIsByoYomi ? 1.0 : 0.0;
    row[80] = tcIsCanadian ? 1.0 : 0.0;
    row[81] = tcIsFischer ? 1.0 : 0.0;

    final mainCapped = mainTimeSeconds.clamp(0.0, 3.0 * 86400);
    final periodCapped = periodTimeSeconds.clamp(0.0, 1.0 * 86400);
    row[82] = 0.4 * (math.log(mainCapped + 60.0) - 6.5);
    row[83] = 0.3 * (math.log(periodCapped + 1.0) - 3.0);
    row[84] = 0.5 * (math.log(byoYomiPeriods.clamp(0, 50) + 2.0) - 1.5);
    row[85] = 0.25 * (math.log(canadianMoves.clamp(0, 50) + 2.0) - 1.5);

    row[86] = 0.5 * math.log(boardArea / 361.0);

    final daysDifference =
        gameDate.difference(DateTime.utc(1970, 1, 1)).inDays.toDouble();
    const dateStartIdx = 87;
    const dateLen = 32;
    var period = 7.0;
    final factor = math.pow(80000.0, 1.0 / (dateLen - 1)).toDouble();
    const twopi = 6.283185307179586476925;
    for (var i = 0; i < dateLen; i++) {
      final numRevolutions = daysDifference / period;
      row[dateStartIdx + i * 2 + 0] = math.cos(numRevolutions * twopi);
      row[dateStartIdx + i * 2 + 1] = math.sin(numRevolutions * twopi);
      period *= factor;
    }

    row[151 + source] = 1.0;
    return row;
  }
}

// 9d = 1, 8d = 2, ... 1d = 9, 1k = 10, ... 20k = 29
final Map<String, int> kInverseRank = {
  for (var d = 1; d <= 9; d++) '${d}d': 10 - d,
  for (var k = 1; k <= 20; k++) '${k}k': 9 + k,
};

SgfMetadata _basicRankProfile(int invB, int invW, bool preAz) => SgfMetadata(
      inverseBRank: invB,
      inverseWRank: invW,
      bIsHuman: true,
      wIsHuman: true,
      gameRatednessIsUnknown: true,
      tcIsUnknown: false,
      tcIsByoYomi: true,
      mainTimeSeconds: 1200,
      periodTimeSeconds: 30,
      byoYomiPeriods: 5,
      gameDate: preAz ? DateTime.utc(2016, 9, 1) : DateTime.utc(2020, 3, 1),
      source: kSourceKgs,
    );

SgfMetadata _proProfile(DateTime date, int source) => SgfMetadata(
      inverseBRank: 1,
      inverseWRank: 1,
      bIsHuman: true,
      wIsHuman: true,
      tcIsUnknown: true,
      gameDate: date,
      source: source,
    );

SgfMetadata getProfile(String name) {
  if (name.startsWith('proyear_')) {
    final year = int.parse(name.substring('proyear_'.length));
    if (year >= 1800 && year <= 2020) {
      return _proProfile(DateTime.utc(year, 6, 1), kSourceGogod);
    }
    if (year >= 2021 && year <= 2023) {
      return _proProfile(DateTime.utc(year, 6, 1), kSourceGo4go);
    }
    throw ArgumentError('proyear out of range: $year');
  }
  if (name.startsWith('rank_') || name.startsWith('preaz_')) {
    final preAz = name.startsWith('preaz_');
    final ranks = name.substring(preAz ? 'preaz_'.length : 'rank_'.length);
    final r = kInverseRank[ranks];
    if (r != null) return _basicRankProfile(r, r, preAz);
    final pieces = ranks.split('_');
    if (pieces.length == 2 &&
        kInverseRank.containsKey(pieces[0]) &&
        kInverseRank.containsKey(pieces[1])) {
      return _basicRankProfile(
          kInverseRank[pieces[0]]!, kInverseRank[pieces[1]]!, preAz);
    }
  }
  throw ArgumentError('Unknown human SL network profile: $name');
}
