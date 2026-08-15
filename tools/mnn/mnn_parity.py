"""Does the MNN conversion of the human-SL net still produce KataGo's numbers?

ONNX Runtime has no Android GPU backend, so reaching the phone's GPU means
switching runtime. MNN is the cheapest candidate (direct ONNX converter, OpenCL
and Vulkan backends on Android). The only real risk is whether this architecture
-- nested-bottleneck blocks with global pooling -- survives conversion, so check
the outputs against ORT before doing any Android work.
"""

import json
import struct
import time
from pathlib import Path

import MNN.expr as expr
import MNN.nn as nn
import numpy as np
import onnxruntime as ort

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"
ONNX = Path.home() / ".katrain/b18c384nbt-humanv0.onnx"
MNN_MODEL = HERE / "humanv0.mnn"


def gtp(i: int) -> str:
    return "pass" if i == 361 else f"{'ABCDEFGHJKLMNOPQRST'[i % 19]}{19 - i // 19}"


IN_NAMES = ["bin_input", "global_input", "input_meta"]
OUT_NAMES = ["policy", "value", "lead"]


def load_inputs():
    raw = (ASSETS / "position.bin").read_bytes()
    n = 22 * 19 * 19
    bin_ = np.array(struct.unpack(f"<{n}f", raw[: 4 * n]), dtype=np.float32).reshape(1, 22, 19, 19)
    glob = np.array(struct.unpack("<19f", raw[4 * n : 4 * n + 76]), dtype=np.float32).reshape(1, 19)
    ref = json.loads((ASSETS / "reference.json").read_text())
    return bin_, glob, ref


def main():
    bin_, glob, ref = load_inputs()
    sess = ort.InferenceSession(str(ONNX), providers=["CPUExecutionProvider"])
    net = nn.load_module_from_file(str(MNN_MODEL), IN_NAMES, OUT_NAMES)

    print(f"{'profile':<14}{'ORT top':>9}{'MNN top':>9}{'max|dpolicy|':>14}{'dlead':>9}")
    worst = 0.0
    mismatches = 0
    for name, d in ref["profiles"].items():
        meta = np.array(d["meta"], dtype=np.float32).reshape(1, -1)

        o_pol, _, o_lead = sess.run(None, {"bin_input": bin_, "global_input": glob, "input_meta": meta})
        outs = net.forward(
            [
                expr.const(bin_, list(bin_.shape), expr.NCHW),
                expr.const(glob, list(glob.shape), expr.NCHW),
                expr.const(meta, list(meta.shape), expr.NCHW),
            ]
        )
        m_pol = np.array(outs[0].read()).reshape(-1)
        m_lead = float(np.array(outs[2].read()).reshape(-1)[0])

        o = o_pol[0].astype(np.float64)
        m = m_pol.astype(np.float64)
        diff = float(np.max(np.abs(o - m)))
        worst = max(worst, diff)
        oi, mi = int(np.argmax(o)), int(np.argmax(m))
        if oi != mi:
            mismatches += 1
        print(f"{name:<14}{gtp(oi):>9}{gtp(mi):>9}{diff:>14.2e}{abs(float(o_lead[0]) - m_lead):>9.3f}")

    print(f"\nworst policy diff {worst:.3e}, top-1 mismatches {mismatches}/{len(ref['profiles'])}")
    print("GATE:", "PASS" if worst < 1e-3 and mismatches == 0 else "FAIL")

    # Rough desktop throughput check; says nothing about mobile GPU, but confirms
    # the runtime is actually usable rather than merely correct.
    meta = np.array(next(iter(ref["profiles"].values()))["meta"], dtype=np.float32).reshape(1, -1)
    args = [
        expr.const(bin_, list(bin_.shape), expr.NCHW),
        expr.const(glob, list(glob.shape), expr.NCHW),
        expr.const(meta, list(meta.shape), expr.NCHW),
    ]
    for _ in range(2):
        net.forward(args)
    t0 = time.perf_counter()
    for _ in range(5):
        net.forward(args)
    mnn_ms = (time.perf_counter() - t0) / 5 * 1000

    feeds = {"bin_input": bin_, "global_input": glob, "input_meta": meta}
    for _ in range(2):
        sess.run(None, feeds)
    t0 = time.perf_counter()
    for _ in range(5):
        sess.run(None, feeds)
    ort_ms = (time.perf_counter() - t0) / 5 * 1000

    print(f"\ndesktop CPU: MNN {mnn_ms:.0f} ms/eval, ORT {ort_ms:.0f} ms/eval")


if __name__ == "__main__":
    main()
