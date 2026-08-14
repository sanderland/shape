"""Generate featurizer fixtures: the gate for the Dart port of board.py + features.py.

Emits, for a set of deliberately awkward positions, the exact bin_input (22 planes)
and global_input (19) that KataGo's Python featurizer produces. The Dart port must
reproduce these byte-for-byte.

Positions are chosen to break a naive port: ladders (planes 14-17 need a full ladder
search), ko (plane 6), captures, passes (globals 0-4), suicide-adjacent shapes, and
both board sizes and rulesets.
"""

import base64
import json
import os
from pathlib import Path

import numpy as np
from compare import BOARD_SIZE, CKPT, GTP_COLS
from katago.game.board import Board
from katago.game.features import Features
from katago.game.gamestate import GameState
from katago.train.load_model import load_model

OUT = Path(os.environ.get("SHAPE_FIXTURES_OUT", Path(__file__).resolve().parent / "assets"))

RULESETS = {"japanese": GameState.RULES_JAPANESE, "chinese": GameState.RULES_CHINESE}


def gtp_to_xy(gtp: str, size: int) -> tuple[int, int]:
    return GTP_COLS.index(gtp[0].upper()), size - int(gtp[1:])


def xy_to_gtp(x: int, y: int, size: int) -> str:
    return f"{GTP_COLS[x]}{size - y}"


def random_moves(size: int, n: int, seed: int, pass_every: int = 0) -> list[str]:
    """Seeded random legal play.

    Random play on a small board produces captures, ko and plenty of 1-2 liberty
    groups, which is what exercises the ladder search -- far better coverage than
    sequences hand-derived by eye.
    """
    rng = np.random.default_rng(seed)
    state = GameState(size, GameState.RULES_JAPANESE)
    pla = Board.BLACK
    moves: list[str] = []
    for i in range(n):
        if pass_every and i % pass_every == pass_every - 1:
            state.play(pla, Board.PASS_LOC)
            moves.append("pass")
            pla = Board.get_opp(pla)
            continue
        cands = [
            (x, y) for y in range(size) for x in range(size) if state.board.board[state.board.loc(x, y)] == Board.EMPTY
        ]
        rng.shuffle(cands)
        for x, y in cands:
            loc = state.board.loc(x, y)
            if state.board.would_be_legal(pla, loc):
                state.play(pla, loc)
                moves.append(xy_to_gtp(x, y, size))
                pla = Board.get_opp(pla)
                break
        else:
            break
    return moves


def random_moves_until_ko(size: int, seeds: range) -> list[str]:
    """Find a position whose last move was a single-stone capture, i.e. a live ko.

    Plane 6 (simple_ko_point) is otherwise never exercised: random play almost never
    *ends* on a ko capture, so searching for one explicitly is the only way to cover it.
    """
    for seed in seeds:
        rng = np.random.default_rng(seed)
        state = GameState(size, GameState.RULES_JAPANESE)
        pla = Board.BLACK
        moves: list[str] = []
        for _ in range(size * size * 2):
            cands = [
                (x, y)
                for y in range(size)
                for x in range(size)
                if state.board.board[state.board.loc(x, y)] == Board.EMPTY
            ]
            rng.shuffle(cands)
            for x, y in cands:
                loc = state.board.loc(x, y)
                if state.board.would_be_legal(pla, loc):
                    state.play(pla, loc)
                    moves.append(xy_to_gtp(x, y, size))
                    pla = Board.get_opp(pla)
                    break
            else:
                break
            if state.board.simple_ko_point is not None:
                return moves
    raise RuntimeError("no ko position found; widen the seed range")


CASES = [
    ("empty19", 19, "japanese", []),
    ("opening", 19, "japanese", ["Q4", "D4", "Q16", "D16", "R14"]),
    ("pass_then_move", 19, "japanese", ["Q4", "pass", "D4"]),
    ("double_pass", 19, "japanese", ["Q4", "D4", "pass", "pass"]),
    ("many_passes", 19, "japanese", ["Q4", "pass", "D4", "pass", "Q16", "pass"]),
    ("corner", 19, "japanese", ["A1", "B1", "A2", "B2", "A3", "B3", "C1", "A4"]),
    ("dense", 19, "japanese", ["Q4", "D4", "Q16", "D16", "R14", "C14", "R6", "F3", "K10", "K4", "K16", "C6"]),
    ("opening_chinese", 19, "chinese", ["Q4", "D4", "Q16", "D16", "R14"]),
    # Random play: captures, ko, atari, ladder-eligible groups.
    ("rand9_a", 9, "japanese", random_moves(9, 40, seed=1)),
    ("rand9_b", 9, "japanese", random_moves(9, 70, seed=2)),
    ("rand9_c", 9, "chinese", random_moves(9, 70, seed=3)),
    ("rand9_passes", 9, "japanese", random_moves(9, 40, seed=4, pass_every=7)),
    ("rand13", 13, "japanese", random_moves(13, 90, seed=5)),
    ("rand19_a", 19, "japanese", random_moves(19, 60, seed=6)),
    ("rand19_b", 19, "japanese", random_moves(19, 150, seed=7)),
    ("rand19_c", 19, "chinese", random_moves(19, 150, seed=8)),
    ("ko9", 9, "japanese", random_moves_until_ko(9, range(100))),
    ("ko19", 19, "japanese", random_moves_until_ko(19, range(100))),
]


def build(size: int, ruleset: str, moves: list[str]) -> GameState:
    state = GameState(size, RULESETS[ruleset])
    pla = Board.BLACK
    for mv in moves:
        if mv == "pass":
            state.play(pla, Board.PASS_LOC)
        else:
            x, y = gtp_to_xy(mv, size)
            state.play(pla, state.board.loc(x, y))
        pla = Board.get_opp(pla)
    return state


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    model, swa_model, _ = load_model(str(CKPT), use_swa=False, device="cpu", pos_len=BOARD_SIZE, verbose=False)
    model = swa_model if swa_model is not None else model
    features = Features(model.config, model.pos_len)

    out = []
    totals = np.zeros(22, dtype=int)
    for name, size, ruleset, moves in CASES:
        state = build(size, ruleset, moves)
        bin_np, global_np = state.get_input_features(features)
        # bin planes are strictly 0/1 here, so pack them as bytes.
        flat = bin_np.astype(np.float32).ravel()
        assert set(np.unique(flat)).issubset({0.0, 1.0}), f"{name}: non-binary bin_input"
        packed = base64.b64encode(flat.astype(np.uint8).tobytes()).decode()
        out.append(
            {
                "name": name,
                "boardSize": size,
                "ruleset": ruleset,
                "moves": moves,
                "nextPlayer": "B" if state.board.pla == Board.BLACK else "W",
                "binB64": packed,
                "global": [float(v) for v in global_np.ravel()],
            }
        )
        # Per-plane counts, so we can assert the awkward planes are actually exercised.
        planes = bin_np.reshape(22, -1).sum(axis=1).astype(int)
        totals[:] = totals + planes
        print(
            f"{name:<16} {size}x{size} {ruleset:<9} mv={len(moves):>3} "
            f"ko={planes[6]} hist={planes[9:14].sum():>2} ladder={planes[14]},{planes[15]},{planes[16]},{planes[17]} "
            f"area={planes[18]},{planes[19]}"
        )

    print("\nplane coverage across all fixtures:")
    for i, t in enumerate(totals):
        print(f"  plane {i:>2}: {t}")
    # These are the planes a naive port gets wrong; refuse to ship fixtures that don't test them.
    for p in (3, 4, 5, 6, 9, 14, 15, 16):
        assert totals[p] > 0, f"plane {p} never set in any fixture -- coverage gap"

    path = OUT / "featurizer_fixtures.json"
    path.write_text(json.dumps({"posLen": BOARD_SIZE, "cases": out}))
    print(f"\n{path}: {path.stat().st_size / 1024:.0f} KB, {len(out)} cases")


if __name__ == "__main__":
    main()
