"""Emit the Flutter app's assets for the single-position slice.

- position.bin : float32 bin_input[22*19*19] then float32 global_input[19]
- reference.json: desktop ONNX policy top-20 per profile, so the app can prove its
  on-device output matches desktop rather than merely producing *something*.
"""

import json
import os
import struct
from pathlib import Path

import numpy as np
import onnxruntime as ort
from compare import BOARD_SIZE, CKPT, GTP_COLS, MOVES, PROFILES, build_state
from katago.game.features import Features
from katago.train.load_model import load_model
from profiles import get_profile

OUT = Path(os.environ.get("SHAPE_ASSETS_OUT", Path(__file__).resolve().parent / "assets"))
ONNX_PATH = Path(os.environ.get("SHAPE_ONNX_OUT", Path.home() / ".katrain" / "b18c384nbt-humanv0.onnx"))


def gtp(i: int) -> str:
    if i == BOARD_SIZE * BOARD_SIZE:
        return "pass"
    return f"{GTP_COLS[i % BOARD_SIZE]}{BOARD_SIZE - i // BOARD_SIZE}"


def main():
    OUT.mkdir(exist_ok=True)
    state = build_state()

    model, swa_model, _ = load_model(str(CKPT), use_swa=False, device="cpu", pos_len=BOARD_SIZE, verbose=False)
    model = swa_model if swa_model is not None else model
    features = Features(model.config, model.pos_len)
    bin_np, global_np = state.get_input_features(features)

    bin_f = bin_np.astype(np.float32).ravel()
    glob_f = global_np.astype(np.float32).ravel()
    assert bin_f.size == 22 * BOARD_SIZE * BOARD_SIZE and glob_f.size == 19, (bin_f.size, glob_f.size)
    (OUT / "position.bin").write_bytes(
        struct.pack(f"<{bin_f.size}f", *bin_f) + struct.pack(f"<{glob_f.size}f", *glob_f)
    )
    print(f"position.bin: {(OUT / 'position.bin').stat().st_size} bytes")

    # Desktop reference outputs, one batch-1 call per profile.
    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    ref = {}
    for name in PROFILES:
        meta = (
            get_profile(name)
            .get_metadata_row(nextPlayer=state.board.pla, boardArea=BOARD_SIZE * BOARD_SIZE)
            .astype(np.float32)
        )
        policy, value, lead = sess.run(
            None,
            {
                "bin_input": bin_np.astype(np.float32),
                "global_input": global_np.astype(np.float32),
                "input_meta": meta.reshape(1, -1),
            },
        )
        p = policy[0].astype(np.float64)
        top = np.argsort(p)[::-1][:20]
        ref[name] = {
            "meta": [float(v) for v in meta],  # full 192-vector, for exact Dart port comparison
            "lead": float(lead[0]),
            "top": [{"idx": int(i), "gtp": gtp(int(i)), "p": float(p[i])} for i in top],
        }
        print(f"{name:<14} top={gtp(int(top[0])):>5} p={p[top[0]]:.4f}  lead={lead[0]:+.2f}  metasum={meta.sum():.4f}")

    board = [["." for _ in range(BOARD_SIZE)] for _ in range(BOARD_SIZE)]
    for color, mv in MOVES:
        x = GTP_COLS.index(mv[0])
        y = BOARD_SIZE - int(mv[1:])
        board[y][x] = color
    (OUT / "reference.json").write_text(
        json.dumps(
            {
                "moves": [{"color": c, "gtp": m} for c, m in MOVES],
                "board": board,
                "nextPlayer": "W" if len(MOVES) % 2 else "B",
                "profiles": ref,
            },
            indent=1,
        )
    )
    print(f"\nreference.json: {(OUT / 'reference.json').stat().st_size} bytes")


if __name__ == "__main__":
    main()
