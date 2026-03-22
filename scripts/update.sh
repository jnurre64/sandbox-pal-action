#!/bin/bash
set -euo pipefail

# ─── Update a standalone agent-dispatch installation from upstream ──
# Usage: update.sh [path-to-.agent-dispatch]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="${1:-.agent-dispatch}"

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}Installation directory not found: $INSTALL_DIR${NC}"
    echo "Usage: update.sh [path-to-.agent-dispatch]"
    exit 1
fi

UPSTREAM_FILE="$INSTALL_DIR/.upstream"

if [ ! -f "$UPSTREAM_FILE" ]; then
    echo -e "${RED}.upstream tracking file not found at $UPSTREAM_FILE${NC}"
    echo "This installation may predate the update mechanism."
    echo "Run /setup again or manually create the .upstream file."
    exit 1
fi

echo ""
echo -e "${BOLD}Claude Agent Dispatch — Update${NC}"
echo "═══════════════════════════════"
echo ""

# ── Parse .upstream file ─────────────────────────────────────────
UPSTREAM_REPO=$(grep '^repo:' "$UPSTREAM_FILE" | sed 's/^repo: *//')
STORED_VERSION=$(grep '^version:' "$UPSTREAM_FILE" | sed 's/^version: *//')

echo -e "Current version: ${CYAN}${STORED_VERSION:0:12}${NC}"
echo -e "Upstream repo:   ${CYAN}${UPSTREAM_REPO}${NC}"
echo ""

# ── Fetch latest upstream ────────────────────────────────────────
echo -e "${CYAN}Fetching latest upstream...${NC}"
UPSTREAM_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$UPSTREAM_DIR'" EXIT

git clone --depth=1 "$UPSTREAM_REPO" "$UPSTREAM_DIR" 2>/dev/null
LATEST_SHA=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)

echo -e "Latest upstream:  ${CYAN}${LATEST_SHA:0:12}${NC}"
echo ""

if [ "$STORED_VERSION" = "$LATEST_SHA" ]; then
    echo -e "${GREEN}Already up to date.${NC}"
    exit 0
fi

# ── Discover trackable files from upstream ────────────────────────
# Dynamically finds all scripts, prompts, and config files rather than
# using a hardcoded list. This ensures new files added upstream are detected.
TRACKED_FILES=()
while IFS= read -r -d '' file; do
    # Get path relative to upstream root
    rel_path="${file#"$UPSTREAM_DIR/"}"
    TRACKED_FILES+=("$rel_path")
done < <(find "$UPSTREAM_DIR/scripts" "$UPSTREAM_DIR/prompts" -type f -print0 2>/dev/null)
# Also track labels.txt
[ -f "$UPSTREAM_DIR/labels.txt" ] && TRACKED_FILES+=("labels.txt")

# ── Categorize files ─────────────────────────────────────────────
AUTO_UPDATE=()
NEEDS_REVIEW=()
UP_TO_DATE=()
LOCAL_ONLY=()
NEW_FILES=()

get_stored_checksum() {
    local file="$1"
    grep "  ${file}:" "$UPSTREAM_FILE" | sed 's/.*"sha256://' | sed 's/".*//' || echo ""
}

for file in "${TRACKED_FILES[@]}"; do
    local_path="$INSTALL_DIR/$file"
    upstream_path="$UPSTREAM_DIR/$file"
    stored_checksum=$(get_stored_checksum "$file")

    if [ ! -f "$upstream_path" ]; then
        continue  # File removed from upstream, skip
    fi

    upstream_checksum=$(sha256sum "$upstream_path" | cut -d' ' -f1)

    if [ ! -f "$local_path" ]; then
        NEW_FILES+=("$file")
        continue
    fi

    local_checksum=$(sha256sum "$local_path" | cut -d' ' -f1)
    local_modified=false
    upstream_changed=false

    if [ -z "$stored_checksum" ]; then
        # No stored checksum — assume locally modified (conservative)
        local_modified=true
    elif [ "$local_checksum" != "$stored_checksum" ]; then
        local_modified=true
    fi

    if [ -z "$stored_checksum" ] || [ "$upstream_checksum" != "$stored_checksum" ]; then
        upstream_changed=true
    fi

    if [ "$local_modified" = false ] && [ "$upstream_changed" = false ]; then
        UP_TO_DATE+=("$file")
    elif [ "$local_modified" = false ] && [ "$upstream_changed" = true ]; then
        AUTO_UPDATE+=("$file")
    elif [ "$local_modified" = true ] && [ "$upstream_changed" = true ]; then
        NEEDS_REVIEW+=("$file")
    else
        LOCAL_ONLY+=("$file")
    fi
done

# ── Show summary ─────────────────────────────────────────────────
echo -e "${BOLD}Update Summary (${STORED_VERSION:0:8} → ${LATEST_SHA:0:8}):${NC}"
echo ""

if [ ${#AUTO_UPDATE[@]} -gt 0 ]; then
    echo -e "  ${GREEN}Auto-update${NC} (safe to overwrite — no local modifications):"
    for f in "${AUTO_UPDATE[@]}"; do echo "    $f"; done
    echo ""
fi

if [ ${#NEEDS_REVIEW[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}Needs review${NC} (both sides changed):"
    for f in "${NEEDS_REVIEW[@]}"; do echo "    $f"; done
    echo ""
fi

if [ ${#NEW_FILES[@]} -gt 0 ]; then
    echo -e "  ${CYAN}New from upstream${NC}:"
    for f in "${NEW_FILES[@]}"; do echo "    $f"; done
    echo ""
fi

if [ ${#UP_TO_DATE[@]} -gt 0 ]; then
    echo "  Up to date:"
    for f in "${UP_TO_DATE[@]}"; do echo "    $f"; done
    echo ""
fi

if [ ${#LOCAL_ONLY[@]} -gt 0 ]; then
    echo "  Local only (your changes, upstream unchanged):"
    for f in "${LOCAL_ONLY[@]}"; do echo "    $f"; done
    echo ""
fi

# ── Apply auto-updates ───────────────────────────────────────────
if [ ${#AUTO_UPDATE[@]} -gt 0 ]; then
    read -rp "Apply all auto-updates? [Y/n]: " APPLY_AUTO
    APPLY_AUTO="${APPLY_AUTO:-Y}"
    if [[ "$APPLY_AUTO" =~ ^[Yy] ]]; then
        for file in "${AUTO_UPDATE[@]}"; do
            cp "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
            echo -e "  ${GREEN}✓${NC} Updated $file"
        done
    fi
    echo ""
fi

# ── Handle needs-review files ────────────────────────────────────
if [ ${#NEEDS_REVIEW[@]} -gt 0 ]; then
    echo -e "${YELLOW}The following files have both local and upstream changes.${NC}"
    echo "For each file, choose: (a)ccept upstream, (k)eep local, or (d)iff to review."
    echo ""
    for file in "${NEEDS_REVIEW[@]}"; do
        echo -e "  ${BOLD}$file${NC}"
        read -rp "  [a]ccept upstream / [k]eep local / [d]iff? " CHOICE
        case "$CHOICE" in
            a|A)
                cp "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
                echo -e "  ${GREEN}✓${NC} Replaced with upstream version"
                ;;
            d|D)
                echo ""
                diff -u "$INSTALL_DIR/$file" "$UPSTREAM_DIR/$file" || true
                echo ""
                read -rp "  After reviewing: [a]ccept upstream / [k]eep local? " CHOICE2
                if [[ "$CHOICE2" =~ ^[aA] ]]; then
                    cp "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
                    echo -e "  ${GREEN}✓${NC} Replaced with upstream version"
                else
                    echo -e "  ${CYAN}→${NC} Kept local version"
                fi
                ;;
            *)
                echo -e "  ${CYAN}→${NC} Kept local version"
                ;;
        esac
        echo ""
    done
fi

# ── Handle new files ─────────────────────────────────────────────
if [ ${#NEW_FILES[@]} -gt 0 ]; then
    read -rp "Add new upstream files? [Y/n]: " ADD_NEW
    ADD_NEW="${ADD_NEW:-Y}"
    if [[ "$ADD_NEW" =~ ^[Yy] ]]; then
        for file in "${NEW_FILES[@]}"; do
            mkdir -p "$(dirname "$INSTALL_DIR/$file")"
            cp "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
            echo -e "  ${GREEN}✓${NC} Added $file"
        done
    fi
    echo ""
fi

# ── Update .upstream tracking ────────────────────────────────────
echo -e "${CYAN}Updating version tracking...${NC}"
{
    echo "# Upstream tracking for standalone agent-dispatch installation"
    echo "# Do not edit manually — managed by /update skill and setup.sh"
    echo "repo: $UPSTREAM_REPO"
    echo "version: $LATEST_SHA"
    echo "synced_at: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
    echo "checksums:"
    for file in "${TRACKED_FILES[@]}"; do
        local_path="$INSTALL_DIR/$file"
        if [ -f "$local_path" ]; then
            checksum=$(sha256sum "$local_path" | cut -d' ' -f1)
            echo "  ${file}: \"sha256:${checksum}\""
        fi
    done
} > "$UPSTREAM_FILE"

echo -e "  ${GREEN}✓${NC} Updated .upstream to ${LATEST_SHA:0:12}"
echo ""

echo -e "${BOLD}Update complete.${NC}"
echo "Don't forget to commit: git add .agent-dispatch/ && git commit -m 'Update agent-dispatch from upstream'"
echo ""
