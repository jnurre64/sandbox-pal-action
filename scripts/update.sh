#!/bin/bash
# shellcheck disable=SC1091  # Sourced files are resolved at runtime
set -euo pipefail

# ─── Update a standalone sandbox-pal-dispatch installation from upstream ──
# Usage: update.sh [--yes] [path-to-.sandbox-pal-dispatch]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=false
if [ "${1:-}" = "--yes" ]; then
    ASSUME_YES=true
    shift
fi
INSTALL_DIR="${1:-.sandbox-pal-dispatch}"

# EOF preserves files/config; --yes accepts only safe updates and new assets.
prompt_update() {
    local prompt="$1" variable="$2" fallback="$3" automatic="$4" answer
    if [ "$ASSUME_YES" = true ]; then
        answer="$automatic"
    elif ! read -rp "$prompt" answer; then
        answer="$fallback"
    fi
    printf -v "$variable" '%s' "$answer"
}

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
    echo "Already up to date by version; checking for missing or deferred assets."
fi

# ── Discover trackable files from the shared inventory ────────────
if [ -f "$UPSTREAM_DIR/scripts/lib/install-assets.sh" ]; then
    source "$UPSTREAM_DIR/scripts/lib/install-assets.sh"
else
    source "$SCRIPT_DIR/lib/install-assets.sh"
fi
mapfile -d '' -t TRACKED_FILES < <(list_install_assets "$UPSTREAM_DIR")

# ── Categorize files ─────────────────────────────────────────────
AUTO_UPDATE=()
NEEDS_REVIEW=()
UP_TO_DATE=()
LOCAL_ONLY=()
NEW_FILES=()

get_stored_checksum() {
    local file="$1"
    awk -v key="  ${file}:" 'index($0, key " ") == 1 {
        sub(/^.*"sha256:/, ""); sub(/".*$/, ""); print; exit
    }' "$UPSTREAM_FILE"
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
    # Recover a copy interrupted before metadata was stamped.
    if [ "$local_checksum" = "$upstream_checksum" ]; then
        UP_TO_DATE+=("$file")
        continue
    fi
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

for file in "${AUTO_UPDATE[@]}" "${NEEDS_REVIEW[@]}" "${NEW_FILES[@]}"; do
    if [[ "$file" == .claude/skills/setup/templates/* ]]; then
        echo "Workflow templates changed: review $INSTALL_DIR/.claude/skills/setup/templates/"
        echo "Apply relevant changes to your repository's .github/workflows/ (preserving actor filters)."
        break
    fi
done

# ── Apply auto-updates ───────────────────────────────────────────
if [ ${#AUTO_UPDATE[@]} -gt 0 ]; then
    prompt_update "Apply all auto-updates? [Y/n]: " APPLY_AUTO n Y
    APPLY_AUTO="${APPLY_AUTO:-Y}"
    if [[ "$APPLY_AUTO" =~ ^[Yy] ]]; then
        for file in "${AUTO_UPDATE[@]}"; do
            copy_install_asset "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
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
        prompt_update "  [a]ccept upstream / [k]eep local / [d]iff? " CHOICE k k
        case "$CHOICE" in
            a|A)
                copy_install_asset "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
                echo -e "  ${GREEN}✓${NC} Replaced with upstream version"
                ;;
            d|D)
                echo ""
                diff -u "$INSTALL_DIR/$file" "$UPSTREAM_DIR/$file" || true
                echo ""
                prompt_update "  After reviewing: [a]ccept upstream / [k]eep local? " CHOICE2 k k
                # shellcheck disable=SC2153 # Assigned indirectly by prompt_update.
                if [[ "$CHOICE2" =~ ^[aA] ]]; then
                    copy_install_asset "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
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
    prompt_update "Add new upstream files? [Y/n]: " ADD_NEW n Y
    ADD_NEW="${ADD_NEW:-Y}"
    if [[ "$ADD_NEW" =~ ^[Yy] ]]; then
        for file in "${NEW_FILES[@]}"; do
            mkdir -p "$(dirname "$INSTALL_DIR/$file")"
            copy_install_asset "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"
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

                    prompt_update "      (A)dd active / (c)ommented (default) / (s)kip: " CHOICE s s
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
PENDING_ASSETS=0
for file in "${TRACKED_FILES[@]}"; do
    if ! cmp -s "$UPSTREAM_DIR/$file" "$INSTALL_DIR/$file"; then
        PENDING_ASSETS=$((PENDING_ASSETS + 1))
    fi
done
{
    echo "# Upstream tracking for standalone sandbox-pal-dispatch installation"
    echo "# Do not edit manually — managed by /update skill and setup.sh"
    echo "repo: $UPSTREAM_REPO"
    echo "version: $LATEST_SHA"
    echo "pending_assets: $PENDING_ASSETS"
    echo "synced_at: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
    echo "checksums:"
    for file in "${TRACKED_FILES[@]}"; do
        local_path="$INSTALL_DIR/$file"
        if [ -f "$local_path" ]; then
            checksum=$(sha256sum "$UPSTREAM_DIR/$file" | cut -d' ' -f1)
            local_checksum=$(sha256sum "$local_path" | cut -d' ' -f1)
            if [ "$local_checksum" != "$checksum" ]; then
                checksum=$(get_stored_checksum "$file")
            fi
            # Keep the previous baseline for deferred/customized assets.
            if [ -n "$checksum" ]; then
                echo "  ${file}: \"sha256:${checksum}\""
            fi
        fi
    done
    # Track known config vars for future new-var detection
    if type parse_config_vars &>/dev/null && [ -f "$UPSTREAM_DIR/config.defaults.env.example" ]; then
        echo "config_vars:"
        parse_config_vars "$UPSTREAM_DIR/config.defaults.env.example" | while read -r var; do
            echo "  - $var"
        done
    fi
} > "$UPSTREAM_FILE.tmp"
mv "$UPSTREAM_FILE.tmp" "$UPSTREAM_FILE"

# Older distributions may not yet provide client discovery assets/helpers.
if type link_install_client_skills &>/dev/null; then
    link_install_client_skills "$INSTALL_DIR"
fi

echo -e "  ${GREEN}✓${NC} Updated .upstream to ${LATEST_SHA:0:12}"
echo ""

echo -e "${BOLD}Update complete.${NC}"
if [ "$PENDING_ASSETS" -gt 0 ]; then
    echo "$PENDING_ASSETS asset(s) remain customized or deferred; rerun update to review."
fi

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

# The first dispatch would fail on this; say so now (#159).
if ! "${AGENT_PYTHON:-python3}" "$INSTALL_DIR/scripts/lib/agent-result.py" check-dependency >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning:${NC} the worker validator's Python dependency is missing or too old."
    echo "  Run: bash $INSTALL_DIR/scripts/check-prereqs.sh"
    echo ""
fi

echo "Review and commit the updated .sandbox-pal-dispatch/ assets and any new .claude/skills/ and .agents/skills/ links."
echo ""
