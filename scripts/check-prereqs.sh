#!/bin/bash
set -euo pipefail

# ─── Check prerequisites for sandbox-pal-action ───────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REQUIRED_TOOLS=("gh" "claude" "git" "jq" "curl" "python3")
MISSING=()
WARNINGS=()

echo "Checking prerequisites for sandbox-pal-action..."
echo ""

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        version=$("$tool" --version 2>&1 | sed -n 1p)
        echo -e "  ${GREEN}✓${NC} $tool found: $version"
    else
        echo -e "  ${RED}✗${NC} $tool not found"
        MISSING+=("$tool")
    fi
done

echo ""

if ! python3 "$(dirname "${BASH_SOURCE[0]}")/lib/agent-result.py" check-dependency >/dev/null 2>&1; then
    echo "Missing worker validator: python3 -m pip install -r scripts/requirements-worker.txt"
    MISSING+=("jsonschema")
fi

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

# Sandbox profile (optional): what AGENT_SANDBOX="strict" needs.
SRT_BIN="${AGENT_SANDBOX_SRT:-srt}"
SANDBOX_MISSING=()
for tool in "$SRT_BIN" bwrap socat rg; do
    command -v "$tool" &> /dev/null || SANDBOX_MISSING+=("${tool##*/}")
done
if [ ${#SANDBOX_MISSING[@]} -ne 0 ]; then
    echo -e "  ${YELLOW}-${NC} sandbox profile (optional) unavailable, missing: ${SANDBOX_MISSING[*]}"
    echo "      Needed only for AGENT_SANDBOX=\"strict\". See docs/sandbox.md."
elif sandbox_error=$("$SRT_BIN" -s <(echo '{"network":{"allowedDomains":[],"deniedDomains":[]},"filesystem":{"denyRead":[],"allowWrite":[],"denyWrite":[]}}') -- true 2>&1); then
    echo -e "  ${GREEN}✓${NC} sandbox profile available: $("$SRT_BIN" --version 2>&1 | sed -n 1p)"
else
    echo -e "  ${YELLOW}!${NC} sandbox runtime is installed but cannot start: $(sed -n 1p <<< "$sandbox_error")"
    if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
        echo "      This kernel restricts unprivileged user namespaces through AppArmor."
        echo "      bubblewrap needs an AppArmor profile that allows them: see docs/sandbox.md."
    fi
    WARNINGS+=("sandbox runtime cannot start")
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
