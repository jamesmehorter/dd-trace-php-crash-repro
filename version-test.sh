#!/usr/bin/env bash
set -euo pipefail

# Tests whether a specific dd-trace-php version crashes under concurrent load.
# Usage: ./version-test.sh [version]
# Example: ./version-test.sh 1.18.0
#          ./version-test.sh 1.16.0
#
# Prerequisites: docker, docker compose, ab (apache2-utils on Linux)

VERSION="${1:-1.18.0}"
TIMEOUT_SEC=180
CONCURRENCY=200
REQUESTS=5000
IDLE_SEC=5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

# Resolve container ID dynamically (works regardless of clone directory name)
get_container() {
    docker compose ps -aq app 2>/dev/null | head -1
}

check_crashed() {
    local cid
    cid=$(get_container)
    if [[ -z "$cid" ]]; then
        return 0  # container gone = crashed
    fi
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "missing")
    [[ "$status" != "running" ]]
}

get_exit_code() {
    local cid
    cid=$(get_container)
    docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo "?"
}

show_crash_logs() {
    local cid
    cid=$(get_container)
    [[ -n "$cid" ]] && docker logs --tail 5 "$cid" 2>&1
}

# Check prerequisites
if ! command -v ab > /dev/null 2>&1; then
    echo "Error: 'ab' (Apache Bench) is required. Install with:"
    echo "  macOS: already installed"
    echo "  Linux: apt-get install apache2-utils"
    exit 1
fi

log "${YELLOW}Testing dd-trace-php ${VERSION}${NC} (timeout ${TIMEOUT_SEC}s)"

# Rebuild with the specified version
docker compose down -t 5 > /dev/null 2>&1
docker compose build --no-cache --build-arg DD_TRACE_VERSION="$VERSION" app > /dev/null 2>&1
docker compose up -d app datadog-agent > /dev/null 2>&1

# Wait for ready
for i in $(seq 1 30); do
    curl -sf --max-time 5 http://localhost:8080/health > /dev/null 2>&1 && break
    sleep 1
done

# Confirm version
ACTUAL=$(curl -sf http://localhost:8080/ 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['extensions']['ddtrace'])" 2>/dev/null || echo "unknown")
log "Confirmed ddtrace version: ${ACTUAL}"

if [[ "$ACTUAL" != "$VERSION" ]]; then
    log "${RED}Version mismatch! Expected $VERSION, got $ACTUAL${NC}"
    docker compose down -t 5 > /dev/null 2>&1
    exit 1
fi

# Run burst-then-idle until crash or timeout
START_TIME=$(date +%s)
ROUND=1
CRASHED=false

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if (( ELAPSED >= TIMEOUT_SEC )); then
        break
    fi

    log "Burst $ROUND..."
    ab -n "$REQUESTS" -c "$CONCURRENCY" http://localhost:8080/ 2>&1 | grep -E "Complete req|Failed|Requests per" || true

    if check_crashed; then
        ELAPSED=$(( $(date +%s) - START_TIME ))
        log "${RED}CRASHED${NC} after ${ELAPSED}s (exit code $(get_exit_code))"
        show_crash_logs
        CRASHED=true
        break
    fi

    log "Idle ${IDLE_SEC}s..."
    sleep "$IDLE_SEC"

    if check_crashed; then
        ELAPSED=$(( $(date +%s) - START_TIME ))
        log "${RED}CRASHED${NC} during idle after burst ${ROUND}, ${ELAPSED}s (exit code $(get_exit_code))"
        show_crash_logs
        CRASHED=true
        break
    fi

    ROUND=$((ROUND + 1))
done

ELAPSED=$(( $(date +%s) - START_TIME ))

if [[ "$CRASHED" == "true" ]]; then
    log "${RED}RESULT: dd-trace-php ${VERSION} CRASHED after ${ELAPSED}s${NC}"
    docker compose down -t 5 > /dev/null 2>&1
    exit 133
else
    log "${GREEN}RESULT: dd-trace-php ${VERSION} SURVIVED ${TIMEOUT_SEC}s (${ROUND} bursts)${NC}"
    docker compose down -t 5 > /dev/null 2>&1
    exit 0
fi
