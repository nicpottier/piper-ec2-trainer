# Piper TTS Training Pipeline

## Overview

Train a [Piper TTS](https://github.com/rhasspy/piper) text-to-speech model for any language, fine-tuned from an existing Piper checkpoint. Training runs on an AWS EC2 GPU spot instance with automatic checkpoint syncing and spot recovery.

## Prerequisites

- **Python 3.10+** with pip
- **sox** -- audio processing (`brew install sox` on macOS, `apt install sox` on Linux)
- **AWS CLI** -- configured with credentials that have EC2 and S3 permissions
- **Training data** -- directory containing `TextData.xlsx` and `wavs/`

## Quick Start

1. Copy the example config and fill in your language-specific settings:
   ```bash
   cp config.example.env config.env
   ```
   See `config.example.env` for detailed comments on each setting, or [Configuration](#configuration) below.
2. Install Python dependencies:
   ```bash
   python3 -m venv env
   source env/bin/activate
   pip install -r requirements.txt
   ```
3. Symlink or place your training data directory (set `INPUT_DATA_DIR` in config)
4. Run the pipeline:

```bash
# 1. Prepare training data (resample + create metadata)
python3 scripts/prepare-data.py --input-dir <YOUR_DATA_DIR>

# 2. Upload to S3
./scripts/setup-s3.sh

# 3. Launch EC2 spot instance
./scripts/ec2-launch.sh

# 4. SSH to instance, copy files, set up environment
scp -i ~/.ssh/<KEY_NAME>.pem -r config.env scripts/ ubuntu@<IP>:~/
ssh -i ~/.ssh/<KEY_NAME>.pem ubuntu@<IP>
./scripts/ec2-setup.sh

# 5. Start training
./scripts/train.sh

# 6. Export trained model to ONNX
./scripts/export.sh

# 7. Stop the instance when done
./scripts/ec2-stop.sh    # run locally
```

## Project Structure

| File | Description |
|------|-------------|
| `config.env` | Central configuration (project identity, S3, EC2, training params) |
| `scripts/prepare-data.py` | Resample audio + create metadata.csv from Excel |
| `scripts/setup-s3.sh` | Create S3 bucket and upload prepared data |
| `scripts/ec2-launch.sh` | Launch a GPU spot instance |
| `scripts/ec2-setup.sh` | Set up the training environment on EC2 |
| `scripts/train.sh` | Preprocess and run Piper training |
| `scripts/export.sh` | Export best checkpoint to ONNX |
| `scripts/check-progress.sh` | Monitor training progress remotely |
| `scripts/ec2-stop.sh` | Terminate instance and clean up |
| `scripts/sync-checkpoints.sh` | Push/pull checkpoints to/from S3 |
| `scripts/publish-hf.sh` | Publish model to Hugging Face |

## Configuration

All settings live in `config.env`:

### Project Identity

| Parameter | Description | Example |
|-----------|-------------|---------|
| `PROJECT_NAME` | Short slug for AWS resource naming | `tamil-tts` |
| `LANG_NAME` | Human-readable language name | `Tamil` |
| `LANG_LOCALE` | Piper locale code (used in model filename) | `ta_IN` |
| `VOICE_NAME` | Voice/speaker identifier (lowercase, used in filename) | `ashoka` |
| `INPUT_DATA_DIR` | Local path to raw training data | `TamilTTSData` |

### S3

| Parameter | Description | Example |
|-----------|-------------|---------|
| `S3_BUCKET` | S3 bucket for data and checkpoints | `tamil-tts-piper` |
| `S3_REGION` | S3 bucket region | `us-east-1` |

### EC2

| Parameter | Description | Example |
|-----------|-------------|---------|
| `EC2_INSTANCE_TYPE` | GPU instance type | `g6.xlarge` |
| `EC2_REGION` | EC2 region | `us-east-1` |
| `EC2_KEY_NAME` | SSH key pair name | `my-tts-key` |
| `EC2_SPOT_MAX_PRICE` | Max hourly spot price | `0.60` |
| `EC2_USE_SPOT` | Use spot instances (`true`/`false`) | `true` |

### Training

| Parameter | Description | Example |
|-----------|-------------|---------|
| `PIPER_LANGUAGE` | Piper language code | `ta` |
| `PIPER_QUALITY` | Model quality (`low`/`medium`/`high`) | `medium` |
| `PIPER_BATCH_SIZE` | Training batch size | `32` |
| `PIPER_MAX_EPOCHS` | Maximum training epochs | `6000` |
| `PIPER_CHECKPOINT_EPOCHS` | Save checkpoint every N epochs | `25` |
| `PIPER_SAMPLE_RATE` | Audio sample rate in Hz | `22050` |
| `PIPER_PRECISION` | Training precision (`16`/`32`) | `32` |

### Base Checkpoint

Fine-tuning from a related language's checkpoint is much faster than training from scratch. Browse available checkpoints at `https://huggingface.co/datasets/rhasspy/piper-checkpoints`. Pick the closest available language by language family (e.g. Hindi for South Asian languages, German for European languages).

| Parameter | Description | Example |
|-----------|-------------|---------|
| `BASE_CHECKPOINT_REPO` | HuggingFace dataset repo | `rhasspy/piper-checkpoints` |
| `BASE_CHECKPOINT_PATH` | Path within repo to checkpoint | `hi/hi_IN/rohan/medium` |
| `BASE_CHECKPOINT_LANG` | Base checkpoint locale | `hi_IN` |
| `BASE_CHECKPOINT_NAME` | Human-readable base language name | `Hindi` |

## Training Data Format

The pipeline expects a directory containing:
- `TextData.xlsx` -- maps filenames (column A) to text transcriptions (column B)
- `wavs/` -- the corresponding `.wav` audio files

The `prepare-data.py` script resamples audio to the target sample rate and produces an LJSpeech-format `metadata.csv` in `prepared_data/`.

## Monitoring Training

Run locally to check progress on the remote instance:

```bash
./scripts/check-progress.sh
```

This shows epoch progress, GPU stats, service status, and estimated completion time.

## Resuming Training

If the spot instance is interrupted or you want to continue later:

```bash
./scripts/ec2-launch.sh
./scripts/ec2-setup.sh
./scripts/sync-checkpoints.sh --pull
./scripts/train.sh --resume
```

On instances set up with `ec2-setup.sh`, a boot-time systemd service automatically runs `train.sh --resume` after spot recovery.

## Exported Model

After `scripts/export.sh`, the model is two files:
- `<LANG_LOCALE>-<VOICE_NAME>-<QUALITY>.onnx` -- the ONNX model
- `<LANG_LOCALE>-<VOICE_NAME>-<QUALITY>.onnx.json` -- the config

These are uploaded to S3 and can be used with the `piper` CLI or NVDA's Piper voice addon:

```bash
pip install piper-tts
echo 'text in your language' | piper --model <LANG_LOCALE>-<VOICE_NAME>-<QUALITY>.onnx --output_file test.wav
```

## Publishing to Hugging Face

To publish the exported model (with samples and a model card):

```bash
./scripts/publish-hf.sh
```

The script walks you through login, repo creation, and upload. It generates sample audio from the `SAMPLES` texts in `config.env` and creates a model card with playable audio.

## Cost Estimates

| Resource | Rate | Estimated Cost |
|----------|------|----------------|
| g6.xlarge spot | ~$0.40-0.60/hr | ~$48-72 for 5 days |
| EBS storage (200GB gp3) | ~$0.08/GB/mo | ~$16/mo |
| S3 storage | ~$0.023/GB/mo | < $1/mo |
| **Total for full training** | | **~$50-80** |

## Troubleshooting

**sox not found**: Install with `brew install sox` (macOS) or `apt install sox libsox-fmt-all` (Linux).

**CUDA out of memory**: Reduce `PIPER_BATCH_SIZE` in config.env (try 16 or 8).

**Spot instance terminated**: Normal. Relaunch and resume from the latest S3 checkpoint.

**No .ckpt file found**: The base checkpoint download may have failed. Re-run `ec2-setup.sh`.

**openpyxl import error**: `pip install openpyxl`

**Permission denied on scripts**: `chmod +x scripts/*.sh`

**S3 access denied**: Ensure AWS CLI credentials have s3:PutObject, s3:GetObject, and s3:ListBucket permissions, and the EC2 instance has an IAM role with S3 access.
