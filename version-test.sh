#!/usr/bin/env bash
set -euo pipefail

# Tests whether a specific dd-trace-php version crashes under concurrent load.
# Usage: ./version-test.sh [version]
# Example: ./version-test.sh 1.18.0
#          ./version-test.sh 1.16.0

VERSION="${1:-1.18.0}"
TIMEOUT_SEC=180
CONCURRENCY=200
REQUESTS=10000
IDLE_SEC=10
CONTAINER="dd-trace-php-crash-repro-app-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

log "${YELLOW}Testing dd-trace-php ${VERSION}${NC} (timeout ${TIMEOUT_SEC}s)"

# Rebuild with the specified version
export DD_TRACE_VERSION="$VERSION"
docker compose down -t 5 > /dev/null 2>&1

# Temporarily override the build arg
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

    # Check if crashed
    STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
    if [[ "$STATUS" != "running" ]]; then
        EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "?")
        ELAPSED=$(( $(date +%s) - START_TIME ))
        log "${RED}CRASHED${NC} after ${ELAPSED}s (exit code ${EXIT_CODE})"
        docker logs --tail 5 "$CONTAINER" 2>&1
        CRASHED=true
        break
    fi

    log "Idle ${IDLE_SEC}s..."
    sleep "$IDLE_SEC"
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
