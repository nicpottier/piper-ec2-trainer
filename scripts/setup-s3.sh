#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

echo "=== S3 Setup for ${LANG_NAME} TTS Training ==="
echo ""

# Create bucket
echo "Creating S3 bucket: ${S3_BUCKET} in ${S3_REGION} ..."
aws s3 mb "s3://${S3_BUCKET}" --region "${S3_REGION}" 2>/dev/null || echo "Bucket already exists"

# Check that prepared data exists
if [ ! -d "$SCRIPT_DIR/../prepared_data" ]; then
    echo "ERROR: prepared_data/ directory not found."
    echo "Run scripts/prepare-data.py first to prepare training data."
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/../prepared_data/metadata.csv" ]; then
    echo "ERROR: prepared_data/metadata.csv not found."
    echo "Run scripts/prepare-data.py first to prepare training data."
    exit 1
fi

# Upload prepared data
echo ""
echo "Uploading training data to S3..."
aws s3 sync "$SCRIPT_DIR/../prepared_data/" "s3://${S3_BUCKET}/${S3_DATA_PREFIX}/" --region "${S3_REGION}"

echo ""
echo "Upload complete."
echo "Data location: s3://${S3_BUCKET}/${S3_DATA_PREFIX}/"
