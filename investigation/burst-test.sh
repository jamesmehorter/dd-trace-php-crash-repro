#!/usr/bin/env bash
set -euo pipefail

# Burst-then-idle pattern: hammers with concurrent requests, pauses briefly,
# repeats. Mimics real traffic (user activity → idle → user returns).
# This is how other reporters reproduced the crash quickly.

APP_URL="${APP_URL:-http://localhost:8080}"
CONCURRENCY="${CONCURRENCY:-200}"
REQUESTS="${REQUESTS:-10000}"
IDLE_SECONDS="${IDLE_SECONDS:-30}"
CONTAINER="${CONTAINER:-dd-trace-php-crash-repro-app-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

check_alive() {
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
    if [[ "$status" != "running" ]]; then
        local exit_code
        exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "?")
        log "${RED}CRASH DETECTED${NC} — status: $status, exit code: $exit_code"
        log "Container logs:"
        docker logs --tail 30 "$CONTAINER" 2>&1
        return 1
    fi
    return 0
}

log "Burst-then-idle crash test"
log "Config: ${REQUESTS} requests @ concurrency ${CONCURRENCY}, ${IDLE_SECONDS}s idle between bursts"
echo

# Wait for ready
for i in $(seq 1 30); do
    curl -sf --max-time 5 "$APP_URL/health" > /dev/null 2>&1 && break
    sleep 1
done

round=1
while true; do
    log "${YELLOW}=== Burst $round ===${NC}"

    if ! check_alive; then exit 133; fi

    ab -n "$REQUESTS" -c "$CONCURRENCY" "$APP_URL/" 2>&1 | grep -E "Complete req|Failed|Requests per|Non-2xx"

    if ! check_alive; then exit 133; fi

    log "Idle ${IDLE_SECONDS}s..."
    sleep "$IDLE_SECONDS"

    if ! check_alive; then exit 133; fi

    log "${GREEN}Burst $round done${NC}"
    round=$((round + 1))
    echo
done
