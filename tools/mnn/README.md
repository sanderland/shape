# MNN conversion — GPU path spike

ONNX Runtime has no Android GPU backend (native WebGPU/Vulkan is still an open
feature request), so reaching the phone's GPU means changing runtime. MNN is the
cheapest candidate: it converts ONNX directly and has OpenCL and Vulkan backends
on Android.

The risk was whether this architecture — nested-bottleneck blocks with global
pooling — survives conversion. It does, first try:

```
pip install MNN
mnnconvert -f ONNX --modelFile ~/.katrain/b18c384nbt-humanv0.onnx \
           --MNNModel humanv0.mnn --bizCode shape
python mnn_parity.py
```

Result against ONNX Runtime on the same position, all 7 rank profiles:

```
worst policy diff 4.0e-05, top-1 mismatches 0/7, lead identical
desktop CPU: MNN 36 ms/eval, ORT 32 ms/eval
```

So conversion is not the obstacle. What remains before this can be measured on a
phone:

1. **Android integration.** There is no Flutter plugin for MNN, so it needs a
   platform channel or FFI wrapper around the Android AAR — the same shape as
   `flutter_onnxruntime`, but only the three-input/three-output call we use.
2. **Ship a second model format** (`.mnn`, 107 MB) or switch to it entirely.
3. **Measure OpenCL and Vulkan against the 242 ms CPU baseline** on the target
   device. Conv-heavy nets typically gain 2–5x on a mobile GPU, but that is a
   prior, not a measurement.

Worth doing only if inference latency is actually the thing worth fixing; at
three profiles per position the app currently spends ~0.7 s.
