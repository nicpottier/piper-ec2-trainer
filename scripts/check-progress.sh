#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/../config.env"

INSTANCE_FILE="$PROJECT_DIR/.instance_id"

# --- Instance lookup ---
if [ ! -f "${INSTANCE_FILE}" ]; then
    echo "ERROR: .instance_id file not found."
    exit 1
fi

INSTANCE_ID=$(cat "${INSTANCE_FILE}")

INFO=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${EC2_REGION}" \
    --query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,LaunchTime:LaunchTime,Lifecycle:InstanceLifecycle,Type:InstanceType,AZ:Placement.AvailabilityZone}' \
    --output json 2>/dev/null)

STATE=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['State'])")
PUBLIC_IP=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['PublicIp'] or 'None')")
LIFECYCLE=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Lifecycle') or 'on-demand')")
INST_TYPE=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['Type'])")
AZ=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['AZ'])")

SERVICE_NAME="${PROJECT_NAME}-resume.service"

echo "=== ${LANG_NAME} TTS Training Progress ==="
echo ""
echo "Instance:  ${INSTANCE_ID} (${INST_TYPE}, ${LIFECYCLE})"
echo "Region:    ${AZ}"
echo "State:     ${STATE}"

if [ "${STATE}" != "running" ]; then
    echo ""
    echo "Instance is not running. No training data available."
    exit 0
fi

echo "Public IP: ${PUBLIC_IP}"
echo ""

# --- Find SSH key ---
SSH_KEY=""
for candidate in ~/.ssh/${EC2_KEY_NAME}-usw2.pem ~/.ssh/${EC2_KEY_NAME}.pem; do
    if [ -f "$candidate" ]; then
        SSH_KEY="$candidate"
        break
    fi
done

if [ -z "$SSH_KEY" ]; then
    echo "ERROR: No SSH key found matching ${EC2_KEY_NAME}"
    exit 1
fi

SSH_CMD="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${PUBLIC_IP}"

# --- Gather remote data in a single SSH call ---
REMOTE_DATA=$(${SSH_CMD} bash -s <<'REMOTE_SCRIPT'
# Latest checkpoint
LATEST_CKPT=$(find /home/ubuntu/training/output/training/lightning_logs/ -name "*.ckpt" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [ -n "$LATEST_CKPT" ]; then
    CKPT_BASENAME=$(basename "$LATEST_CKPT")
    CKPT_MTIME=$(stat -c '%Y' "$LATEST_CKPT" 2>/dev/null || echo "0")
    # Extract epoch number
    EPOCH=$(echo "$CKPT_BASENAME" | grep -oP 'epoch=\K[0-9]+')
else
    CKPT_BASENAME="none"
    CKPT_MTIME="0"
    EPOCH="0"
fi

# GPU info
GPU_LINE=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "0, 0, 0, 0")

# Service status
SVC_STATUS=$(sudo systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo "unknown")

# Boot count from journalctl (count "Boot" markers)
BOOT_COUNT=$(sudo journalctl -u ${SERVICE_NAME} --no-pager 2>/dev/null | grep -c "^-- Boot" || echo "0")

# Latest service start time
SVC_START=$(sudo systemctl show ${SERVICE_NAME} --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")

# Count all checkpoints
CKPT_COUNT=$(find /home/ubuntu/training/output/training/lightning_logs/ -name "*.ckpt" 2>/dev/null | wc -l)

# Second-latest checkpoint for rate calculation
SECOND_CKPT_LINE=$(find /home/ubuntu/training/output/training/lightning_logs/ -name "*.ckpt" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -2 | head -1)
if [ -n "$SECOND_CKPT_LINE" ]; then
    SECOND_CKPT_PATH=$(echo "$SECOND_CKPT_LINE" | cut -d' ' -f2-)
    SECOND_CKPT_MTIME=$(stat -c '%Y' "$SECOND_CKPT_PATH" 2>/dev/null || echo "0")
    SECOND_EPOCH=$(basename "$SECOND_CKPT_PATH" | grep -oP 'epoch=\K[0-9]+' || echo "0")
else
    SECOND_CKPT_MTIME="0"
    SECOND_EPOCH="0"
fi

NOW=$(date +%s)

echo "${EPOCH}|${CKPT_MTIME}|${GPU_LINE}|${SVC_STATUS}|${BOOT_COUNT}|${SVC_START}|${CKPT_COUNT}|${SECOND_EPOCH}|${SECOND_CKPT_MTIME}|${NOW}|${CKPT_BASENAME}"
REMOTE_SCRIPT
) || { echo "ERROR: Could not connect to instance via SSH."; exit 1; }

# --- Parse remote data ---
IFS='|' read -r EPOCH CKPT_MTIME GPU_LINE SVC_STATUS BOOT_COUNT SVC_START CKPT_COUNT SECOND_EPOCH SECOND_CKPT_MTIME NOW CKPT_BASENAME <<< "$REMOTE_DATA"

# Trim whitespace
GPU_UTIL=$(echo "$GPU_LINE" | cut -d',' -f1 | xargs)
GPU_MEM_USED=$(echo "$GPU_LINE" | cut -d',' -f2 | xargs)
GPU_MEM_TOTAL=$(echo "$GPU_LINE" | cut -d',' -f3 | xargs)
GPU_TEMP=$(echo "$GPU_LINE" | cut -d',' -f4 | xargs)

MAX_EPOCHS=${PIPER_MAX_EPOCHS}

# --- Display ---
echo "--- Training ---"
echo "Target:          ${MAX_EPOCHS} epochs"
echo "Latest ckpt:     ${CKPT_BASENAME}"

if [ "$EPOCH" -gt 0 ] 2>/dev/null; then
    PCT=$(python3 -c "print(f'{${EPOCH}/${MAX_EPOCHS}*100:.1f}')")
    REMAINING=$((MAX_EPOCHS - EPOCH))
    echo "Progress:        ${EPOCH} / ${MAX_EPOCHS} epochs (${PCT}%)"
    echo "Remaining:       ${REMAINING} epochs"
else
    echo "Progress:        No checkpoints found"
fi

echo ""
echo "--- GPU ---"
echo "Utilization:     ${GPU_UTIL}%"
echo "Memory:          ${GPU_MEM_USED} MiB / ${GPU_MEM_TOTAL} MiB"
echo "Temperature:     ${GPU_TEMP}°C"

echo ""
echo "--- Service ---"
echo "Status:          ${SVC_STATUS}"
echo "Started:         ${SVC_START}"
echo "Spot recoveries: ${BOOT_COUNT}"
echo "Checkpoints:     ${CKPT_COUNT} saved"

# --- Rate & ETA calculation ---
echo ""
echo "--- Estimates ---"

# Calculate rate from two most recent checkpoints
if [ "$SECOND_EPOCH" -gt 0 ] 2>/dev/null && [ "$EPOCH" != "$SECOND_EPOCH" ] && [ "$CKPT_MTIME" != "$SECOND_CKPT_MTIME" ]; then
    EPOCH_DIFF=$((EPOCH - SECOND_EPOCH))
    TIME_DIFF=$((CKPT_MTIME - SECOND_CKPT_MTIME))
    if [ "$TIME_DIFF" -gt 0 ] && [ "$EPOCH_DIFF" -gt 0 ]; then
        RATE_INFO=$(python3 -c "
epoch_diff = ${EPOCH_DIFF}
time_diff = ${TIME_DIFF}
remaining = ${REMAINING}
now = ${NOW}
ckpt_mtime = ${CKPT_MTIME}
spot_price = ${EC2_SPOT_MAX_PRICE}

epochs_per_hr = epoch_diff / (time_diff / 3600)
mins_per_epoch = (time_diff / 60) / epoch_diff

# Estimate current epoch (time since last checkpoint)
elapsed_since_ckpt = now - ckpt_mtime
est_extra_epochs = int(elapsed_since_ckpt / (time_diff / epoch_diff))
est_current = ${EPOCH} + est_extra_epochs
est_remaining = max(0, ${MAX_EPOCHS} - est_current)

hrs_remaining = est_remaining / epochs_per_hr
cost_remaining = hrs_remaining * 0.44  # approx spot price

import datetime
eta = datetime.datetime.now(datetime.UTC) + datetime.timedelta(hours=hrs_remaining)
eta_str = eta.strftime('%a %b %d, %H:%M UTC')

print(f'{epochs_per_hr:.1f}|{mins_per_epoch:.1f}|{est_current}|{est_remaining}|{hrs_remaining:.1f}|{cost_remaining:.0f}|{eta_str}')
")
        IFS='|' read -r EPH MPE EST_CUR EST_REM HRS_REM COST_REM ETA_STR <<< "$RATE_INFO"
        # Warn if the two checkpoints span spot interruptions (time gap >> expected)
        EXPECTED_SECS=$(python3 -c "print(int(${EPOCH_DIFF} * 2.2 * 60))")
        if [ "$TIME_DIFF" -gt $((EXPECTED_SECS * 3 / 2)) ]; then
            echo "Rate:            ~${EPH} epochs/hr (~${MPE} min/epoch) -- includes downtime between checkpoints"
        else
            echo "Rate:            ~${EPH} epochs/hr (~${MPE} min/epoch)"
        fi
        echo "Est. current:    ~epoch ${EST_CUR} (based on time since last checkpoint)"
        echo "Est. remaining:  ~${EST_REM} epochs (~${HRS_REM} hours)"
        echo "Est. completion: ${ETA_STR}"
        echo "Est. spot cost:  ~\$${COST_REM} remaining (at \$0.44/hr)"
    else
        echo "Rate:            (waiting for more checkpoints to calculate)"
    fi
else
    echo "Rate:            (need at least 2 checkpoints to calculate)"
fi

echo ""
