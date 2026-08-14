"""Latency baseline for the exported human net, and fp16 size check.

CoreML EP here is a stand-in for the mobile NPU path; CPU EP is the floor.
Batch 1 vs 3 shows what the profile-batching trick actually buys.
"""

import time

import numpy as np
import onnxruntime as ort

ONNX_PATH = "b18c384nbt-humanv0.onnx"
BOARD = 19


def make_inputs(batch: int):
    rng = np.random.default_rng(0)
    return {
        "bin_input": (rng.random((batch, 22, BOARD, BOARD)) > 0.8).astype(np.float32),
        "global_input": rng.random((batch, 19)).astype(np.float32),
        "input_meta": rng.random((batch, 192)).astype(np.float32),
    }


def bench(provider: str, batch: int, iters: int = 12) -> float | None:
    try:
        sess = ort.InferenceSession(ONNX_PATH, providers=[provider])
    except Exception as e:
        print(f"  {provider} unavailable: {str(e)[:80]}")
        return None
    feeds = make_inputs(batch)
    for _ in range(3):
        sess.run(None, feeds)
    t0 = time.perf_counter()
    for _ in range(iters):
        sess.run(None, feeds)
    return (time.perf_counter() - t0) / iters * 1000


def main():
    print("available providers:", ort.get_available_providers(), "\n")
    print(f"{'provider':<26} {'batch':>5} {'ms/call':>9} {'ms/position':>12}")
    print("-" * 56)
    for provider in ["CPUExecutionProvider", "CoreMLExecutionProvider"]:
        for batch in (1, 3):
            ms = bench(provider, batch)
            if ms is not None:
                print(f"{provider:<26} {batch:>5} {ms:>9.1f} {ms:>12.1f}")

    import onnx
    from onnxconverter_common import float16

    m = onnx.load(ONNX_PATH)
    m16 = float16.convert_float_to_float16(m, keep_io_types=True)
    onnx.save(m16, "b18c384nbt-humanv0.fp16.onnx")
    import os

    print(f"\nfp32: {os.path.getsize(ONNX_PATH) / 1e6:>6.0f} MB")
    print(f"fp16: {os.path.getsize('b18c384nbt-humanv0.fp16.onnx') / 1e6:>6.0f} MB")


if __name__ == "__main__":
    main()
