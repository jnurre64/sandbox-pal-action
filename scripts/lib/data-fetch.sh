#!/bin/bash
# ─── Extract debug data from issue/PR comments ──────────────────
# Provides: extract_debug_data
# Sets globals: EXTRACTED_DATA_COMMENT_FILE, EXTRACTED_GIST_FILES, EXTRACTED_DATA_ERRORS
# Pre-fetches save/log data so Claude can read them as local files.
# Supports three formats:
#   1. submit-logs skill: comments with "### Environment" marker
#   2. Gist links: https://gist.github.com/user/id
#   3. GitHub file attachments: https://github.com/user-attachments/{assets,files}/...
#
# Usage: extract_debug_data <comments_json> <data_dir> [extra_text]
#
# Sets these globals:
#   EXTRACTED_DATA_COMMENT_FILE — path to latest data comment (or empty)
#   EXTRACTED_GIST_FILES — space-separated paths to downloaded files
#   EXTRACTED_DATA_ERRORS — path to error file

# Helper: download gists and file attachments from a text blob.
_download_linked_files() {
    local text="$1"
    local data_dir="$2"

    # Download gist content
    local gist_urls
    gist_urls=$(echo "$text" | grep -oE 'https://gist\.github\.com/[a-zA-Z0-9_-]+/[a-f0-9]+' | sort -u)
    for gist_url in $gist_urls; do
        local gist_id
        gist_id=$(basename "$gist_url")
        local gist_file="${data_dir}/gist-${gist_id}.txt"
        log "Downloading gist: $gist_url"
        if gh gist view "$gist_id" --raw > "$gist_file" 2>/dev/null; then
            log "Saved gist ($(wc -c < "$gist_file") bytes)"
            EXTRACTED_GIST_FILES="${EXTRACTED_GIST_FILES} ${gist_file}"
        else
            log "WARN: Failed to download gist: $gist_url"
            echo "FAILED: $gist_url" >> "$EXTRACTED_DATA_ERRORS"
        fi
    done

    # Download GitHub file attachments (drag-and-drop uploads)
    local attachment_urls
    attachment_urls=$(echo "$text" | grep -oE 'https://github\.com/user-attachments/(assets|files)/[a-zA-Z0-9_./-]+' | sort -u)
    for attach_url in $attachment_urls; do
        local attach_filename
        attach_filename=$(basename "$attach_url")
        # If basename is a uuid (no extension), try to get name from markdown link
        if [[ "$attach_filename" != *.* ]]; then
            # Try to find the markdown link label for this URL: [label](attach_url)
            # Escape dots in URL for use in bash regex. The attachment-URL regex
            # above constrains characters to [a-zA-Z0-9_./-], so . is the only
            # regex metacharacter we need to handle.
            local url_re="${attach_url//./"\\."}"
            local md_name=""
            if [[ "$text" =~ \[([^]]+)\]\($url_re\) ]]; then
                md_name="${BASH_REMATCH[1]}"
            fi
            [ -n "$md_name" ] && attach_filename="$md_name"
        fi
        [ -z "$attach_filename" ] && attach_filename="attachment-$(echo "$attach_url" | md5sum | cut -c1-8)"
        local attach_file="${data_dir}/${attach_filename}"
        log "Downloading attachment: $attach_url -> $attach_filename"
        if curl -sL -H "Authorization: token ${GH_TOKEN:-}" -o "$attach_file" "$attach_url" 2>/dev/null && [ -s "$attach_file" ]; then
            local first_bytes
            first_bytes=$(head -c 20 "$attach_file")
            if [ "$first_bytes" = "Not Found" ] || echo "$first_bytes" | grep -q '<!DOCTYPE'; then
                log "WARN: Attachment returned error page: $attach_url"
                echo "FAILED (may require browser auth): $attach_url" >> "$EXTRACTED_DATA_ERRORS"
                rm -f "$attach_file"
            else
                log "Saved attachment ($(wc -c < "$attach_file") bytes)"
                EXTRACTED_GIST_FILES="${EXTRACTED_GIST_FILES} ${attach_file}"
            fi
        else
            log "WARN: Failed to download attachment: $attach_url"
            echo "FAILED: $attach_url" >> "$EXTRACTED_DATA_ERRORS"
            rm -f "$attach_file"
        fi
    done
}

extract_debug_data() {
    local comments_json="$1"
    local data_dir="$2"
    local extra_text="${3:-}"
    mkdir -p "$data_dir"

    EXTRACTED_DATA_COMMENT_FILE=""
    EXTRACTED_GIST_FILES=""
    EXTRACTED_DATA_ERRORS="${data_dir}/data-errors.txt"

    # Find the latest non-bot comment with debug data
    local latest_data_comment
    latest_data_comment=$(echo "$comments_json" | jq -r '
        [.[] | select(.author.login != "'"$AGENT_BOT_USER"'") | select(.body | test("### Environment"))] | last | .body // ""
    ' 2>/dev/null)

    if [ -z "$latest_data_comment" ]; then
        latest_data_comment=$(echo "$comments_json" | jq -r '
            [.[] | select(.author.login != "'"$AGENT_BOT_USER"'") | select(.body | test("gist\\.github\\.com|user-attachments/"))] | last | .body // ""
        ' 2>/dev/null)
    fi

    if [ -n "$latest_data_comment" ]; then
        log "Found data comment (${#latest_data_comment} chars)"
        EXTRACTED_DATA_COMMENT_FILE="${data_dir}/latest-data-comment.md"
        echo "$latest_data_comment" > "$EXTRACTED_DATA_COMMENT_FILE"
        log "Saved latest data comment ($(wc -c < "$EXTRACTED_DATA_COMMENT_FILE") bytes)"
        _download_linked_files "$latest_data_comment" "$data_dir"
    fi

    # Also check the extra text (issue body / PR body) for attachments
    if [ -n "$extra_text" ]; then
        local has_links=false
        echo "$extra_text" | grep -qE 'gist\.github\.com|user-attachments/' && has_links=true
        if [ "$has_links" = true ]; then
            log "Found linked files in issue/PR body"
            if [ -z "$EXTRACTED_DATA_COMMENT_FILE" ]; then
                EXTRACTED_DATA_COMMENT_FILE="${data_dir}/issue-body.md"
                echo "$extra_text" > "$EXTRACTED_DATA_COMMENT_FILE"
                log "Saved issue/PR body as data source ($(wc -c < "$EXTRACTED_DATA_COMMENT_FILE") bytes)"
            fi
            _download_linked_files "$extra_text" "$data_dir"
        fi
    fi

    if [ -z "$EXTRACTED_DATA_COMMENT_FILE" ] && [ -z "$EXTRACTED_GIST_FILES" ]; then
        log "No data comment or linked files found"
    fi
}
