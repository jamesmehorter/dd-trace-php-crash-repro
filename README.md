# dd-trace-php FrankenPHP Crash Reproducer

Minimal reproducer for a memory corruption crash in dd-trace-php's Rust internals (libdatadog/libddwaf) when running inside FrankenPHP.

Related issues:
- [dd-trace-php #3729](https://github.com/DataDog/dd-trace-php/issues/3729) — heap corruption on FrankenPHP
- [dd-trace-php #3414](https://github.com/DataDog/dd-trace-php/issues/3414) — unrealistic memory allocations
- [FrankenPHP #2280](https://github.com/php/frankenphp/issues/2280) — flagged as likely datadog-related

## The Bug

After a period of PHP inactivity, the first real PHP request triggers a crash:

```
memory allocation of 281471287409328 bytes failed   (exit code 133 / SIGTRAP)
```

The allocation sizes are corrupted pointer values (~256 TB on ARM64) — a struct field is being read as a size after memory corruption across the Rust/PHP FFI boundary.

Key conditions:
- FrankenPHP + PHP 8.4 ZTS
- dd-trace-php 1.17.1 and 1.18.0 (multiple users report 1.16.0 is stable)
- Container receives Caddy-level health checks that never reach PHP, so dd-trace-php's sidecar is idle even though the container looks healthy
- Shortest observed idle-to-crash window: ~45 minutes

## Quick Start

```bash
docker compose up -d --build
./test.sh
```

## Debugging a Crash

The app runs under **gdb** by default. When the crash happens, the container logs will contain a full backtrace with `thread apply all bt full`. This is what the Datadog team has been asking for to diagnose the root cause.

```bash
# Watch for the crash
IDLE_MINUTES=45 LOOP=true ./test.sh

# After a crash, grab the gdb backtrace from the logs
docker logs dd-trace-php-crash-repro-app-1 2>&1 | tee crash-backtrace.txt
```

To run without gdb (normal mode):

```bash
RUN_WITH_GDB=false docker compose up -d --build
```

## Configuration

Environment variables for `test.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `IDLE_MINUTES` | `5` | Minutes to idle between PHP requests |
| `HEALTH_INTERVAL` | `30` | Seconds between /health pings during idle |
| `LOOP` | `false` | Run cycles continuously |
| `APP_URL` | `http://localhost:8080` | App base URL |
| `CONTAINER_NAME` | `dd-trace-php-crash-repro-app-1` | Docker container name to inspect |

## What's in the box

- **Dockerfile** — FrankenPHP + dd-trace-php + gdb for crash capture
- **Caddyfile** — `/health` at Caddy level (never reaches PHP), everything else via `php_server`
- **public/index.php** — Trivial JSON response with dd-trace extension versions
- **docker-compose.yml** — App (with SYS_PTRACE for gdb) + Datadog Agent
- **entrypoint.sh** — Wraps FrankenPHP in gdb to capture backtrace on crash
- **test.sh** — Automated idle-then-request cycle with crash detection

## Env Vars We've Tried (None Fixed It)

| Change | Result |
|---|---|
| `DD_TRACE_SIDECAR_TRACE_SENDER=false` | Still crashes |
| `DD_INSTRUMENTATION_TELEMETRY_ENABLED=false` | Still crashes |
| `DD_APPSEC_ENABLED=false` | Testing |
