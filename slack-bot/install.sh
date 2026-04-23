#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="sandbox-pal-dispatch-slack"

echo "=== Sandbox Pal Dispatch Slack Bot Install ==="

# Determine config.env path (same logic as sandbox-pal-dispatch.sh)
# Accepts --config <path> for non-interactive use, falls back to interactive prompt
DEFAULT_CONFIG="${AGENT_CONFIG:-${HOME}/agent-infra/config.env}"
CONFIG_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_PATH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
if [ -z "$CONFIG_PATH" ]; then
    read -r -p "Path to config.env [${DEFAULT_CONFIG}]: " CONFIG_PATH
    CONFIG_PATH="${CONFIG_PATH:-$DEFAULT_CONFIG}"
fi

if [ ! -f "$CONFIG_PATH" ]; then
    echo "Warning: ${CONFIG_PATH} not found. Create it before starting the bot."
fi

# Create venv if it doesn't exist or is broken
if [ -d "${SCRIPT_DIR}/.venv" ] && [ ! -f "${SCRIPT_DIR}/.venv/bin/pip" ]; then
    echo "Removing broken virtual environment..."
    rm -rf "${SCRIPT_DIR}/.venv"
fi
if [ ! -d "${SCRIPT_DIR}/.venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv "${SCRIPT_DIR}/.venv"
fi

echo "Installing dependencies..."
"${SCRIPT_DIR}/.venv/bin/pip" install -q -r "${SCRIPT_DIR}/requirements.txt"

# Install systemd service
echo "Installing systemd service..."
SERVICE_FILE="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
mkdir -p "$(dirname "$SERVICE_FILE")"

sed "s|WORKING_DIR|${SCRIPT_DIR}|g; s|CONFIG_PATH|${CONFIG_PATH}|g" \
    "${SCRIPT_DIR}/sandbox-pal-dispatch-slack.service" > "$SERVICE_FILE"

systemctl --user daemon-reload
systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
systemctl --user enable "$SERVICE_NAME"

echo ""
echo "Install complete. To start the bot:"
echo "  systemctl --user start ${SERVICE_NAME}"
echo ""
echo "To check status:"
echo "  systemctl --user status ${SERVICE_NAME}"
echo "  journalctl --user -u ${SERVICE_NAME} -f"
echo ""
echo "Make sure these are set in your config.env (${CONFIG_PATH}):"
echo "  AGENT_SLACK_BOT_TOKEN       (xoxb-... Bot User OAuth Token)"
echo "  AGENT_SLACK_APP_TOKEN       (xapp-... App-Level Token for Socket Mode)"
echo "  AGENT_SLACK_CHANNEL_ID      (Channel ID for notifications)"
echo "  AGENT_SLACK_ALLOWED_USERS   (Comma-separated Slack user IDs)"
echo "  AGENT_DISPATCH_REPO         (owner/repo format)"
echo ""
echo "For the bot to start at boot (without requiring login):"
echo "  sudo loginctl enable-linger $(whoami)"
