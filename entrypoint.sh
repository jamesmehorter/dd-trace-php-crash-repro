#!/bin/bash
set -e

# Allow core dumps
ulimit -c unlimited 2>/dev/null || true

if [[ "${RUN_WITH_GDB:-true}" == "true" ]]; then
    echo "[entrypoint] Starting FrankenPHP under gdb (will capture backtrace on crash)"
    echo "[entrypoint] gdb output will appear in container logs"

    # gdb runs frankenphp, catches signals, prints backtrace, then exits
    exec gdb -batch \
        -ex "set confirm off" \
        -ex "set pagination off" \
        -ex "handle SIGTERM nostop pass" \
        -ex "handle SIGINT nostop pass" \
        -ex "handle SIGUSR1 nostop pass" \
        -ex "handle SIGUSR2 nostop pass" \
        -ex "run" \
        -ex "echo \n=== CRASH DETECTED ===\n" \
        -ex "echo Signal: \n" \
        -ex "info signal" \
        -ex "echo \n=== BACKTRACE (current thread) ===\n" \
        -ex "bt full" \
        -ex "echo \n=== ALL THREADS ===\n" \
        -ex "thread apply all bt full" \
        -ex "echo \n=== REGISTERS ===\n" \
        -ex "info registers" \
        -ex "echo \n=== MEMORY MAP ===\n" \
        -ex "info proc mappings" \
        -ex "quit 133" \
        --args frankenphp run --config /etc/caddy/Caddyfile
else
    echo "[entrypoint] Starting FrankenPHP directly (core dumps to /tmp/core.*)"
    echo "[entrypoint] After crash: docker cp <container>:/tmp/core.* . && gdb frankenphp core.*"
    exec frankenphp run --config /etc/caddy/Caddyfile
fi
