#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

usage() {
    echo "Usage: $0 --push|--pull [--dir PATH]"
    echo ""
    echo "Sync training checkpoints to/from S3."
    echo ""
    echo "Options:"
    echo "  --push    Upload local checkpoints to S3"
    echo "  --pull    Download checkpoints from S3 to local"
    echo "  --dir     Local checkpoint directory (default: ${EC2_OUTPUT_DIR}/training/lightning_logs)"
    exit 1
}

MODE=""
LOCAL_DIR="${EC2_OUTPUT_DIR}/training/lightning_logs"
S3_PATH="s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/lightning_logs/"

while [ $# -gt 0 ]; do
    case "$1" in
        --push) MODE="push"; shift ;;
        --pull) MODE="pull"; shift ;;
        --dir)  LOCAL_DIR="$2"; shift 2 ;;
        *)      usage ;;
    esac
done

if [ -z "${MODE}" ]; then
    usage
fi

echo "=== Checkpoint Sync ==="
echo "  Mode:      ${MODE}"
echo "  Local dir: ${LOCAL_DIR}"
echo "  S3 path:   ${S3_PATH}"
echo ""

if [ "${MODE}" = "push" ]; then
    if [ ! -d "${LOCAL_DIR}" ]; then
        echo "ERROR: Local directory not found: ${LOCAL_DIR}"
        exit 1
    fi

    CKPT_COUNT=$(find "${LOCAL_DIR}" -name "*.ckpt" -type f 2>/dev/null | wc -l)
    echo "Pushing ${CKPT_COUNT} checkpoint file(s) to S3 ..."

    aws s3 sync "${LOCAL_DIR}/" "${S3_PATH}" \
        --region "${S3_REGION}" \
        --exclude "*.tmp"

    echo "Push complete."

elif [ "${MODE}" = "pull" ]; then
    mkdir -p "${LOCAL_DIR}"

    echo "Pulling checkpoints from S3 ..."
    aws s3 sync "${S3_PATH}" "${LOCAL_DIR}/" \
        --region "${S3_REGION}" \
        --exclude "*.tmp"

    CKPT_COUNT=$(find "${LOCAL_DIR}" -name "*.ckpt" -type f 2>/dev/null | wc -l)
    echo "Pull complete. ${CKPT_COUNT} checkpoint file(s) available locally."
fi
