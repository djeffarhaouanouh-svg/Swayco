#!/usr/bin/env bash
# Export the Korean and Arabic Moonshine checkpoints to ONNX and push them to
# djeffar/swayco-stt-models.
#
# UsefulSensors publishes moonshine-tiny-{ko,ar} as PyTorch only, while every
# other language the app supports already has an ONNX export on onnx-community.
# ONNX Runtime (the engine bundled in the app) cannot read PyTorch, so these two
# languages stay dead until this has run once.
#
#   pip install optimum optimum-onnx onnx onnxruntime transformers torch huggingface_hub
#   hf auth login
#   ./scripts/export_moonshine_onnx.sh
#
# Note: `optimum[exporters]` no longer exists — optimum 2.x moved the ONNX
# exporter into the separate `optimum-onnx` distribution. `--optimize O2` is
# skipped on purpose: dynamic int8 quantisation below is what actually shrinks
# the download (140 MB fp32 → ~40 MB), and O2 adds a failure surface for no gain.
#
# Layout produced, matching MoonshineSpec.subdir + files:
#   moonshine-tiny-ko/onnx/encoder_model_quantized.onnx   (~8 MB)
#   moonshine-tiny-ko/onnx/decoder_model_quantized.onnx   (~28 MB)
#   moonshine-tiny-ko/tokenizer.json
#
# Caveat baked into MoonshineEngine: an optimum re-export declares an
# `attention_mask` / `encoder_attention_mask` input that the onnx-community
# graphs do not. The engine inspects `session.inputNames` and feeds the masks
# only when present, so both provenances load through the same code path.

set -euo pipefail

HF_REPO="djeffar/swayco-stt-models"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

for lang in ko ar; do
  src="UsefulSensors/moonshine-tiny-${lang}"
  out="${WORKDIR}/moonshine-tiny-${lang}"

  echo "==> exporting ${src}"
  # A ~3.6e-05 max-diff warning against the reference model is expected and fine.
  optimum-cli export onnx \
    --model "${src}" \
    --task automatic-speech-recognition \
    "${out}"

  echo "==> quantising ${lang} to int8"
  python - "$out" <<'PY'
import pathlib, sys
from onnxruntime.quantization import quantize_dynamic, QuantType

out = pathlib.Path(sys.argv[1])
onnx_dir = out / "onnx"
onnx_dir.mkdir(exist_ok=True)

# optimum writes the graphs at the export root; the app expects them under
# onnx/ with the *_quantized suffix (the onnx-community convention).
for stem in ("encoder_model", "decoder_model"):
    src = out / f"{stem}.onnx"
    if not src.exists():
        raise SystemExit(f"missing {src} — did the export task change?")
    dst = onnx_dir / f"{stem}_quantized.onnx"
    quantize_dynamic(src, dst, weight_type=QuantType.QInt8)
    print(f"    {stem}: {src.stat().st_size/1e6:.0f}MB -> {dst.stat().st_size/1e6:.0f}MB")
    src.unlink()
PY

  # Ship only what SttModelDownloader fetches.
  find "${out}" -maxdepth 1 -type f ! -name 'tokenizer.json' -delete

  echo "==> uploading moonshine-tiny-${lang} to ${HF_REPO}"
  hf upload "${HF_REPO}" "${out}" "moonshine-tiny-${lang}"
done

echo "done — ko/ar now resolvable by SttModelDownloader"
