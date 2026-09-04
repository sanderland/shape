"""Port of SGFMetadata::getProfile from cpp/neuralnet/sgfmetadata.cpp.

The Python katago.game.sgfmetadata module provides the 192-channel encoding but
NOT the humanSLProfile string -> SGFMetadata mapping, which lives only in C++.

Trap: the C++ struct defaults tcIsUnknown=false while the Python dataclass
defaults it to True, so every profile must set it explicitly or the one-hot
assert in get_metadata_row fires.
"""

import datetime

from katago.game.sgfmetadata import SGFMetadata

# 9d = 1, 8d = 2, ... 1d = 9, 1k = 10, ... 20k = 29
INVERSE_RANK = {f"{d}d": 10 - d for d in range(1, 10)} | {f"{k}k": 9 + k for k in range(1, 21)}


def make_basic_rank_profile(inverse_rank_black: int, inverse_rank_white: int, pre_az: bool) -> SGFMetadata:
    return SGFMetadata(
        inverseBRank=inverse_rank_black,
        inverseWRank=inverse_rank_white,
        bIsHuman=True,
        wIsHuman=True,
        gameRatednessIsUnknown=True,
        tcIsUnknown=False,
        tcIsByoYomi=True,
        mainTimeSeconds=1200,
        periodTimeSeconds=30,
        byoYomiPeriods=5,
        gameDate=datetime.date(2016, 9, 1) if pre_az else datetime.date(2020, 3, 1),
        source=SGFMetadata.SOURCE_KGS,
    )


def _make_pro_profile(date: datetime.date, source: int) -> SGFMetadata:
    return SGFMetadata(
        inverseBRank=1,
        inverseWRank=1,
        bIsHuman=True,
        wIsHuman=True,
        tcIsUnknown=True,
        gameDate=date,
        source=source,
    )


def get_profile(name: str) -> SGFMetadata:
    if name in ("", "_", '""'):
        return SGFMetadata()

    if name.startswith("proyear_"):
        year = int(name.removeprefix("proyear_"))
        if 1800 <= year <= 2020:
            return _make_pro_profile(datetime.date(year, 6, 1), SGFMetadata.SOURCE_GOGOD)
        if 2021 <= year <= 2023:
            return _make_pro_profile(datetime.date(year, 6, 1), SGFMetadata.SOURCE_GO4GO)
        raise ValueError(f"proyear out of range: {year}")

    if name.startswith(("rank_", "preaz_")):
        pre_az = name.startswith("preaz_")
        ranks = name.removeprefix("preaz_") if pre_az else name.removeprefix("rank_")
        if ranks in INVERSE_RANK:
            r = INVERSE_RANK[ranks]
            return make_basic_rank_profile(r, r, pre_az)
        pieces = ranks.split("_")
        if len(pieces) == 2 and all(p in INVERSE_RANK for p in pieces):
            return make_basic_rank_profile(INVERSE_RANK[pieces[0]], INVERSE_RANK[pieces[1]], pre_az)

    raise ValueError(f"Unknown human SL network profile: {name}")
