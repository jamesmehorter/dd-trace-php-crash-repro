#!/usr/bin/env bash
set -euo pipefail

# Reproducer for dd-trace-php crash in FrankenPHP after PHP idle period.
#
# The crash is a memory allocation failure in dd-trace-php's Rust sidecar
# (libdatadog/libddwaf) with corrupted pointer values (~256 TB), exit code
# 133 (SIGTRAP). It happens on the first real PHP request after the sidecar's
# internal connections have gone stale from inactivity.

APP_URL="${APP_URL:-http://localhost:8080}"
IDLE_MINUTES="${IDLE_MINUTES:-5}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-30}"
LOOP="${LOOP:-false}"
CONTAINER_NAME="${CONTAINER_NAME:-dd-trace-php-crash-repro-app-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

check_container() {
    local state exit_code
    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "?")

    if [[ "$state" != "running" ]]; then
        log "${RED}CRASH DETECTED${NC} - container status: $state, exit code: $exit_code"
        log "Last 50 lines of container logs:"
        docker logs --tail 50 "$CONTAINER_NAME" 2>&1
        return 1
    fi
    return 0
}

send_php_request() {
    local label="$1"
    log "Sending PHP request ($label)..."
    local response
    if response=$(curl -sf --max-time 10 "$APP_URL/" 2>&1); then
        log "${GREEN}OK${NC} - $response"
        return 0
    else
        log "${RED}FAILED${NC} - $response"
        return 1
    fi
}

health_check_loop() {
    local duration=$1
    local elapsed=0
    while (( elapsed < duration )); do
        sleep "$HEALTH_INTERVAL"
        elapsed=$(( elapsed + HEALTH_INTERVAL ))
        local remaining=$(( duration - elapsed ))
        curl -sf --max-time 5 "$APP_URL/health" > /dev/null 2>&1 && \
            log "  /health OK (${remaining}s remaining)" || \
            log "${YELLOW}  /health FAILED${NC}"

        if ! check_container; then
            return 1
        fi
    done
    return 0
}

run_cycle() {
    local cycle="$1"
    log "=== Cycle $cycle ==="

    # Confirm container is alive
    if ! check_container; then
        log "Container not running. Aborting."
        return 1
    fi

    # Send initial request to activate dd-trace
    if ! send_php_request "pre-idle"; then
        check_container
        return 1
    fi

    # Idle period - only health checks reach Caddy, PHP stays idle
    local idle_seconds=$(( IDLE_MINUTES * 60 ))
    log "Entering ${IDLE_MINUTES}m idle period (health checks every ${HEALTH_INTERVAL}s)..."
    if ! health_check_loop "$idle_seconds"; then
        return 1
    fi

    # The critical request - first PHP hit after idle
    log "${YELLOW}Sending post-idle PHP request (this is where crashes happen)...${NC}"
    if ! send_php_request "post-idle"; then
        check_container
        return 1
    fi

    if ! check_container; then
        return 1
    fi

    log "${GREEN}Cycle $cycle completed - no crash${NC}"
    return 0
}

# --- Main ---

log "dd-trace-php FrankenPHP crash reproducer"
log "Config: idle=${IDLE_MINUTES}m, health_interval=${HEALTH_INTERVAL}s, loop=${LOOP}"
log "Container: $CONTAINER_NAME"
echo

# Wait for app to be ready
log "Waiting for app to start..."
for i in $(seq 1 30); do
    if curl -sf --max-time 5 "$APP_URL/health" > /dev/null 2>&1; then
        log "${GREEN}App is ready${NC}"
        break
    fi
    if (( i == 30 )); then
        log "${RED}App did not start within 30s${NC}"
        exit 1
    fi
    sleep 1
done
echo

if [[ "$LOOP" == "true" ]]; then
    cycle=1
    while true; do
        if ! run_cycle "$cycle"; then
            log "${RED}Crash reproduced on cycle $cycle${NC}"
            exit 133
        fi
        cycle=$(( cycle + 1 ))
        echo
    done
else
    if ! run_cycle 1; then
        log "${RED}Crash reproduced${NC}"
        exit 133
    fi
    log "Single cycle complete. Run with LOOP=true for continuous testing."
    log "Shortest observed crash window in production: ~45 minutes."
    log "Try: IDLE_MINUTES=45 LOOP=true ./test.sh"
fi
