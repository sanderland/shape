"""Calibrate the move-verdict thresholds against the actual distribution.

The app labels a move "above your level" when moveLikeTarget = tP/(pP+tP) >= 0.5,
i.e. when the target rank likes it even marginally more than the player's rank.
0.5 is the point of NO evidence, so ~half of all moves clear it by chance.

This measures, over realistic positions from human-like self-play, where
moveLikeTarget actually lands for:
  - moves a player of the player's rank would really pick
  - moves a player of the target rank would really pick
A usable threshold has to separate those two.
"""

from pathlib import Path

import numpy as np
import onnxruntime as ort
from katago.game.features import Features
from katago.game.gamestate import GameState
from katago.train.load_model import load_model
from profiles import get_profile

PLAYER = "rank_5k"
TARGET = "rank_2d"
GAME_MOVES = 80
SEED = 7
# App defaults (shape_game.dart): topK 50, minP 0.05.
TOP_K, MIN_P = 50, 0.05


def policy_of(sess, feats, state, profile):
    b, g = state.get_input_features(feats)
    meta = (
        get_profile(profile)
        .get_metadata_row(nextPlayer=state.board.pla, boardArea=361)
        .astype(np.float32)
        .reshape(1, -1)
    )
    pol, _, _ = sess.run(
        None,
        {"bin_input": b.astype(np.float32), "global_input": g.astype(np.float32), "input_meta": meta},
    )
    return pol[0].astype(np.float64)


def sample_move(policy, state, rng):
    """Mirror PolicyData.sample + pick: top_k / min_p over legal board points."""
    cands = []
    for y in range(19):
        for x in range(19):
            loc = state.board.loc(x, y)
            if state.board.would_be_legal(state.board.pla, loc):
                p = policy[y * 19 + x]
                if p > 0:
                    cands.append((p, loc))
    if not cands:
        return None
    cands.sort(reverse=True)
    best = cands[0][0]
    kept = [c for i, c in enumerate(cands[:TOP_K]) if c[0] >= MIN_P * best]
    probs = np.array([c[0] for c in kept])
    probs = probs / probs.sum()
    return kept[rng.choice(len(kept), p=probs)][1]


def mlt(tP, pP, floor=0.0):
    tP, pP = max(tP, floor), max(pP, floor)
    return tP / max(tP + pP, 1e-12)


def main():
    m, swa, _ = load_model(
        str(Path.home() / ".katrain/b18c384nbt-humanv0.ckpt"),
        use_swa=False,
        device="cpu",
        pos_len=19,
        verbose=False,
    )
    m = swa or m
    feats = Features(m.config, m.pos_len)
    sess = ort.InferenceSession(
        str(Path.home() / ".katrain/b18c384nbt-humanv0.onnx"), providers=["CPUExecutionProvider"]
    )
    rng = np.random.default_rng(SEED)

    state = GameState(19, GameState.RULES_JAPANESE)
    played, target_like = [], []

    for _ in range(GAME_MOVES):
        pol_p = policy_of(sess, feats, state, PLAYER)
        pol_t = policy_of(sess, feats, state, TARGET)

        # What a player of each rank would actually pick here.
        mv_p = sample_move(pol_p, state, rng)
        mv_t = sample_move(pol_t, state, rng)
        if mv_p is None or mv_t is None:
            break

        for mv, bucket in ((mv_p, played), (mv_t, target_like)):
            x, y = state.board.loc_x(mv), state.board.loc_y(mv)
            bucket.append((pol_t[y * 19 + x], pol_p[y * 19 + x]))

        state.play(state.board.pla, mv_p)

    print(f"{GAME_MOVES} positions of {PLAYER} self-play; player={PLAYER} target={TARGET}\n")

    for floor in (0.0, 0.0005):
        tag = "no floor" if floor == 0 else f"floor {floor:.4f}"
        print(f"--- moveLikeTarget, {tag} ---")
        print(
            f"{'move source':<22}{'median':>8}{'p25':>8}{'p75':>8}{'>=0.50':>8}{'>=0.60':>8}{'>=0.67':>8}{'>=0.75':>8}"
        )
        for name, bucket in ((f"{PLAYER} would play", played), (f"{TARGET} would play", target_like)):
            v = np.array([mlt(t, p, floor) for t, p in bucket])
            print(
                f"{name:<22}{np.median(v):>8.3f}{np.percentile(v, 25):>8.3f}{np.percentile(v, 75):>8.3f}"
                f"{(v >= 0.50).mean():>8.1%}{(v >= 0.60).mean():>8.1%}"
                f"{(v >= 0.667).mean():>8.1%}{(v >= 0.75).mean():>8.1%}"
            )
        print()

    # Separation: how well does a threshold tell the two apart?
    vp = np.array([mlt(t, p) for t, p in played])
    vt = np.array([mlt(t, p) for t, p in target_like])
    print(f"{'threshold':<12}{'flags ' + PLAYER:>18}{'flags ' + TARGET:>18}{'lift':>8}")
    for th in (0.50, 0.55, 0.60, 0.667, 0.75, 0.80):
        a, b = (vp >= th).mean(), (vt >= th).mean()
        print(f"{th:<12.3f}{a:>17.1%}{b:>17.1%}{(b / a if a else float('inf')):>8.2f}")


if __name__ == "__main__":
    main()
