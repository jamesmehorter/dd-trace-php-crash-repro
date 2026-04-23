# dd-trace-php Crash Reproducer

dd-trace-php 1.17.0+ crashes under normal traffic. Install it, send requests, process dies. No special configuration, no edge case, no unusual load pattern — just a PHP application serving concurrent requests with dd-trace-php active.

This repo reproduces the crash in seconds with a trivial PHP script. No framework, no database, no application code.

**Related issues:**
- [dd-trace-php #3729](https://github.com/DataDog/dd-trace-php/issues/3729) — heap corruption on FrankenPHP (open)
- [dd-trace-php #3414](https://github.com/DataDog/dd-trace-php/issues/3414) — unrealistic memory allocations (open)
- [FrankenPHP #2280](https://github.com/php/frankenphp/issues/2280) — flagged as likely datadog-related (open)

## The Problem

dd-trace-php 1.17.0+ corrupts memory during normal concurrent request handling, then crashes with:

```
memory allocation of 3420891154821048684 bytes failed   (exit code 133 / SIGABRT)
```

The allocation size (~3.4 exabytes) is a corrupted pointer being read as a size — heap corruption in dd-trace-php's Rust internals (libdatadog).

This is not an edge case. The crash requires nothing more than concurrent HTTP requests to a PHP application with dd-trace-php loaded. Concurrency as low as 10 triggers it. It reproduces on a trivial PHP script that does nothing but write a temp file and return JSON.

**1.16.0 is stable. 1.17.0+ crashes.**

> **Scope:** Confirmed on FrankenPHP + PHP 8.4 ZTS. Other reporters on [#3729](https://github.com/DataDog/dd-trace-php/issues/3729) have seen this on PHP-FPM (8.3 NTS) and Symfony worker mode (8.2 ZTS) as well. We have not tested those configurations with this reproducer.

## Prerequisites

- Docker and Docker Compose
- `ab` (Apache Bench) — pre-installed on macOS; on Linux: `apt-get install apache2-utils`

## How to Reproduce

### One command

```bash
git clone https://github.com/jamesmehorter/dd-trace-php-crash-repro.git
cd dd-trace-php-crash-repro
docker compose up -d --build
ab -n 5000 -c 200 http://localhost:8080/
```

The container dies mid-request. Check with `docker compose ps` — the app container has exited with code 133.

### Automated A/B version test

```bash
./version-test.sh 1.18.0   # crashes in seconds
./version-test.sh 1.16.0   # survives indefinitely
```

This script builds a specific dd-trace-php version, starts the stack, runs the load, and reports CRASHED or SURVIVED.

### What the setup is

- FrankenPHP (PHP 8.4 ZTS, 20 threads) serving a trivial PHP script
- dd-trace-php installed with appsec and profiling
- A Datadog Agent sidecar receiving traces
- `ab` sending concurrent requests from the host

That's it. The PHP script writes a temp file, serializes JSON, and returns. No framework, no database, no middleware.

> **Note:** The Datadog Agent sidecar is included because dd-trace-php sends traces to it. The crash is in dd-trace-php's client-side code, not in the agent.

### What we learned about the trigger

| Variation | Result |
|---|---|
| Concurrency 10 | **CRASHED** |
| Concurrency 200 | **CRASHED** |
| 500+ requests | **CRASHED** |
| 100 requests | Survived (not enough to trigger) |

Concurrency level barely matters. The only variable is request volume — ~500+ requests reliably crashes.

### Version comparison

| Version | Result |
|---|---|
| **1.18.0** | **CRASHED** — seconds |
| **1.16.0** | Survived 180s — 14 bursts, 140K requests, zero failures |

### Crash output

```
memory allocation of 3420891154821048684 bytes failed
memory allocation of 3420891154821048684 bytes failed

=== CRASH HANDLER ===
Signal: 6
Backtrace (3 frames):
/usr/local/lib/crash_handler.so(+0x7a4) [0xffff840e07a4]
linux-vdso.so.1(__kernel_rt_sigreturn+0x0) [0xffff841427d0]
frankenphp() [0x48c368]
=== END CRASH HANDLER ===
```

Signal 6 (SIGABRT) from Rust's `alloc::handle_alloc_error` → `std::process::abort()`. The backtrace is shallow because FrankenPHP is a statically-linked Go binary.

> **Heisenbug note:** Replacing `ddtrace.so` with the debug-symbol build (`ddtrace-debug.so` from the release assets) shifts the memory layout enough to prevent the crash. The Datadog team will need to capture the full backtrace with their internal tooling (e.g., ASAN build or instrumented allocator).

## Environment

- **Image:** `dunglas/frankenphp:php8.4-trixie`
- **PHP:** 8.4 ZTS (Zend Thread Safe)
- **FrankenPHP threads:** 20 (`num_threads` in Caddyfile)
- **dd-trace-php:** installed with `--enable-appsec --enable-profiling`
- **Tested on:** macOS ARM64 (Docker Desktop) and ECS Fargate (Linux ARM64)
- **Not tested:** x86_64, PHP 8.3 ZTS, NTS builds, php-fpm

## Repo Contents

| File | Purpose |
|---|---|
| `version-test.sh` | Automated A/B version test — builds, loads, reports crash or survive |
| `Dockerfile` | FrankenPHP + dd-trace-php (version via `DD_TRACE_VERSION` build arg) + crash handler |
| `docker-compose.yml` | App + Datadog Agent sidecar |
| `Caddyfile` | 20 FrankenPHP threads, `/health` handled by Caddy (never reaches PHP) |
| `public/index.php` | Trivial PHP script — file I/O + JSON serialization |
| `crash_handler.c` | LD_PRELOAD signal handler — prints backtrace on crash, zero runtime overhead |
| `entrypoint.sh` | Starts FrankenPHP with crash handler (or gdb via `RUN_WITH_GDB=true`) |
| `investigation/` | Scripts used during trigger analysis (`burst-test.sh`, `find-trigger.sh`, `test.sh`) |

## Env Vars We've Tried (None Fixed It)

All set simultaneously on an ECS task running 1.18.0. It still crashed.

| Variable | Value | Result |
|---|---|---|
| `DD_TRACE_SIDECAR_TRACE_SENDER` | `false` | Still crashes |
| `DD_INSTRUMENTATION_TELEMETRY_ENABLED` | `false` | Still crashes |
| `DD_APPSEC_ENABLED` | `false` | Still crashes |
| `DD_TRACE_LOG_LEVEL` | `debug` | Still crashes |
| All four combined | — | Still crashes |

The only fix is pinning to 1.16.0.

## TODO

- [ ] Test 1.17.0 explicitly to confirm it's the first broken release
- [ ] Test without `--enable-appsec` to isolate whether libddwaf is involved
- [ ] Test without `--enable-profiling` to isolate whether the profiler is involved
- [ ] Test on x86_64
- [ ] Test on PHP 8.3 ZTS
- [ ] Test whether crash reproduces without the Datadog Agent sidecar
