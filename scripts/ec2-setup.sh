#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

echo "=== Setting Up EC2 Training Environment ==="
echo ""

# Install system dependencies
echo "[1/5] Installing system dependencies ..."
sudo apt-get update -qq
sudo apt-get install -y -qq python3-pip sox libsox-fmt-all git-lfs
git lfs install

echo ""
echo "[2/5] Installing piper-train from source ..."

# piper_train requires pytorch-lightning~=1.7.0 which has invalid metadata
# that newer pip rejects. Pin pip to a compatible version first.
pip3 install "pip<24.1"

# Install PyTorch with CUDA support (latest stable with cu118)
pip3 install torch torchaudio --index-url https://download.pytorch.org/whl/cu118

# Pin numpy<2 and torchmetrics<0.12 for compatibility with piper-train
pip3 install "numpy<2" "torchmetrics<0.12"

# piper_train is not a standalone pip package -- must install from source
PIPER_SRC_DIR="${EC2_WORK_DIR}/piper"
if [ ! -d "${PIPER_SRC_DIR}" ]; then
    git clone https://github.com/rhasspy/piper.git "${PIPER_SRC_DIR}"
fi
cd "${PIPER_SRC_DIR}/src/python"
pip3 install --no-deps -e .

# Build the monotonic_align C extension
cd "${PIPER_SRC_DIR}/src/python/piper_train/vits/monotonic_align"
python3 setup.py build_ext --inplace
# Fix the output path (build puts .so in wrong directory)
mkdir -p monotonic_align
cp piper_train/vits/monotonic_align/core*.so monotonic_align/ 2>/dev/null || true

# Patch piper-train for PyTorch 2.x LR scheduler compatibility
LIGHTNING_FILE="${PIPER_SRC_DIR}/src/python/piper_train/vits/lightning.py"
if ! grep -q "lr_scheduler_step" "${LIGHTNING_FILE}"; then
    sed -i 's/    @staticmethod\n    def add_model_specific_args/    def lr_scheduler_step(self, scheduler, *args, **kwargs):\n        scheduler.step()\n\n    @staticmethod\n    def add_model_specific_args/' "${LIGHTNING_FILE}" 2>/dev/null || \
    python3 -c "
f = '${LIGHTNING_FILE}'
c = open(f).read()
c = c.replace(
    '    @staticmethod\n    def add_model_specific_args',
    '    def lr_scheduler_step(self, scheduler, *args, **kwargs):\n        scheduler.step()\n\n    @staticmethod\n    def add_model_specific_args'
)
open(f,'w').write(c)
print('Patched lightning.py for PyTorch 2.x')
"
fi

cd ~

# Additional dependencies
pip3 install openpyxl

echo ""
echo "[3/5] Creating working directories ..."
mkdir -p "${EC2_WORK_DIR}"
mkdir -p "${EC2_DATA_DIR}"
mkdir -p "${EC2_OUTPUT_DIR}"
mkdir -p "${EC2_CHECKPOINT_DIR}"

echo ""
echo "[4/5] Downloading training data from S3 ..."
aws s3 sync "s3://${S3_BUCKET}/${S3_DATA_PREFIX}/" "${EC2_DATA_DIR}/" --region "${S3_REGION}"

WAV_COUNT=$(find "${EC2_DATA_DIR}/wav" -name "*.wav" 2>/dev/null | wc -l)
echo "  Downloaded ${WAV_COUNT} wav files"

if [ -f "${EC2_DATA_DIR}/metadata.csv" ]; then
    META_COUNT=$(wc -l < "${EC2_DATA_DIR}/metadata.csv")
    echo "  metadata.csv has ${META_COUNT} entries"
else
    echo "  WARNING: metadata.csv not found in downloaded data"
fi

echo ""
echo "[5/5] Downloading Hindi base checkpoint from HuggingFace ..."
CKPT_DOWNLOAD_DIR="${EC2_CHECKPOINT_DIR}/hindi-base"
mkdir -p "${CKPT_DOWNLOAD_DIR}"

# Clone just the needed subdirectory using git sparse checkout
cd "${EC2_CHECKPOINT_DIR}"
if [ ! -d "piper-checkpoints" ]; then
    git clone --no-checkout --filter=blob:none \
        "https://huggingface.co/datasets/${BASE_CHECKPOINT_REPO}" \
        piper-checkpoints
    cd piper-checkpoints
    git sparse-checkout init --cone
    git sparse-checkout set "${BASE_CHECKPOINT_PATH}"
    git checkout main
else
    echo "  Checkpoint repo already cloned, pulling latest ..."
    cd piper-checkpoints
    git pull
fi

# Copy checkpoint files to a clean directory
CKPT_SRC="${EC2_CHECKPOINT_DIR}/piper-checkpoints/${BASE_CHECKPOINT_PATH}"
if [ -d "${CKPT_SRC}" ]; then
    cp -r "${CKPT_SRC}"/* "${CKPT_DOWNLOAD_DIR}/"
    echo "  Hindi checkpoint files:"
    ls -lh "${CKPT_DOWNLOAD_DIR}/"
else
    echo "  WARNING: Expected checkpoint path not found: ${CKPT_SRC}"
    echo "  Available paths:"
    find "${EC2_CHECKPOINT_DIR}/piper-checkpoints" -name "*.ckpt" 2>/dev/null | head -5
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Summary:"
echo "  Work dir:        ${EC2_WORK_DIR}"
echo "  Training data:   ${EC2_DATA_DIR} (${WAV_COUNT} wav files)"
echo "  Output dir:      ${EC2_OUTPUT_DIR}"
echo "  Hindi checkpoint: ${CKPT_DOWNLOAD_DIR}"
echo ""
echo "Next: run scripts/train.sh to start training"
