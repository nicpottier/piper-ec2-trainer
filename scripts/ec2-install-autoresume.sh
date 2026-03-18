#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

SERVICE_NAME="${PROJECT_NAME}-resume.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(eval echo "~${SERVICE_USER}")"
LOG_PATH="${SERVICE_HOME}/training-service.log"

echo "=== Installing Auto-Resume Service ==="
echo "  Service: ${SERVICE_NAME}"
echo "  User:    ${SERVICE_USER}"
echo "  Home:    ${SERVICE_HOME}"
echo ""

sudo tee "${SERVICE_PATH}" >/dev/null <<EOF
[Unit]
Description=${LANG_NAME} TTS auto-resume training
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${SERVICE_HOME}
Environment=HOME=${SERVICE_HOME}
ExecStart=/bin/bash -lc 'cd ${SERVICE_HOME} && ${SERVICE_HOME}/scripts/train.sh --resume'
Restart=on-failure
RestartSec=30
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"

echo "Service installed. Use these commands on the instance to inspect it:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo "  sudo journalctl -u ${SERVICE_NAME} -f"
