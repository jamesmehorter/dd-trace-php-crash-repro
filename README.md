# dd-trace-php Crash Reproducer

dd-trace-php 1.17.0+ crashes PHP processes with corrupted memory allocations and SIGABRT. This repo reproduces the crash in under 10 seconds with no application framework — just FrankenPHP, dd-trace-php, and a trivial PHP script.

**Related issues:**
- [dd-trace-php #3729](https://github.com/DataDog/dd-trace-php/issues/3729) — heap corruption on FrankenPHP (open)
- [dd-trace-php #3414](https://github.com/DataDog/dd-trace-php/issues/3414) — unrealistic memory allocations (open)
- [FrankenPHP #2280](https://github.com/php/frankenphp/issues/2280) — flagged as likely datadog-related (open)

## The Problem

When dd-trace-php 1.17.0+ runs inside FrankenPHP (PHP 8.4 ZTS), concurrent requests cause memory corruption in dd-trace-php's Rust internals (libdatadog), crashing the process:

```
memory allocation of 3420891154821048684 bytes failed   (exit code 133 / SIGABRT)
```

The allocation size (~3.4 exabytes) is a corrupted pointer value being read as a size.

**The trigger is concurrent requests through dd-trace-php's instrumentation hooks across FrankenPHP's PHP threads.** No special timing, idle periods, or traffic patterns required — just enough concurrent requests (~500+) with dd-trace-php active.

**1.16.0 is stable. 1.17.0+ crashes.**

> **Scope:** Confirmed on FrankenPHP + PHP 8.4 ZTS. Other reporters on [#3729](https://github.com/DataDog/dd-trace-php/issues/3729) have seen this on PHP-FPM (8.3 NTS) and Symfony worker mode (8.2 ZTS) as well. We have not tested those configurations with this reproducer.

## Prerequisites

- Docker and Docker Compose
- `ab` (Apache Bench) — pre-installed on macOS; on Linux: `apt-get install apache2-utils`

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
2. Sends `ab -n 5000 -c 200` in bursts with 5s gaps
3. Checks if the container crashed (exit code 133)

No framework, no database. Just concurrent requests to a trivial PHP script with dd-trace-php active.

> **Note:** The Datadog Agent sidecar is included because dd-trace-php sends traces to it — removing the agent changes the code path and may affect reproducibility. The crash is in dd-trace-php's client-side code, not in the agent.

### What we learned about the trigger

| Variation | Result |
|---|---|
| Concurrency 10 | **CRASHED** |
| Concurrency 200 | **CRASHED** |
| Zero idle between bursts | **CRASHED** |
| 500+ requests per burst | **CRASHED** |
| 100 requests per burst | Survived (not enough to trigger) |

Concurrency level barely matters. Idle time doesn't matter at all. The only variable that affects reproducibility is request volume — ~500+ requests reliably crashes, ~100 sometimes survives.

### Version comparison

| Version | Result |
|---|---|
| **1.18.0** | **CRASHED** — under 10s |
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

Signal 6 (SIGABRT) from Rust's `alloc::handle_alloc_error` → `std::process::abort()`. The backtrace is shallow because FrankenPHP is a statically-linked Go binary — `backtrace()` can't unwind through Go's stack frames.

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
| `version-test.sh` | **Start here.** Builds a specific dd-trace-php version, runs load, reports crash or survive |
| `Dockerfile` | FrankenPHP + dd-trace-php (version via `DD_TRACE_VERSION` build arg) + crash handler |
| `docker-compose.yml` | App + Datadog Agent sidecar |
| `Caddyfile` | 20 FrankenPHP threads, `/health` handled by Caddy (never reaches PHP) |
| `public/index.php` | Trivial PHP script — file I/O + JSON serialization |
| `crash_handler.c` | LD_PRELOAD signal handler — prints backtrace on crash, zero runtime overhead |
| `entrypoint.sh` | Starts FrankenPHP with crash handler (or gdb via `RUN_WITH_GDB=true`) |
| `investigation/` | Scripts used during our trigger analysis (`burst-test.sh`, `find-trigger.sh`, `test.sh`) |

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
