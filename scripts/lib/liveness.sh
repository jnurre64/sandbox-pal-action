#!/bin/bash
# ─── Dispatch liveness: lock heartbeat, stale detection, outcome record ──
# Provides: acquire_dispatch_lock, set_heartbeat, release_dispatch_lock,
#           write_last_dispatch, handle_status
#
# A session that dispatches a long-running pipeline has to answer "is it
# still going?", and background-task monitors are not reliable — a run
# reported killed can be alive and go on to open a PR. Three independent
# signals (#94): the lock carries pid/host/start/current-phase and is
# heartbeat-updated as the pipeline advances; `status` reports live vs.
# stale without mutating anything; and a last-dispatch record is written
# before exit on every outcome, because a failure is exactly when the
# calling session is least likely to still hold the pipe.

DISPATCH_LOCK_HELD=""
DISPATCH_OUTCOME=""
DISPATCH_STARTED=""
DISPATCH_PR_URL=""
DISPATCH_LOCK_REFUSED=""

_lock_path() {
    echo "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"
}

_last_dispatch_path() {
    echo "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}-last-dispatch.json"
}

_utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# One dispatch per issue. A held lock is refused with the holder named
# (pid, host, start, phase, path) so a live run and a leftover are
# distinguishable. A same-host lock whose pid is dead is reclaimed; a
# lock from another host is never reclaimed — we cannot check its pid.
acquire_dispatch_lock() {
    local lock
    lock=$(_lock_path)
    mkdir -p "$AGENT_LOCK_DIR"
    if [ -f "$lock" ]; then
        local held_pid held_host
        held_pid=$(jq -r '.pid // empty' "$lock" 2>/dev/null)
        held_host=$(jq -r '.host // empty' "$lock" 2>/dev/null)
        if [ "$held_host" != "$(hostname)" ]; then
            log "Dispatch lock held by another host (${held_host:-unknown}, pid ${held_pid:-unknown}) — refusing. Lock: ${lock}"
            return 1
        fi
        if [ -n "$held_pid" ] && ps -p "$held_pid" >/dev/null 2>&1; then
            log "Dispatch lock held by a live run (pid ${held_pid}, phase $(jq -r '.phase // "?"' "$lock"), started $(jq -r '.started // "?"' "$lock")) — refusing. Lock: ${lock}"
            return 1
        fi
        log "Reclaiming stale dispatch lock (pid ${held_pid:-unknown} is dead). Lock: ${lock}"
    fi
    DISPATCH_STARTED=$(_utc_now)
    jq -n --arg pid "$$" --arg host "$(hostname)" --arg event "$EVENT_TYPE" \
          --arg issue "$NUMBER" --arg started "$DISPATCH_STARTED" \
        '{pid: ($pid | tonumber), host: $host, event: $event, issue: $issue,
          started: $started, phase: "starting", updated: $started}' > "$lock"
    DISPATCH_LOCK_HELD=1
    return 0
}

# Update the lock's current phase. Called at each phase start and once
# per review-loop pass — that is where a long dispatch actually spends
# its time, and without it status cannot distinguish "reviewing" from
# "died after the test gate". No-op when we do not hold the lock.
set_heartbeat() {
    local phase="$1"
    [ -n "$DISPATCH_LOCK_HELD" ] || return 0
    local lock
    lock=$(_lock_path)
    [ -f "$lock" ] || return 0
    local tmp="${lock}.tmp"
    jq --arg p "$phase" --arg u "$(_utc_now)" '.phase = $p | .updated = $u' \
        "$lock" > "$tmp" 2>/dev/null && mv "$tmp" "$lock"
    return 0
}

# Remove our own lock only — never a lock owned by another pid.
release_dispatch_lock() {
    local lock
    lock=$(_lock_path)
    [ -f "$lock" ] || return 0
    if [ "$(jq -r '.pid // empty' "$lock" 2>/dev/null)" = "$$" ]; then
        rm -f "$lock"
    fi
    return 0
}

# The run's own outcome record, written before the process exits on
# every outcome including failure. Only a dispatch that held the lock
# writes it — a refused dispatch must not overwrite the running run's
# record, and status never writes it at all.
write_last_dispatch() {
    local exit_code="${1:-0}"
    [ -n "$DISPATCH_LOCK_HELD" ] || return 0
    local outcome="$DISPATCH_OUTCOME"
    if [ -z "$outcome" ]; then
        [ "$exit_code" -eq 0 ] && outcome="success" || outcome="error"
    fi
    jq -n --arg event "$EVENT_TYPE" --arg repo "$REPO" --arg issue "$NUMBER" \
          --arg outcome "$outcome" --arg ec "$exit_code" --arg pr "$DISPATCH_PR_URL" \
          --arg started "${DISPATCH_STARTED:-}" --arg finished "$(_utc_now)" \
        '{event: $event, repo: $repo, issue: $issue, outcome: $outcome,
          exit_code: ($ec | tonumber), pr_url: $pr,
          started: $started, finished: $finished}' \
        > "$(_last_dispatch_path)"
    return 0
}

# The orchestrator-mode result: exactly one compact JSON line on stdout,
# emitted as the very last thing the dispatch prints. Everything a
# calling session needs to narrate the outcome; everything else went to
# stderr and the log. Silent in actions mode, and for the status event,
# which emits its own final line. (#95)
emit_orchestrator_result() {
    local exit_code="${1:-0}"
    [ "${AGENT_EXECUTION_MODE:-actions}" = "orchestrator" ] || return 0
    [ "$EVENT_TYPE" = "status" ] && return 0
    local outcome="$DISPATCH_OUTCOME"
    if [ -z "$outcome" ]; then
        if [ -n "$DISPATCH_LOCK_REFUSED" ]; then
            outcome="lock-refused"
        elif [ "$exit_code" -eq 0 ]; then
            outcome="success"
        else
            outcome="error"
        fi
    fi
    jq -cn --arg event "$EVENT_TYPE" --arg repo "$REPO" --arg issue "$NUMBER" \
           --arg outcome "$outcome" --arg ec "$exit_code" --arg pr "$DISPATCH_PR_URL" \
           --arg started "${DISPATCH_STARTED:-}" --arg finished "$(_utc_now)" \
        '{event: $event, repo: $repo, issue: $issue, outcome: $outcome,
          exit_code: ($ec | tonumber), pr_url: $pr,
          started: $started, finished: $finished}'
}

# Read-only status: reports the lock (live or stale) and the last
# dispatch outcome. Deliberately mutates nothing — it does not clean up
# a dead lock (the next dispatch reclaims it) and never touches the
# last-dispatch record of the run being asked about. The final line of
# stdout is a compact JSON object; everything before it is for humans.
handle_status() {
    local lock last stale="null" lock_json="null" last_json="null"
    lock=$(_lock_path)
    last=$(_last_dispatch_path)

    if [ -f "$lock" ]; then
        local held_pid held_host
        held_pid=$(jq -r '.pid // empty' "$lock" 2>/dev/null)
        held_host=$(jq -r '.host // empty' "$lock" 2>/dev/null)
        if [ "$held_host" != "$(hostname)" ]; then
            stale='"unknown"'
            log "status: lock held on another host (${held_host:-unknown}) — cannot check its pid"
        elif [ -n "$held_pid" ] && ps -p "$held_pid" >/dev/null 2>&1; then
            stale="false"
            log "status: dispatch ALIVE — pid ${held_pid}, phase $(jq -r '.phase // "?"' "$lock"), since $(jq -r '.updated // "?"' "$lock")"
        else
            stale="true"
            log "status: lock is STALE (pid ${held_pid:-unknown} is dead) — the next dispatch will reclaim it"
        fi
        lock_json=$(jq -c --argjson s "$stale" '. + {stale: $s}' "$lock" 2>/dev/null || echo "null")
    else
        log "status: no dispatch in flight for #${NUMBER}"
    fi

    if [ -f "$last" ]; then
        last_json=$(jq -c '.' "$last" 2>/dev/null || echo "null")
    fi

    jq -cn --arg repo "$REPO" --arg issue "$NUMBER" \
        --argjson lock "$lock_json" --argjson last "$last_json" \
        '{event: "status", repo: $repo, issue: $issue, lock: $lock, last_dispatch: $last}'
}
