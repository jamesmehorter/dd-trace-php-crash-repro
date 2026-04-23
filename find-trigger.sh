#!/usr/bin/env bash
set -euo pipefail

# Systematically tests different burst/idle patterns to find the simplest crash trigger.
# The pattern is: BURST → WAIT → BURST → WAIT → BURST ...

APP_URL="${APP_URL:-http://localhost:8080}"
CONTAINER="dd-trace-php-crash-repro-app-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

test_pattern() {
    local reqs=$1 conc=$2 idle=$3 max_bursts=$4
    local label="ab -n${reqs} -c${conc}, ${idle}s idle"

    docker compose down -t 2 > /dev/null 2>&1
    docker compose up -d app datadog-agent > /dev/null 2>&1
    sleep 5

    # Verify it's running
    if ! curl -sf --max-time 5 "$APP_URL/health" > /dev/null 2>&1; then
        log "${RED}App didn't start${NC}"
        return 2
    fi

    local start_time=$(date +%s)

    for burst in $(seq 1 "$max_bursts"); do
        ab -n "$reqs" -c "$conc" "$APP_URL/" > /dev/null 2>&1 || true

        local status
        status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
        if [[ "$status" != "running" ]]; then
            local elapsed=$(( $(date +%s) - start_time ))
            local exit_code
            exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "?")
            log "${RED}CRASHED${NC} — ${label} — burst ${burst}, ${elapsed}s (exit ${exit_code})"
            return 0
        fi

        if (( idle > 0 )); then
            sleep "$idle"
        fi

        status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
        if [[ "$status" != "running" ]]; then
            local elapsed=$(( $(date +%s) - start_time ))
            local exit_code
            exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "?")
            log "${RED}CRASHED${NC} — ${label} — during idle after burst ${burst}, ${elapsed}s (exit ${exit_code})"
            return 0
        fi
    done

    local elapsed=$(( $(date +%s) - start_time ))
    log "${GREEN}SURVIVED${NC} — ${label} — ${max_bursts} bursts, ${elapsed}s"
    return 1
}

log "${YELLOW}Finding the simplest crash trigger...${NC}"
echo

# Test different patterns — vary requests, concurrency, and idle time
# Format: requests concurrency idle_seconds max_bursts

# Does idle matter?
log "--- Does idle time matter? ---"
test_pattern 5000 200 0  10 || true   # No idle
test_pattern 5000 200 2  10 || true   # 2s idle
test_pattern 5000 200 5  10 || true   # 5s idle
test_pattern 5000 200 10 10 || true   # 10s idle
echo

# Does concurrency matter?
log "--- Does concurrency matter? ---"
test_pattern 5000 10  5 10 || true    # Low concurrency
test_pattern 5000 50  5 10 || true    # Medium
test_pattern 5000 100 5 10 || true    # High
test_pattern 5000 200 5 10 || true    # Very high
echo

# Does request count matter?
log "--- Does request volume matter? ---"
test_pattern 100  200 5 10 || true    # Tiny bursts
test_pattern 500  200 5 10 || true    # Small bursts
test_pattern 2000 200 5 10 || true    # Medium bursts
test_pattern 10000 200 5 10 || true   # Large bursts
echo

# Minimal pattern
log "--- Minimal trigger? ---"
test_pattern 100 50 2 20 || true      # Small + low concurrency + short idle
test_pattern 100 100 1 20 || true     # Tiny burst, high concurrency, 1s idle

docker compose down -t 2 > /dev/null 2>&1
log "Done."
