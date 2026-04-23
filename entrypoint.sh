#!/bin/bash
set -e

# Allow core dumps
ulimit -c unlimited 2>/dev/null || true

# Always load the crash handler — prints backtrace on SIGTRAP/SIGABRT/SIGSEGV
# with zero performance overhead (signal handler only fires on crash).
export LD_PRELOAD="/usr/local/lib/crash_handler.so"

if [[ "${RUN_WITH_GDB:-false}" == "true" ]]; then
    echo "[entrypoint] Starting FrankenPHP under gdb"
    echo "[entrypoint] WARNING: gdb limits thread count and slows execution significantly"
    unset LD_PRELOAD  # gdb handles signals itself

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
    echo "[entrypoint] Starting FrankenPHP with crash handler (LD_PRELOAD)"
    exec frankenphp run --config /etc/caddy/Caddyfile
fi
