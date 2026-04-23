#!/bin/bash
set -euo pipefail

# ─── Check prerequisites for sandbox-pal-action ───────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REQUIRED_TOOLS=("gh" "claude" "git" "jq" "curl")
MISSING=()
WARNINGS=()

echo "Checking prerequisites for sandbox-pal-action..."
echo ""

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        version=$("$tool" --version 2>&1 | head -1)
        echo -e "  ${GREEN}✓${NC} $tool found: $version"
    else
        echo -e "  ${RED}✗${NC} $tool not found"
        MISSING+=("$tool")
    fi
done

echo ""

# Check gh authentication
if command -v gh &> /dev/null; then
    if gh auth status &> /dev/null; then
        local_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
        echo -e "  ${GREEN}✓${NC} gh authenticated as: $local_user"
    else
        echo -e "  ${YELLOW}!${NC} gh CLI not authenticated. Run: gh auth login"
        WARNINGS+=("gh not authenticated")
    fi
fi

# Check if config.env exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "  ${GREEN}✓${NC} config.env found"
    # Check if AGENT_BOT_USER is set
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    if [ -n "${AGENT_BOT_USER:-}" ]; then
        echo -e "  ${GREEN}✓${NC} AGENT_BOT_USER set to: $AGENT_BOT_USER"
    else
        echo -e "  ${YELLOW}!${NC} AGENT_BOT_USER is empty in config.env"
        WARNINGS+=("AGENT_BOT_USER not set")
    fi
else
    echo -e "  ${YELLOW}!${NC} config.env not found. Copy config.env.example to config.env and fill in values."
    WARNINGS+=("config.env missing")
fi

echo ""

if [ ${#MISSING[@]} -ne 0 ]; then
    echo -e "${RED}Missing required tools: ${MISSING[*]}${NC}"
    echo "Please install them before continuing."
    exit 1
fi

if [ ${#WARNINGS[@]} -ne 0 ]; then
    echo -e "${YELLOW}Warnings: ${WARNINGS[*]}${NC}"
    echo "These should be resolved before running the agent."
    exit 0
fi

echo -e "${GREEN}All prerequisites met.${NC}"
