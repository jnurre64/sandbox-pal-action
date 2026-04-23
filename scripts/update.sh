#!/bin/bash
# shellcheck disable=SC1091  # Sourced files are resolved at runtime
set -euo pipefail

# ─── Update a standalone sandbox-pal-dispatch installation from upstream ──
# Usage: update.sh [path-to-.sandbox-pal-dispatch]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-.sandbox-pal-dispatch}"

# Secret-detection keywords — vars matching these are flagged and never written
SECRET_KEYWORDS="TOKEN|KEY|SECRET|WEBHOOK|PASSWORD|CREDENTIAL"

# Source config var parser (from upstream clone if available, else local)
# Deferred until after upstream clone — see below

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}Installation directory not found: $INSTALL_DIR${NC}"
    echo "Usage: update.sh [path-to-.sandbox-pal-dispatch]"
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

# Source config var parser from upstream clone (gets the latest version)
if [ -f "$UPSTREAM_DIR/scripts/lib/config-vars.sh" ]; then
    # shellcheck source=lib/config-vars.sh
    source "$UPSTREAM_DIR/scripts/lib/config-vars.sh"
elif [ -f "$SCRIPT_DIR/lib/config-vars.sh" ]; then
    # Fallback to local copy
    # shellcheck source=lib/config-vars.sh
    source "$SCRIPT_DIR/lib/config-vars.sh"
fi

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

# ── Detect new config variables ──────────────────────────────────
CONFIG_ADDED=0
CONFIG_COMMENTED=0
CONFIG_SKIPPED=0
CONFIG_SENSITIVE=0

if type parse_config_vars &>/dev/null && [ -f "$UPSTREAM_DIR/config.defaults.env.example" ]; then
    # Parse new upstream vars
    mapfile -t NEW_UPSTREAM_VARS < <(parse_config_vars "$UPSTREAM_DIR/config.defaults.env.example")

    # Parse stored vars from .upstream config_vars: section
    STORED_CONFIG_VARS=()
    if grep -q '^config_vars:' "$UPSTREAM_FILE" 2>/dev/null; then
        mapfile -t STORED_CONFIG_VARS < <(
            sed -n '/^config_vars:/,/^[^ ]/{ /^  - /s/^  - //p }' "$UPSTREAM_FILE"
        )
    fi

    if [ ${#STORED_CONFIG_VARS[@]} -eq 0 ]; then
        # First-run: no config_vars: section yet — initialize tracking without prompting
        echo -e "${CYAN}Config variable tracking initialized.${NC}"
        echo "New settings will be detected on your next update."
        echo "Run a manual check of config.defaults.env.example if you want to audit current settings."
        echo ""
    else
        # Compute genuinely new vars: in upstream but not in stored list
        GENUINELY_NEW_VARS=()
        for var in "${NEW_UPSTREAM_VARS[@]}"; do
            found=false
            for stored in "${STORED_CONFIG_VARS[@]}"; do
                if [ "$var" = "$stored" ]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                GENUINELY_NEW_VARS+=("$var")
            fi
        done

        if [ ${#GENUINELY_NEW_VARS[@]} -gt 0 ]; then
            # Determine config file path
            # Look for config.env adjacent to the install dir (standalone layout)
            CONFIG_ENV=""
            if [ -f "$INSTALL_DIR/config.env" ]; then
                CONFIG_ENV="$INSTALL_DIR/config.env"
            elif [ -f "$(dirname "$INSTALL_DIR")/config.env" ]; then
                CONFIG_ENV="$(dirname "$INSTALL_DIR")/config.env"
            fi

            # Parse vars already in user's config.env
            USER_VARS=()
            if [ -n "$CONFIG_ENV" ]; then
                mapfile -t USER_VARS < <(parse_config_vars "$CONFIG_ENV")
            fi

            # Filter out vars user already has
            VARS_TO_PROMPT=()
            for var in "${GENUINELY_NEW_VARS[@]}"; do
                already_set=false
                for user_var in "${USER_VARS[@]}"; do
                    if [ "$var" = "$user_var" ]; then
                        already_set=true
                        break
                    fi
                done
                if [ "$already_set" = false ]; then
                    VARS_TO_PROMPT+=("$var")
                fi
            done

            if [ ${#VARS_TO_PROMPT[@]} -gt 0 ]; then
                echo -e "${BOLD}New Configuration Settings${NC}"
                echo "The following settings were added upstream since your last update:"
                echo ""

                # Build context lookup from upstream example
                declare -A VAR_DEFAULTS VAR_COMMENTS
                while IFS='|' read -r vname vdefault vcomment; do
                    # Only store first occurrence (skip example duplicates)
                    if [ -z "${VAR_DEFAULTS[$vname]+x}" ]; then
                        VAR_DEFAULTS[$vname]="$vdefault"
                        VAR_COMMENTS[$vname]="$vcomment"
                    fi
                done < <(parse_config_vars_with_context "$UPSTREAM_DIR/config.defaults.env.example")

                BACKUP_CREATED=false
                HEADER_WRITTEN=false

                for var in "${VARS_TO_PROMPT[@]}"; do
                    default_val="${VAR_DEFAULTS[$var]:-}"
                    comment="${VAR_COMMENTS[$var]:-}"

                    # Secret heuristic check
                    if echo "$var" | grep -qE "$SECRET_KEYWORDS"; then
                        echo -e "  ${YELLOW}⚠${NC}  ${BOLD}$var${NC} — flagged as potentially sensitive"
                        if [ -n "$comment" ]; then
                            echo "      $comment"
                        fi
                        echo "      This looks like a secret. Not offering to write it."
                        echo ""
                        CONFIG_SENSITIVE=$((CONFIG_SENSITIVE + 1))
                        continue
                    fi

                    echo -e "  ${BOLD}$var${NC}"
                    if [ -n "$comment" ]; then
                        echo -e "      ${comment}"
                    fi
                    if [ -n "$default_val" ]; then
                        echo -e "      Upstream default: ${CYAN}${default_val}${NC}"
                    else
                        echo -e "      Upstream default: ${CYAN}(empty)${NC}"
                    fi
                    echo ""

                    read -rp "      (A)dd active / (c)ommented (default) / (s)kip: " CHOICE
                    CHOICE="${CHOICE:-c}"

                    case "$CHOICE" in
                        a|A)
                            if [ -n "$CONFIG_ENV" ]; then
                                # Create backup before first write
                                if [ "$BACKUP_CREATED" = false ]; then
                                    cp "$CONFIG_ENV" "${CONFIG_ENV}.bak.$(date '+%Y%m%d')"
                                    BACKUP_CREATED=true
                                fi
                                # Write section header before first entry
                                if [ "$HEADER_WRITTEN" = false ]; then
                                    echo "" >> "$CONFIG_ENV"
                                    echo "# ── Added by /update on $(date '+%Y-%m-%d') ──" >> "$CONFIG_ENV"
                                    HEADER_WRITTEN=true
                                fi
                                echo "${var}=\"${default_val}\"" >> "$CONFIG_ENV"
                                echo -e "      ${GREEN}✓${NC} Added to config.env"
                                CONFIG_ADDED=$((CONFIG_ADDED + 1))
                            else
                                echo -e "      ${YELLOW}!${NC} No config.env found — skipped"
                                CONFIG_SKIPPED=$((CONFIG_SKIPPED + 1))
                            fi
                            ;;
                        c|C)
                            if [ -n "$CONFIG_ENV" ]; then
                                if [ "$BACKUP_CREATED" = false ]; then
                                    cp "$CONFIG_ENV" "${CONFIG_ENV}.bak.$(date '+%Y%m%d')"
                                    BACKUP_CREATED=true
                                fi
                                if [ "$HEADER_WRITTEN" = false ]; then
                                    echo "" >> "$CONFIG_ENV"
                                    echo "# ── Added by /update on $(date '+%Y-%m-%d') ──" >> "$CONFIG_ENV"
                                    HEADER_WRITTEN=true
                                fi
                                echo "# ${var}=\"${default_val}\"  # (upstream default)" >> "$CONFIG_ENV"
                                echo -e "      ${GREEN}✓${NC} Added as commented entry"
                                CONFIG_COMMENTED=$((CONFIG_COMMENTED + 1))
                            else
                                echo -e "      ${YELLOW}!${NC} No config.env found — skipped"
                                CONFIG_SKIPPED=$((CONFIG_SKIPPED + 1))
                            fi
                            ;;
                        *)
                            echo -e "      ${CYAN}→${NC} Skipped"
                            CONFIG_SKIPPED=$((CONFIG_SKIPPED + 1))
                            ;;
                    esac
                    echo ""
                done
            fi
        fi
    fi
fi

# ── Update .upstream tracking ────────────────────────────────────
echo -e "${CYAN}Updating version tracking...${NC}"
{
    echo "# Upstream tracking for standalone sandbox-pal-dispatch installation"
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
    # Track known config vars for future new-var detection
    if type parse_config_vars &>/dev/null && [ -f "$UPSTREAM_DIR/config.defaults.env.example" ]; then
        echo "config_vars:"
        parse_config_vars "$UPSTREAM_DIR/config.defaults.env.example" | while read -r var; do
            echo "  - $var"
        done
    fi
} > "$UPSTREAM_FILE"

echo -e "  ${GREEN}✓${NC} Updated .upstream to ${LATEST_SHA:0:12}"
echo ""

echo -e "${BOLD}Update complete.${NC}"

# Config migration summary
CONFIG_TOTAL=$((CONFIG_ADDED + CONFIG_COMMENTED + CONFIG_SKIPPED + CONFIG_SENSITIVE))
if [ "$CONFIG_TOTAL" -gt 0 ]; then
    echo -n "Config: $CONFIG_TOTAL new setting(s) detected"
    details=()
    [ "$CONFIG_ADDED" -gt 0 ] && details+=("$CONFIG_ADDED added")
    [ "$CONFIG_COMMENTED" -gt 0 ] && details+=("$CONFIG_COMMENTED commented")
    [ "$CONFIG_SKIPPED" -gt 0 ] && details+=("$CONFIG_SKIPPED skipped")
    [ "$CONFIG_SENSITIVE" -gt 0 ] && details+=("$CONFIG_SENSITIVE sensitive")
    if [ ${#details[@]} -gt 0 ]; then
        echo -n " ("
        IFS=', ' ; echo -n "${details[*]}" ; IFS=$' \t\n'
        echo ")"
    else
        echo ""
    fi
fi

echo "Don't forget to commit: git add .sandbox-pal-dispatch/ && git commit -m 'Update sandbox-pal-dispatch from upstream'"
echo ""
