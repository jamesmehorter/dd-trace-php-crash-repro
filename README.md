# dd-trace-php Crash Reproducer

dd-trace-php 1.17.0+ crashes PHP processes with corrupted memory allocations and SIGABRT. This repo reproduces the crash in under 30 seconds with no application framework — just FrankenPHP, dd-trace-php, and a trivial PHP script.

**Related issues:**
- [dd-trace-php #3729](https://github.com/DataDog/dd-trace-php/issues/3729) — heap corruption on FrankenPHP (open)
- [dd-trace-php #3414](https://github.com/DataDog/dd-trace-php/issues/3414) — unrealistic memory allocations (open)
- [FrankenPHP #2280](https://github.com/php/frankenphp/issues/2280) — flagged as likely datadog-related (open)

## The Problem

When dd-trace-php 1.17.0+ runs inside FrankenPHP (PHP 8.4 ZTS), the process crashes with:

```
memory allocation of 3420891154821048684 bytes failed   (exit code 133 / SIGABRT)
```

The allocation size (~3.4 exabytes) is a corrupted pointer value being read as a size — memory corruption in dd-trace-php's Rust internals (libdatadog). The crash happens during concurrent PHP request handling where multiple threads interact with dd-trace-php's sidecar connection simultaneously.

**1.16.0 is stable. 1.17.0+ crashes.** We verified this with a clean A/B test — same image, same load, only the dd-trace-php version differs.

## Reproducing the Crash

The crash is triggered by concurrent HTTP load against FrankenPHP with dd-trace-php active. Our approach:

1. Start FrankenPHP with 20 PHP threads, dd-trace-php (appsec + profiling enabled), and a Datadog Agent sidecar
2. Send 10,000 concurrent requests using `ab` at concurrency 200
3. Wait 10 seconds (brief idle between bursts)
4. Repeat — crash typically occurs within the first 2-3 bursts

The PHP script is trivial (file I/O + JSON serialization). No framework, no database, no Redis. The crash is purely from dd-trace-php's internal threading interacting with FrankenPHP's ZTS worker model under concurrent load.

### Quick Start

```bash
git clone https://github.com/jamesmehorter/dd-trace-php-crash-repro.git
cd dd-trace-php-crash-repro

# Crashes in ~30 seconds
./version-test.sh 1.18.0

# Survives indefinitely
./version-test.sh 1.16.0
```

### Version Test Results

| Version | Result |
|---|---|
| **1.18.0** | **CRASHED after 24s** — burst 3 of concurrent load |
| **1.16.0** | Survived 180s — 14 bursts, 140K requests, zero failures |

### Crash Output

```
memory allocation of 3420891154821048684 bytes failed
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

Signal 6 (SIGABRT) from Rust's `alloc::handle_alloc_error` → `std::process::abort()`. The backtrace is shallow because FrankenPHP is a statically-linked Go binary — `backtrace()` can't unwind through Go's stack. A debug-symbol build of dd-trace-php would provide the full Rust/C call stack.

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
| `crash_handler.c` | LD_PRELOAD signal handler — prints backtrace on crash, zero overhead |
| `entrypoint.sh` | Starts FrankenPHP with crash handler (or gdb via `RUN_WITH_GDB=true`) |
| `version-test.sh` | Automated A/B test — builds a specific version, runs burst load, reports crash/survive |
| `burst-test.sh` | Continuous burst-then-idle load pattern |
| `test.sh` | Idle-cycle test (slower reproduction path) |

## Env Vars We've Tried (None Fixed It)

All set simultaneously on a production ECS task running 1.18.0. It still crashed.

| Variable | Value | Result |
|---|---|---|
| `DD_TRACE_SIDECAR_TRACE_SENDER` | `false` | Still crashes |
| `DD_INSTRUMENTATION_TELEMETRY_ENABLED` | `false` | Still crashes |
| `DD_APPSEC_ENABLED` | `false` | Still crashes |
| `DD_TRACE_LOG_LEVEL` | `debug` | Still crashes (but logs tracer internals before crash) |
| All four combined | — | Still crashes |

The only fix is pinning to 1.16.0.

## Production Context

We also see this crash in production ECS Fargate environments (ARM64, Linux). The containers receive Caddy-level health checks (`respond "OK" 200`) every 30 seconds that never reach PHP — so dd-trace-php's internals are idle even though the container looks healthy. Crashes happen when real PHP traffic arrives, triggering concurrent request handling across threads.

33 crashes in 7 days across non-production environments. Zero crashes in production (which has constant traffic, so the idle-then-burst pattern doesn't occur).
