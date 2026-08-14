"""Stage 0 gate: does the PyTorch humanv0 checkpoint reproduce `katago analysis` humanPolicy?

Runs the same position + profile through both and reports max abs diff / KL / top-1
agreement. Uses rootNumSymmetriesToSample=1 so the engine does no symmetry averaging,
matching the plain single-forward-pass the Python reference does.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from katago.game.board import Board
from katago.game.gamestate import GameState
from katago.train.load_model import load_model
from profiles import get_profile

KATRAIN = Path(os.environ.get("SHAPE_MODEL_DIR", Path.home() / ".katrain"))
CKPT = KATRAIN / "b18c384nbt-humanv0.ckpt"
HUMAN_MODEL = KATRAIN / "b18c384nbt-humanv0.bin.gz"
AI_MODEL = KATRAIN / "kata1-b28c512nbt-s11653980416-d5514111622.bin.gz"
CFG = Path(__file__).resolve().parent / "deterministic.cfg"

BOARD_SIZE = 19
KOMI = 6.5
GTP_COLS = "ABCDEFGHJKLMNOPQRST"

# A short opening; enough to make the policy non-trivial and history-dependent.
MOVES = [("B", "Q4"), ("W", "D4"), ("B", "Q16"), ("W", "D16"), ("B", "R14")]

PROFILES = ["rank_20k", "rank_5k", "rank_1d", "rank_9d", "preaz_1k", "proyear_1985", "proyear_2023"]


def gtp_to_xy(gtp: str) -> tuple[int, int]:
    x = GTP_COLS.index(gtp[0].upper())
    y = BOARD_SIZE - int(gtp[1:])
    return x, y


def build_state() -> GameState:
    state = GameState(BOARD_SIZE, GameState.RULES_JAPANESE)
    state.rules["whiteKomi"] = KOMI
    for color, gtp in MOVES:
        x, y = gtp_to_xy(gtp)
        pla = Board.BLACK if color == "B" else Board.WHITE
        state.play(pla, state.board.loc(x, y))
    return state


def torch_policies(model, state: GameState) -> dict[str, np.ndarray]:
    out = {}
    for name in PROFILES:
        res = state.get_model_outputs(model, sgfmeta=get_profile(name))
        policy = np.zeros(BOARD_SIZE * BOARD_SIZE + 1, dtype=np.float64)
        for loc, prob in res["moves_and_probs0"]:
            if loc == Board.PASS_LOC:
                policy[-1] = prob
            else:
                x, y = state.board.loc_x(loc), state.board.loc_y(loc)
                policy[y * BOARD_SIZE + x] = prob
        out[name] = policy
    return out


def katago_policies() -> dict[str, np.ndarray]:
    cmd = [
        "katago",
        "analysis",
        "-config",
        str(CFG),
        "-model",
        str(AI_MODEL),
        "-human-model",
        str(HUMAN_MODEL),
    ]
    queries = [
        json.dumps(
            {
                "id": name,
                "rules": "japanese",
                "komi": KOMI,
                "boardXSize": BOARD_SIZE,
                "boardYSize": BOARD_SIZE,
                "moves": [[c, m] for c, m in MOVES],
                "includePolicy": True,
                "maxVisits": 1,
                "overrideSettings": {
                    "humanSLProfile": name,
                    "ignorePreRootHistory": False,
                    "rootNumSymmetriesToSample": 1,
                },
            }
        )
        for name in PROFILES
    ]
    proc = subprocess.run(cmd, input="\n".join(queries) + "\n", capture_output=True, text=True, timeout=600)
    out = {}
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        resp = json.loads(line)
        if "error" in resp:
            sys.exit(f"katago error for {resp.get('id')}: {resp['error']}\n{proc.stderr[-3000:]}")
        out[resp["id"]] = np.array(resp["humanPolicy"], dtype=np.float64)
    if not out:
        sys.exit(f"no katago output.\nstderr:\n{proc.stderr[-3000:]}")
    return out


def kl(p: np.ndarray, q: np.ndarray) -> float:
    p = np.clip(p, 1e-12, None)
    q = np.clip(q, 1e-12, None)
    p, q = p / p.sum(), q / q.sum()
    return float(np.sum(p * np.log(p / q)))


def main():
    state = build_state()
    print(f"position: {' '.join(m for _, m in MOVES)}  ({len(PROFILES)} profiles)\n")

    print("loading pytorch checkpoint...", flush=True)
    model, swa_model, _ = load_model(str(CKPT), use_swa=False, device="cpu", pos_len=BOARD_SIZE, verbose=False)
    model = swa_model if swa_model is not None else model
    torch_out = torch_policies(model, state)

    print("querying katago analysis engine...", flush=True)
    kata_out = katago_policies()

    print(f"\n{'profile':<14} {'max|diff|':>10} {'KL':>10} {'top1':>6} {'top1 move':>10}")
    print("-" * 56)
    worst = 0.0
    for name in PROFILES:
        t, k = torch_out[name], kata_out[name]
        # katago reports -1 for illegal moves; compare only legal ones
        legal = k >= 0
        t = np.where(legal, t, 0.0)
        k = np.where(legal, k, 0.0)
        diff = float(np.max(np.abs(t - k)))
        worst = max(worst, diff)
        ti, ki = int(np.argmax(t)), int(np.argmax(k))
        agree = "OK" if ti == ki else "MISMATCH"
        move = (
            "pass" if ki == BOARD_SIZE * BOARD_SIZE else f"{GTP_COLS[ki % BOARD_SIZE]}{BOARD_SIZE - ki // BOARD_SIZE}"
        )
        print(f"{name:<14} {diff:>10.2e} {kl(t, k):>10.2e} {agree:>6} {move:>10}")

    print(f"\nworst max|diff| across profiles: {worst:.3e}")
    print("GATE:", "PASS" if worst < 1e-3 else "FAIL", "(threshold 1e-3)")


if __name__ == "__main__":
    main()
