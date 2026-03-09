#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/../config.env"

echo "=== Stopping EC2 Instance ==="
echo ""

INSTANCE_FILE="$PROJECT_DIR/.instance_id"

if [ ! -f "${INSTANCE_FILE}" ]; then
    echo "ERROR: .instance_id file not found."
    echo "Cannot determine which instance to stop."
    exit 1
fi

INSTANCE_ID=$(cat "${INSTANCE_FILE}")
echo "Instance ID: ${INSTANCE_ID}"

# Check instance state
STATE=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${EC2_REGION}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

echo "Current state: ${STATE}"

if [ "${STATE}" = "terminated" ]; then
    echo "Instance is already terminated."
    rm -f "${INSTANCE_FILE}"
    exit 0
fi

if [ "${STATE}" = "running" ]; then
    # Sync checkpoints before terminating
    echo ""
    echo "Syncing checkpoints to S3 before termination ..."

    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "${INSTANCE_ID}" \
        --region "${EC2_REGION}" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    echo "  Attempting remote checkpoint sync via SSH ..."
    echo "  (This will fail gracefully if SSH is not configured)"

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -i ~/.ssh/${EC2_KEY_NAME}.pem \
        ubuntu@${PUBLIC_IP} \
        "aws s3 sync ${EC2_OUTPUT_DIR}/training/lightning_logs/ s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/lightning_logs/ --region ${S3_REGION} --exclude '*.tmp'" \
        2>/dev/null || echo "  Remote sync skipped (could not connect)."
fi

# Terminate the instance
echo ""
echo "Terminating instance ${INSTANCE_ID} ..."
aws ec2 terminate-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${EC2_REGION}" \
    --output text

# Cancel any associated spot requests
echo "Cancelling associated spot instance requests ..."
SPOT_REQUEST_ID=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${EC2_REGION}" \
    --query 'Reservations[0].Instances[0].SpotInstanceRequestId' \
    --output text 2>/dev/null || echo "None")

if [ -n "${SPOT_REQUEST_ID}" ] && [ "${SPOT_REQUEST_ID}" != "None" ]; then
    aws ec2 cancel-spot-instance-requests \
        --spot-instance-request-ids "${SPOT_REQUEST_ID}" \
        --region "${EC2_REGION}" 2>/dev/null || true
    echo "  Cancelled spot request: ${SPOT_REQUEST_ID}"
fi

# Clean up
rm -f "${INSTANCE_FILE}"

echo ""
echo "Instance terminated and .instance_id cleaned up."
echo "Checkpoints are available at: s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/"
