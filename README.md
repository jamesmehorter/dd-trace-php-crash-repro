# dd-trace-php Crash Reproducer

dd-trace-php 1.17.0+ crashes PHP processes with corrupted memory allocations and SIGABRT. This repo reproduces the crash in under 10 seconds with no application framework — just FrankenPHP, dd-trace-php, and a trivial PHP script.

**Related issues:**
- [dd-trace-php #3729](https://github.com/DataDog/dd-trace-php/issues/3729) — heap corruption on FrankenPHP (open)
- [dd-trace-php #3414](https://github.com/DataDog/dd-trace-php/issues/3414) — unrealistic memory allocations (open)
- [FrankenPHP #2280](https://github.com/php/frankenphp/issues/2280) — flagged as likely datadog-related (open)

## The Problem

When dd-trace-php 1.17.0+ runs inside FrankenPHP (PHP 8.4 ZTS), the process crashes with:

```
memory allocation of 3420891154821048684 bytes failed   (exit code 133 / SIGABRT)
```

The allocation size (~3.4 exabytes) is a corrupted pointer value being read as a size — memory corruption in dd-trace-php's Rust internals (libdatadog). The corruption occurs during concurrent PHP request handling where multiple threads interact with dd-trace-php simultaneously.

**1.16.0 is stable. 1.17.0+ crashes.**

## How to Reproduce

```bash
git clone https://github.com/jamesmehorter/dd-trace-php-crash-repro.git
cd dd-trace-php-crash-repro

# Crashes in ~10 seconds
./version-test.sh 1.18.0

# Survives indefinitely
./version-test.sh 1.16.0
```

### What the test does

1. Builds FrankenPHP (PHP 8.4 ZTS, 20 threads) with dd-trace-php (appsec + profiling) and a Datadog Agent sidecar
2. Sends concurrent HTTP requests using `ab`
3. Checks if the container crashed

That's it. No framework, no database, no special timing. Just concurrent requests to a trivial PHP script with dd-trace-php active.

### Crash trigger analysis

We tested variations of request count, concurrency, and idle time to find the minimal trigger:

| Pattern | Result |
|---|---|
| `ab -n 5000 -c 10` | **CRASHED** — burst 1 |
| `ab -n 5000 -c 200, 0s idle` | **CRASHED** — burst 1, 1s |
| `ab -n 500 -c 200` | **CRASHED** — burst 2, 6s |
| `ab -n 100 -c 50, 2s idle` | **CRASHED** — burst 17, 34s |
| `ab -n 100 -c 200` | Survived 10 bursts |
| `ab -n 100 -c 100, 1s idle` | Survived 20 bursts |

**Findings:**
- **Idle time doesn't matter** — crashes with zero idle between bursts
- **Low concurrency is enough** — crashes at concurrency 10
- **~500+ requests needed** — 100 requests sometimes survives, 500+ reliably crashes
- The trigger is simply: enough concurrent requests flowing through dd-trace-php's instrumentation hooks across FrankenPHP's threads

### Version comparison

| Version | Result |
|---|---|
| **1.18.0** | **CRASHED after 24s** |
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

Signal 6 (SIGABRT) from Rust's `alloc::handle_alloc_error` → `std::process::abort()`. The backtrace is shallow because FrankenPHP is a statically-linked Go binary. A debug-symbol build of dd-trace-php shifts the memory layout enough to prevent the crash (Heisenbug), so the Datadog team will need to capture the full backtrace with their internal tooling.

## Environment

- **Image:** `dunglas/frankenphp:php8.4-trixie`
- **PHP:** 8.4 ZTS (Zend Thread Safe)
- **FrankenPHP threads:** 20 (`num_threads` in Caddyfile)
- **dd-trace-php:** installed with `--enable-appsec --enable-profiling`
- **Tested on:** macOS ARM64 (Docker Desktop) and ECS Fargate (Linux ARM64)

## What's in the Box

| File | Purpose |
|---|---|
| `Dockerfile` | FrankenPHP + dd-trace-php (version via build arg) + crash handler |
| `Caddyfile` | 20 threads, `/health` at Caddy level (never reaches PHP) |
| `public/index.php` | Trivial PHP script — file I/O + JSON serialization |
| `docker-compose.yml` | App + Datadog Agent sidecar |
| `crash_handler.c` | LD_PRELOAD signal handler — prints backtrace on crash |
| `entrypoint.sh` | Starts FrankenPHP with crash handler (or gdb via `RUN_WITH_GDB=true`) |
| `version-test.sh` | Automated A/B test — builds specific version, runs load, reports result |
| `burst-test.sh` | Continuous burst-then-idle load pattern |
| `find-trigger.sh` | Systematically tests timing/concurrency variations |
| `test.sh` | Idle-cycle test (alternative reproduction path) |

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
