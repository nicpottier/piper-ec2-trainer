#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

RESUME=false
if [ "${1:-}" = "--resume" ]; then
    RESUME=true
fi

echo "=== Sinhala TTS Training ==="
echo ""

CKPT_DOWNLOAD_DIR="${EC2_CHECKPOINT_DIR}/hindi-base"
TRAINING_DIR="${EC2_OUTPUT_DIR}/training"

# --- Step 1: Preprocess ---
if [ "$RESUME" = true ]; then
    echo "[1/3] Skipping preprocessing (--resume mode)"
    if [ ! -d "${TRAINING_DIR}" ]; then
        echo "  ERROR: No previous training directory found at ${TRAINING_DIR}"
        echo "  Run without --resume first."
        exit 1
    fi
else
    echo "[1/3] Preprocessing data ..."
    mkdir -p "${TRAINING_DIR}"

    python3 -m piper_train.preprocess \
        --language "${PIPER_LANGUAGE}" \
        --input-dir "${EC2_DATA_DIR}" \
        --output-dir "${TRAINING_DIR}" \
        --dataset-format ljspeech \
        --single-speaker \
        --sample-rate "${PIPER_SAMPLE_RATE}"

    echo "  Preprocessing complete."
fi

# --- Step 2: Find the base checkpoint ---
echo ""
echo "[2/3] Locating base checkpoint for fine-tuning ..."

BASE_CKPT_FILE=""
if [ -d "${CKPT_DOWNLOAD_DIR}" ]; then
    BASE_CKPT_FILE=$(find "${CKPT_DOWNLOAD_DIR}" -name "*.ckpt" -type f | head -1)
fi

if [ -z "${BASE_CKPT_FILE}" ]; then
    echo "  WARNING: No .ckpt file found in ${CKPT_DOWNLOAD_DIR}"
    echo "  Training will start from scratch."
else
    echo "  Using base checkpoint: ${BASE_CKPT_FILE}"
fi

# --- Step 3: Start checkpoint sync to S3 in background ---
echo ""
echo "Starting background checkpoint sync to S3 (every 30 minutes) ..."

(
    while true; do
        sleep 1800
        echo "[checkpoint-sync] Syncing checkpoints to S3 ..."
        aws s3 sync "${TRAINING_DIR}/lightning_logs/" \
            "s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/lightning_logs/" \
            --region "${S3_REGION}" \
            --exclude "*.tmp" 2>/dev/null || true
        echo "[checkpoint-sync] Sync complete at $(date)"
    done
) &
SYNC_PID=$!
echo "  Sync process PID: ${SYNC_PID}"

# Clean up sync process on exit
trap "kill ${SYNC_PID} 2>/dev/null || true" EXIT

# --- Step 4: Train ---
echo ""
echo "[3/3] Starting training ..."
echo "  Language:       ${PIPER_LANGUAGE}"
echo "  Quality:        ${PIPER_QUALITY}"
echo "  Sample rate:    ${PIPER_SAMPLE_RATE}"
echo "  Batch size:     ${PIPER_BATCH_SIZE}"
echo "  Max epochs:     ${PIPER_MAX_EPOCHS}"
echo "  Precision:      ${PIPER_PRECISION}"
echo "  Checkpoint every: ${PIPER_CHECKPOINT_EPOCHS} epochs"
echo ""

# Build the training command
TRAIN_CMD=(
    python3 -m piper_train
    --dataset-dir "${TRAINING_DIR}"
    --accelerator gpu
    --devices 1
    --batch-size "${PIPER_BATCH_SIZE}"
    --validation-split 0.05
    --max_epochs "${PIPER_MAX_EPOCHS}"
    --precision "${PIPER_PRECISION}"
    --quality "${PIPER_QUALITY}"
    --checkpoint-epochs "${PIPER_CHECKPOINT_EPOCHS}"
)

# Add fine-tuning checkpoint (single-speaker uses resume_from_checkpoint)
if [ -n "${BASE_CKPT_FILE}" ]; then
    TRAIN_CMD+=(--resume_from_checkpoint "${BASE_CKPT_FILE}")
fi

# If resuming, find latest local checkpoint
if [ "$RESUME" = true ]; then
    LATEST_CKPT=$(find "${TRAINING_DIR}/lightning_logs" -name "*.ckpt" -type f 2>/dev/null | sort | tail -1)
    if [ -n "${LATEST_CKPT}" ]; then
        echo "  Resuming from: ${LATEST_CKPT}"
        TRAIN_CMD+=(--resume_from_checkpoint "${LATEST_CKPT}")
    else
        echo "  WARNING: No local checkpoint found to resume from. Starting fresh."
    fi
fi

echo "Running: ${TRAIN_CMD[*]}"
echo ""

"${TRAIN_CMD[@]}"

# Final sync after training completes
echo ""
echo "Training complete. Final checkpoint sync to S3 ..."
aws s3 sync "${TRAINING_DIR}/lightning_logs/" \
    "s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/lightning_logs/" \
    --region "${S3_REGION}" \
    --exclude "*.tmp"

echo "Done! Checkpoints synced to s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/"
