"""Stage 0 deliverable: export b18c384nbt-humanv0 to ONNX and validate against katago.

Exports a wrapper exposing only what SHAPE consumes (policy, value, lead), with a
dynamic batch axis. Validates by running all 7 profiles as a SINGLE batch-of-7 --
bin_input/global_input are identical across profiles and only input_meta differs,
which is the batching win the mobile design depends on.
"""

import os
import sys

import numpy as np
import onnxruntime as ort
import torch
from compare import (
    BOARD_SIZE,
    CKPT,
    GTP_COLS,
    PROFILES,
    build_state,
    katago_policies,
    kl,
)
from katago.game.features import Features
from katago.train.load_model import load_model
from profiles import get_profile

ONNX_PATH = os.environ.get("SHAPE_ONNX_OUT", "b18c384nbt-humanv0.onnx")
OPSET = 18


class HumanNet(torch.nn.Module):
    """Exposes just policy / value / lead, keeping the batch dimension."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, bin_input, global_input, input_meta):
        raw = self.model(bin_input, global_input, input_meta=input_meta)
        out = self.model.postprocess_output(raw)[0]
        policy_logits = out[0]  # N, num_policy_outputs, 362
        value_logits = out[1]  # N, 3
        pred_lead = out[10]  # N
        policy = torch.softmax(policy_logits[:, 0, :], dim=1)
        value = torch.softmax(value_logits, dim=1)
        return policy, value, pred_lead


def main():
    state = build_state()

    print("loading pytorch checkpoint...", flush=True)
    model, swa_model, _ = load_model(str(CKPT), use_swa=False, device="cpu", pos_len=BOARD_SIZE, verbose=False)
    model = swa_model if swa_model is not None else model
    model.eval()

    # Identical spatial/global features for every profile; only the meta row differs.
    features = Features(model.config, model.pos_len)
    bin_np, global_np = state.get_input_features(features)
    n = len(PROFILES)
    bin_batch = torch.tensor(np.repeat(bin_np, n, axis=0), dtype=torch.float32)
    global_batch = torch.tensor(np.repeat(global_np, n, axis=0), dtype=torch.float32)
    meta_batch = torch.tensor(
        np.stack(
            [
                get_profile(p).get_metadata_row(nextPlayer=state.board.pla, boardArea=BOARD_SIZE * BOARD_SIZE)
                for p in PROFILES
            ]
        ),
        dtype=torch.float32,
    )
    print(f"inputs: bin {tuple(bin_batch.shape)}  global {tuple(global_batch.shape)}  meta {tuple(meta_batch.shape)}")

    wrapper = HumanNet(model).eval()
    with torch.no_grad():
        torch_policy, _, torch_lead = wrapper(bin_batch, global_batch, meta_batch)

    print(f"\nexporting to {ONNX_PATH} (opset {OPSET})...", flush=True)
    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            (bin_batch, global_batch, meta_batch),
            ONNX_PATH,
            input_names=["bin_input", "global_input", "input_meta"],
            output_names=["policy", "value", "lead"],
            dynamic_axes={
                "bin_input": {0: "batch"},
                "global_input": {0: "batch"},
                "input_meta": {0: "batch"},
                "policy": {0: "batch"},
                "value": {0: "batch"},
                "lead": {0: "batch"},
            },
            opset_version=OPSET,
            dynamo=False,
        )

    print(f"exported: {os.path.getsize(ONNX_PATH) / 1e6:.0f} MB")

    print("\nrunning onnxruntime (single batch-of-7)...", flush=True)
    sess = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
    onnx_policy, _, onnx_lead = sess.run(
        None,
        {
            "bin_input": bin_batch.numpy(),
            "global_input": global_batch.numpy(),
            "input_meta": meta_batch.numpy(),
        },
    )

    # CI has no katago binary; --no-katago keeps the torch<->onnx gate only.
    use_katago = "--no-katago" not in sys.argv
    kata = None
    if use_katago:
        print("querying katago analysis engine...", flush=True)
        kata = katago_policies()
    else:
        print("\nskipping katago verification (--no-katago)")

    print(f"\n{'profile':<14} {'onnx-torch':>11} {'onnx-katago':>12} {'KL':>10} {'top1':>6} {'move':>7}")
    print("-" * 66)
    worst_tt, worst_tk = 0.0, 0.0
    for i, name in enumerate(PROFILES):
        o = onnx_policy[i].astype(np.float64)
        t = torch_policy[i].numpy().astype(np.float64)
        k = kata[name] if kata else None
        legal = k >= 0 if k is not None else np.ones_like(o, dtype=bool)
        o_l, t_l = np.where(legal, o, 0.0), np.where(legal, t, 0.0)
        d_tt = float(np.max(np.abs(o_l - t_l)))
        worst_tt = max(worst_tt, d_tt)
        if k is None:
            oi = int(np.argmax(o_l))
            move = (
                "pass"
                if oi == BOARD_SIZE * BOARD_SIZE
                else f"{GTP_COLS[oi % BOARD_SIZE]}{BOARD_SIZE - oi // BOARD_SIZE}"
            )
            print(f"{name:<14} {d_tt:>11.2e} {'-':>12} {'-':>10} {'-':>6} {move:>7}")
            continue
        k_l = np.where(legal, k, 0.0)
        d_tk = float(np.max(np.abs(o_l - k_l)))
        worst_tk = max(worst_tk, d_tk)
        oi, ki = int(np.argmax(o_l)), int(np.argmax(k_l))
        move = (
            "pass" if ki == BOARD_SIZE * BOARD_SIZE else f"{GTP_COLS[ki % BOARD_SIZE]}{BOARD_SIZE - ki // BOARD_SIZE}"
        )
        print(
            f"{name:<14} {d_tt:>11.2e} {d_tk:>12.2e} {kl(o_l, k_l):>10.2e} "
            f"{'OK' if oi == ki else 'MISMATCH':>6} {move:>7}"
        )

    print(f"\nlead (scoreLead) onnx vs torch: max diff {np.max(np.abs(onnx_lead - torch_lead.numpy())):.2e}")
    print(f"worst onnx-vs-torch : {worst_tt:.3e}")
    gate, worst, ref = ("onnx-vs-torch", worst_tt, "torch") if kata is None else ("onnx-vs-katago", worst_tk, "katago")
    if kata is not None:
        print(f"worst onnx-vs-katago: {worst_tk:.3e}")
    print("GATE:", "PASS" if worst < 1e-3 else "FAIL", f"(threshold 1e-3 vs {ref})")
    if worst >= 1e-3:
        sys.exit(f"{gate} exceeded 1e-3")


if __name__ == "__main__":
    main()
