# Sinhala Piper TTS Training

## Overview

This project trains a Sinhala (si_LK) text-to-speech model using [Piper TTS](https://github.com/rhasspy/piper), an open-source neural TTS system. The model is fine-tuned from a Hindi (hi_IN) checkpoint -- Hindi being the closest available Indo-Aryan language with a pre-trained Piper model.

The training corpus contains 4,774 Sinhala utterances recorded at 44.1kHz. Training runs on an AWS EC2 g5.xlarge spot instance with an NVIDIA A10G GPU.

## Prerequisites

- **Python 3.10+** with pip
- **sox** -- audio processing (`brew install sox` on macOS, `apt install sox` on Linux)
- **openpyxl** -- Excel reading (`pip install openpyxl`)
- **AWS CLI** -- configured with credentials that have EC2 and S3 permissions
- **Training data** -- symlinked at `SinhalaTTSData/` containing `TextData.xlsx` and `wavs/`

## Quick Start

```bash
# 1. Prepare training data (resample + create metadata)
python3 scripts/prepare-data.py

# 2. Upload to S3
./scripts/setup-s3.sh

# 3. Launch EC2 spot instance
./scripts/ec2-launch.sh

# 4. SSH to instance, copy files, set up environment
scp -i ~/.ssh/sinhala-tts-key.pem -r config.env scripts/ ubuntu@<IP>:~/
ssh -i ~/.ssh/sinhala-tts-key.pem ubuntu@<IP>
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
| `config.env` | Central configuration (S3, EC2, training params) |
| `scripts/prepare-data.py` | Resample audio + create metadata.csv from Excel |
| `scripts/setup-s3.sh` | Create S3 bucket and upload prepared data |
| `scripts/ec2-launch.sh` | Launch a GPU spot instance |
| `scripts/ec2-setup.sh` | Set up the training environment on EC2 |
| `scripts/train.sh` | Preprocess and run Piper training |
| `scripts/export.sh` | Export best checkpoint to ONNX |
| `scripts/ec2-stop.sh` | Terminate instance and clean up |
| `scripts/sync-checkpoints.sh` | Push/pull checkpoints to/from S3 |

## Configuration

All settings live in `config.env`. Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `S3_BUCKET` | sinhala-tts-piper | S3 bucket for data and checkpoints |
| `EC2_INSTANCE_TYPE` | g5.xlarge | GPU instance (NVIDIA A10G, 24GB VRAM) |
| `EC2_SPOT_MAX_PRICE` | 0.50 | Max hourly price for spot instance |
| `PIPER_BATCH_SIZE` | 32 | Training batch size |
| `PIPER_MAX_EPOCHS` | 3000 | Maximum training epochs |
| `PIPER_CHECKPOINT_EPOCHS` | 100 | Save checkpoint every N epochs |
| `PIPER_QUALITY` | medium | Model quality (low/medium/high) |

Override any value by editing `config.env` before running scripts.

## Step-by-Step Guide

### 1. Prepare Training Data

The raw data is in `SinhalaTTSData/` with 4,774 wav files at 44.1kHz and a `TextData.xlsx` mapping filenames to Sinhala text. Piper expects 22050Hz audio and an LJSpeech-style metadata file.

```bash
pip install openpyxl   # if not already installed
python3 scripts/prepare-data.py
```

This will:
- Read `TextData.xlsx` to extract filename-to-text mappings
- Validate that every referenced wav file exists
- Resample all wav files from 44.1kHz to 22050Hz using sox (with `-v 0.95` to prevent clipping)
- Output to `prepared_data/wav/` and `prepared_data/metadata.csv`

Custom paths: `python3 scripts/prepare-data.py --input-dir /path/to/data --output-dir /path/to/output`

### 2. Upload to S3

```bash
./scripts/setup-s3.sh
```

Creates the S3 bucket (if needed) and uploads the prepared data.

### 3. Launch EC2 Instance

```bash
./scripts/ec2-launch.sh
```

This automatically finds the latest Deep Learning AMI and launches a g5.xlarge spot instance. The g5.xlarge has an NVIDIA A10G GPU with 24GB VRAM, which is sufficient for Piper medium-quality training.

The script saves the instance ID to `.instance_id` for use by other scripts.

**Important**: Make sure you have:
- An EC2 key pair named `sinhala-tts-key` (or update `EC2_KEY_NAME` in config.env)
- An IAM role with S3 access that can be attached to the instance

### 4. Set Up Training Environment

```bash
# Copy project files to the instance
scp -i ~/.ssh/sinhala-tts-key.pem -r config.env scripts/ ubuntu@<PUBLIC_IP>:~/

# SSH into the instance
ssh -i ~/.ssh/sinhala-tts-key.pem ubuntu@<PUBLIC_IP>

# Run setup
./scripts/ec2-setup.sh
```

This installs dependencies, downloads training data from S3, fetches the Hindi base checkpoint from HuggingFace (~845MB), and installs a `systemd` service that resumes training automatically after reboot or Spot recovery.

### 5. Start Training

```bash
./scripts/train.sh
```

Training proceeds in two phases:
1. **Preprocessing**: Converts metadata + wav files into the format Piper expects
2. **Training**: Fine-tunes from the Hindi checkpoint

A background process syncs checkpoints to S3 every 30 minutes for safety.

### 6. Monitor Training

Training logs are written to stdout. Key metrics to watch:
- **val_loss**: Validation loss -- should decrease over time
- **epoch**: Current epoch number
- **step**: Current training step

You can also monitor GPU usage:
```bash
nvidia-smi   # check GPU memory and utilization
```

Use tmux or screen to keep training running after disconnecting:
```bash
tmux new -s training
./scripts/train.sh
# Ctrl+B, D to detach
# tmux attach -t training to reconnect
```

Auto-resume is also installed as a boot-time service:
```bash
sudo systemctl status sinhala-tts-resume.service
sudo journalctl -u sinhala-tts-resume.service -f
```

### 7. Export Model

After training completes (or at a satisfactory checkpoint):

```bash
./scripts/export.sh
```

This exports the best checkpoint to ONNX format, copies the config file, and uploads both to S3. The exported model can be used directly with the `piper` command-line tool.

### 8. Stop Instance (Save Money!)

When you are done training, always stop the instance to avoid ongoing charges:

```bash
# Run locally (not on the EC2 instance)
./scripts/ec2-stop.sh
```

This syncs checkpoints to S3 before terminating the instance. A g5.xlarge spot instance costs approximately $0.40-0.50/hr, so leaving it running overnight wastes ~$5-6.

## Resuming Training

If the spot instance is interrupted or you want to continue training later:

```bash
# 1. Launch a new instance
./scripts/ec2-launch.sh

# 2. Set up environment + pull checkpoints from S3
./scripts/ec2-setup.sh
./scripts/sync-checkpoints.sh --pull

# 3. Resume training (skips preprocessing, loads latest checkpoint)
./scripts/train.sh --resume
```

On instances configured with `scripts/ec2-setup.sh`, the boot-time service will also run `./scripts/train.sh --resume` automatically after the instance comes back.

## Cost Estimates

| Resource | Rate | Estimated Cost |
|----------|------|----------------|
| g5.xlarge spot (us-east-1) | ~$0.40-0.50/hr | ~$48-60 for 5 days |
| EBS storage (200GB gp3) | ~$0.08/GB/mo | ~$16/mo |
| S3 storage | ~$0.023/GB/mo | < $1/mo |
| **Total for full training** | | **~$50-80** |

Spot instances can be interrupted. The checkpoint sync ensures minimal lost progress.

## Troubleshooting

**sox not found**: Install with `brew install sox` (macOS) or `apt install sox libsox-fmt-all` (Linux).

**CUDA out of memory**: Reduce `PIPER_BATCH_SIZE` in config.env (try 16 or 8).

**Spot instance terminated**: This is normal. Relaunch and resume from the latest S3 checkpoint (see "Resuming Training" above).

**No .ckpt file found**: The Hindi checkpoint download may have failed. Re-run `ec2-setup.sh` or manually check the HuggingFace repo structure.

**openpyxl import error**: `pip install openpyxl`

**Permission denied on scripts**: `chmod +x scripts/*.sh`

**S3 access denied**: Check that your AWS CLI credentials have s3:PutObject, s3:GetObject, and s3:ListBucket permissions, and that the EC2 instance has an IAM role with S3 access.
