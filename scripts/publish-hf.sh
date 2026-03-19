#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/../config.env"
export ONNX_NAME VOICE_NAME LANG_NAME LANG_LOCALE PIPER_LANGUAGE PIPER_QUALITY PIPER_SAMPLE_RATE
export BASE_CHECKPOINT_NAME BASE_CHECKPOINT_LANG BASE_CHECKPOINT_PATH
export S3_BUCKET S3_CHECKPOINT_PREFIX
export SCRIPT_DIR PROJECT_DIR

# Use the project's Python if available
PYTHON="${PROJECT_DIR}/env/bin/python"
if [ ! -x "${PYTHON}" ]; then
    PYTHON="python3"
fi

echo "=== Publish Piper TTS Model to Hugging Face ==="
echo ""

# --- Step 1: Check for model files ---
MODEL_DIR="${PROJECT_DIR}/model"
ONNX_FILE="${MODEL_DIR}/${ONNX_NAME}.onnx"
CONFIG_FILE="${MODEL_DIR}/${ONNX_NAME}.onnx.json"

if [ ! -f "${ONNX_FILE}" ]; then
    echo "ERROR: Model file not found: ${ONNX_FILE}"
    echo ""
    echo "Either export locally with scripts/export.sh, or download from S3:"
    echo "  mkdir -p model"
    echo "  aws s3 cp s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/${ONNX_NAME}.onnx model/"
    echo "  aws s3 cp s3://${S3_BUCKET}/${S3_CHECKPOINT_PREFIX}/exported/${ONNX_NAME}.onnx.json model/"
    exit 1
fi

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi

echo "Model files found:"
echo "  ${ONNX_FILE} ($(du -h "${ONNX_FILE}" | cut -f1 | xargs))"
echo "  ${CONFIG_FILE}"

# Collect sample wav files
SAMPLE_WAVS=""
for wav in "${MODEL_DIR}"/test_*.wav; do
    [ -f "$wav" ] && SAMPLE_WAVS="${SAMPLE_WAVS}${wav}|"
done
if [ -n "${SAMPLE_WAVS}" ]; then
    COUNT=$(echo "${SAMPLE_WAVS}" | tr '|' '\n' | grep -c .)
    echo "  ${COUNT} sample wav file(s)"
fi
echo ""

# --- Step 2: Check huggingface_hub is installed ---
if ! "${PYTHON}" -c "import huggingface_hub" 2>/dev/null; then
    echo "Installing huggingface_hub ..."
    "${PYTHON}" -m pip install -q huggingface_hub
    echo ""
fi

# --- Step 3-8: Run the publish logic in Python ---
# Write to temp file so stdin stays connected to the terminal for interactive prompts
PUBLISH_PY=$(mktemp /tmp/publish-hf-XXXXXX)
mv "${PUBLISH_PY}" "${PUBLISH_PY}.py"
PUBLISH_PY="${PUBLISH_PY}.py"
trap "rm -f '${PUBLISH_PY}'" EXIT
cat > "${PUBLISH_PY}" <<'PYEOF'
import os
import sys
import shutil
import tempfile
from pathlib import Path

from huggingface_hub import HfApi, login

# Read config from environment (sourced by the shell wrapper)
ONNX_NAME = os.environ.get("ONNX_NAME", "")
LANG_NAME = os.environ.get("LANG_NAME", "")
LANG_LOCALE = os.environ.get("LANG_LOCALE", "")
PIPER_LANGUAGE = os.environ.get("PIPER_LANGUAGE", "")
PIPER_QUALITY = os.environ.get("PIPER_QUALITY", "")
PIPER_SAMPLE_RATE = os.environ.get("PIPER_SAMPLE_RATE", "22050")
BASE_CHECKPOINT_NAME = os.environ.get("BASE_CHECKPOINT_NAME", "")
BASE_CHECKPOINT_LANG = os.environ.get("BASE_CHECKPOINT_LANG", "")
BASE_CHECKPOINT_PATH = os.environ.get("BASE_CHECKPOINT_PATH", "")

SCRIPT_DIR = Path(__file__).resolve().parent if "__file__" in dir() else Path(os.environ.get("SCRIPT_DIR", "."))
PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", SCRIPT_DIR / "..")).resolve()
MODEL_DIR = PROJECT_DIR / "model"

ONNX_FILE = MODEL_DIR / f"{ONNX_NAME}.onnx"
CONFIG_FILE = MODEL_DIR / f"{ONNX_NAME}.onnx.json"

# Collect sample wavs
sample_wavs = sorted(MODEL_DIR.glob("test_*.wav"))

# --- Check authentication ---
api = HfApi()
try:
    user_info = api.whoami()
    hf_user = user_info["name"]
except Exception:
    print("Not logged in to Hugging Face.")
    print("You need an access token from: https://huggingface.co/settings/tokens")
    print()
    token = input("Paste your HF token (or press Enter to open browser login): ").strip()
    if token:
        login(token=token)
    else:
        login()
    user_info = api.whoami()
    hf_user = user_info["name"]

print(f"Logged in as: {hf_user}")
print()

# --- Choose repo name ---
VOICE_NAME = os.environ.get("VOICE_NAME", "")
default_repo = f"{hf_user}/piper-{LANG_LOCALE}-{VOICE_NAME}-{PIPER_QUALITY}"
repo_input = input(f"Hugging Face repo [{default_repo}]: ").strip()
hf_repo = repo_input if repo_input else default_repo
print()

# --- Create repo ---
print(f"Creating repo: {hf_repo} ...")
api.create_repo(hf_repo, repo_type="model", exist_ok=True)
print()

# --- Prepare upload directory ---
upload_dir = Path(tempfile.mkdtemp())
try:
    shutil.copy2(ONNX_FILE, upload_dir / ONNX_FILE.name)
    shutil.copy2(CONFIG_FILE, upload_dir / CONFIG_FILE.name)

    # Copy sample wavs
    if sample_wavs:
        samples_dir = upload_dir / "samples"
        samples_dir.mkdir()
        for wav in sample_wavs:
            shutil.copy2(wav, samples_dir / wav.name)

    # --- Generate model card ---
    # Build audio samples section for the markdown body
    audio_samples = ""
    if sample_wavs:
        audio_samples = "\n## Samples\n\n"
        for wav in sample_wavs:
            stem = wav.stem.removeprefix("test_")
            title = stem.replace("_", " ").title()
            audio_samples += f'**{title}**\n\n'
            audio_samples += f'<audio controls><source src="https://huggingface.co/{hf_repo}/resolve/main/samples/{wav.name}" type="audio/wav"></audio>\n\n'

    model_card = f"""---
language:
  - {PIPER_LANGUAGE}
license: mit
pipeline_tag: text-to-speech
tags:
  - piper
  - tts
  - onnx
  - {LANG_NAME.lower()}
base_model:
  - rhasspy/piper-voices
library_name: onnx
---

# Piper TTS -- {LANG_NAME} ({LANG_LOCALE}) {PIPER_QUALITY}

A [Piper](https://github.com/rhasspy/piper) text-to-speech voice for {LANG_NAME}, exported as ONNX.
{audio_samples}
## Model Details

| | |
|---|---|
| **Language** | {LANG_NAME} ({LANG_LOCALE}) |
| **Quality** | {PIPER_QUALITY} |
| **Base model** | Fine-tuned from {BASE_CHECKPOINT_NAME} (`{BASE_CHECKPOINT_LANG}`) via [rhasspy/piper-checkpoints](https://huggingface.co/datasets/rhasspy/piper-checkpoints) |
| **Sample rate** | {PIPER_SAMPLE_RATE} Hz |
| **Format** | ONNX |

## Usage

### With Piper CLI

```bash
pip install piper-tts
echo 'your text here' | piper --model {ONNX_NAME}.onnx --output_file output.wav
```

### With NVDA

Download both files and place them in NVDA's Piper voices directory:
- `{ONNX_NAME}.onnx`
- `{ONNX_NAME}.onnx.json`

### Programmatic (Python)

```python
import subprocess
text = "your text here"
subprocess.run(
    ["piper", "--model", "{ONNX_NAME}.onnx", "--output_file", "output.wav"],
    input=text.encode(),
)
```

## Files

| File | Description |
|------|-------------|
| `{ONNX_NAME}.onnx` | ONNX model |
| `{ONNX_NAME}.onnx.json` | Piper config (phoneme map, sample rate, etc.) |
| `samples/` | Audio samples generated by this model |

## Training

Trained using the [Piper TTS Training Pipeline](https://github.com/nicpottier/piper-tts-training). Fine-tuned from the {BASE_CHECKPOINT_NAME} (`{BASE_CHECKPOINT_PATH}`) checkpoint.
"""

    (upload_dir / "README.md").write_text(model_card)
    print("Generated model card.")

    # --- Upload ---
    print()
    print(f"Uploading to {hf_repo} ...")
    print()
    api.upload_folder(
        folder_path=str(upload_dir),
        repo_id=hf_repo,
        commit_message=f"Upload {LANG_NAME} Piper TTS model ({PIPER_QUALITY})",
    )

    print()
    print("=== Published ===")
    print()
    print(f"  https://huggingface.co/{hf_repo}")
    print()

finally:
    shutil.rmtree(upload_dir, ignore_errors=True)
PYEOF
exec "${PYTHON}" "${PUBLISH_PY}"
