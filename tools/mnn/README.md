# MNN parity check

`mnn_parity.py` compares the converted MNN model with its ONNX source. It checks
the policy output and score lead for every profile stored in `reference.json`,
then prints a rough CPU timing for both runtimes.

The script expects `humanv0.mnn`, `assets/position.bin`, and
`assets/reference.json` beside itself. It reads the ONNX model from
`~/.katrain/b18c384nbt-humanv0.onnx`. After putting those files in place, run:

```sh
pip install MNN onnxruntime numpy
python tools/mnn/mnn_parity.py
```

The check passes when the largest policy difference is below `1e-3` and both
runtimes choose the same top move for every saved profile.
