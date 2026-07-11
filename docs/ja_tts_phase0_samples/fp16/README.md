# fp16 model samples — size optimisation

Same g2p / phrases as the parent `../` fp32 samples, but synthesised from a
**float16** export of the ja model to halve download size.

| | size | notes |
|---|---|---|
| model.onnx (fp32) | **163 MB** | original MiaoMint export |
| model.fp16.onnx   | **87 MB**  | float16, 9 float-boundary nodes kept fp32 (noise / stochastic-duration / mask casts) |

fp16 is essentially transparent for VITS: same durations, near-identical levels;
A/B these against the fp32 files in `../` (02 konnichiwa, 03 kinou_ryouri,
08 year_2026, 10 shokuji).

Further shrink options if 87 MB is still too heavy: int8 **static** quantisation
with a small calibration set (~45 MB, needs quality check — dynamic int8 doesn't
work here because the VITS decoder Convs use weight-norm), or a lighter melo-ja
export. The fp16 conversion recipe lives in
`scratchpad/ja_tts_phase0/gen_fp16.py`.
