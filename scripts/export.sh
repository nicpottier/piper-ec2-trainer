#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

echo "=== Export Piper TTS Model to ONNX ==="
echo ""

TRAINING_DIR="${EC2_OUTPUT_DIR}/training"
EXPORT_DIR="${EC2_OUTPUT_DIR}/exported"

mkdir -p "${EXPORT_DIR}"

# Find the latest/best checkpoint
echo "Looking for best checkpoint ..."
BEST_CKPT=""

# First look for a "best" checkpoint
BEST_CKPT=$(find "${TRAINING_DIR}/lightning_logs" -name "*best*" -name "*.ckpt" -type f 2>/dev/null | sort | tail -1)

# Fallback to latest checkpoint by modification time
if [ -z "${BEST_CKPT}" ]; then
    BEST_CKPT=$(find "${TRAINING_DIR}/lightning_logs" -name "*.ckpt" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
fi

if [ -z "${BEST_CKPT}" ]; then
    echo "ERROR: No checkpoint file found in ${TRAINING_DIR}/lightning_logs/"
    echo "Make sure training has run and produced at least one checkpoint."
    exit 1
fi

echo "  Using checkpoint: ${BEST_CKPT}"

# Export to ONNX
echo ""
echo "Exporting to ONNX ..."
ONNX_OUTPUT="${EXPORT_DIR}/${ONNX_NAME}.onnx"

python3 -m piper_train.export_onnx \
    "${BEST_CKPT}" \
    "${ONNX_OUTPUT}"

echo "  Exported: ${ONNX_OUTPUT}"

# Copy the config.json alongside the ONNX file
CONFIG_SRC="${TRAINING_DIR}/config.json"
CONFIG_DST="${EXPORT_DIR}/${ONNX_NAME}.onnx.json"

if [ -f "${CONFIG_SRC}" ]; then
    cp "${CONFIG_SRC}" "${CONFIG_DST}"
    echo "  Config:   ${CONFIG_DST}"
else
    echo "  WARNING: config.json not found at ${CONFIG_SRC}"
    echo "  The ONNX model needs a config.json to run with Piper."
fi

# Upload to S3
echo ""
echo "Uploading exported model to S3 ..."
aws s3 cp "${ONNX_OUTPUT}" \
    "s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/${ONNX_NAME}.onnx" \
    --region "${S3_REGION}"

if [ -f "${CONFIG_DST}" ]; then
    aws s3 cp "${CONFIG_DST}" \
        "s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/${ONNX_NAME}.onnx.json" \
        --region "${S3_REGION}"
fi

echo ""
echo "=== Export Complete ==="
echo ""
echo "Model files:"
echo "  ONNX:   ${ONNX_OUTPUT}"
echo "  Config:  ${CONFIG_DST}"
echo ""
echo "S3 location:"
echo "  s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/"
echo ""
echo "To test the model locally:"
echo "  pip install piper-tts"
echo "  echo 'test text' | piper --model ${ONNX_OUTPUT} --output_file test.wav"
echo "  # or download from S3:"
echo "  aws s3 cp s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/${ONNX_NAME}.onnx ."
echo "  aws s3 cp s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/${ONNX_NAME}.onnx.json ."
echo "  echo 'test text' | piper --model ${ONNX_NAME}.onnx --output_file test.wav"
