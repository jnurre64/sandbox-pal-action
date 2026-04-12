#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="agent-dispatch-bot"

echo "=== Agent Dispatch Bot Install ==="

# Determine config.env path (same logic as agent-dispatch.sh)
DEFAULT_CONFIG="${AGENT_CONFIG:-${HOME}/agent-infra/config.env}"
read -r -p "Path to config.env [${DEFAULT_CONFIG}]: " CONFIG_PATH
CONFIG_PATH="${CONFIG_PATH:-$DEFAULT_CONFIG}"

if [ ! -f "$CONFIG_PATH" ]; then
    echo "Warning: ${CONFIG_PATH} not found. Create it before starting the bot."
fi

# Create venv if it doesn't exist or is broken (e.g., previous failed install)
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

# Generate service file from template, replacing placeholders with actual paths
sed "s|WORKING_DIR|${SCRIPT_DIR}|g; s|CONFIG_PATH|${CONFIG_PATH}|g" \
    "${SCRIPT_DIR}/agent-dispatch-bot.service" > "$SERVICE_FILE"

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
echo "  AGENT_DISCORD_BOT_TOKEN"
echo "  AGENT_DISCORD_CHANNEL_ID"
echo "  AGENT_DISCORD_GUILD_ID"
echo "  AGENT_DISCORD_ALLOWED_USERS or AGENT_DISCORD_ALLOWED_ROLE"
echo "  AGENT_DISPATCH_REPO (owner/repo format)"
echo "  AGENT_NOTIFY_BACKEND=\"bot\""
echo ""
echo "For the bot to start at boot (without requiring login):"
echo "  sudo loginctl enable-linger \$(whoami)"
echo ""
echo "Note: After enabling linger, 'sudo systemctl --user ...' won't work."
echo "Use 'ssh <user>@localhost' or export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
