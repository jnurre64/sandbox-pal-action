#!/bin/bash
set -euo pipefail

# ─── Check prerequisites for running tests locally ─────────────
# Usage: bash scripts/check-test-prereqs.sh
# Exits 0 if all tools present, 1 if any missing.
# Reports platform and install instructions for missing tools.

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

MISSING=()

# ─── Platform detection ────────────────────────────────────────

detect_platform() {
    local uname_out
    uname_out="$(uname -s)"
    case "$uname_out" in
        Linux*)                echo "linux" ;;
        Darwin*)               echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)                     echo "unknown" ;;
    esac
}

PLATFORM="$(detect_platform)"
echo -e "Platform: ${PLATFORM}"
echo ""

# ─── Tool checks ──────────────────────────────────────────────

check_tool() {
    local tool="$1"
    if command -v "$tool" &>/dev/null; then
        local version
        version=$("$tool" --version 2>&1 | head -1)
        echo -e "  ${GREEN}✓${NC} ${tool} found: ${version}"
    else
        echo -e "  ${RED}✗${NC} ${tool} not found"
        MISSING+=("$tool")
    fi
}

echo "Checking test prerequisites..."
echo ""

check_tool "jq"
check_tool "shellcheck"

# ─── Bats submodule check ─────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_BIN="${SCRIPT_DIR}/../tests/bats/bin/bats"

if [ -x "$BATS_BIN" ]; then
    bats_version=$("$BATS_BIN" --version 2>&1 | head -1)
    echo -e "  ${GREEN}✓${NC} bats found: ${bats_version}"
else
    echo -e "  ${RED}✗${NC} bats submodule not initialized — not found"
    MISSING+=("bats")
fi

echo ""

# ─── Install instructions ─────────────────────────────────────

if [ ${#MISSING[@]} -ne 0 ]; then
    echo -e "${RED}Missing: ${MISSING[*]}${NC}"
    echo ""
    echo "Install instructions for ${PLATFORM}:"
    echo ""

    for tool in "${MISSING[@]}"; do
        case "$tool" in
            jq)
                case "$PLATFORM" in
                    linux)   echo "  jq:         sudo apt-get install -y jq" ;;
                    macos)   echo "  jq:         brew install jq" ;;
                    windows) echo "  jq:         winget install jqlang.jq" ;;
                    *)       echo "  jq:         see https://jqlang.github.io/jq/download/" ;;
                esac
                ;;
            shellcheck)
                case "$PLATFORM" in
                    linux)   echo "  shellcheck: sudo apt-get install -y shellcheck" ;;
                    macos)   echo "  shellcheck: brew install shellcheck" ;;
                    windows) echo "  shellcheck: winget install koalaman.shellcheck" ;;
                    *)       echo "  shellcheck: see https://github.com/koalaman/shellcheck#installing" ;;
                esac
                ;;
            bats)
                echo "  bats:       git submodule update --init --recursive"
                ;;
        esac
    done

    echo ""
    exit 1
fi

echo -e "${GREEN}All test prerequisites met.${NC}"
