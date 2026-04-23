// Minimal signal handler that prints a backtrace on crash.
// Compiled and LD_PRELOADed into FrankenPHP — zero overhead until signal fires.
// Catches SIGTRAP (133-128=5), SIGABRT (6), SIGSEGV (11).

#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <execinfo.h>
#include <unistd.h>

static void crash_handler(int sig) {
    void *frames[128];
    int n = backtrace(frames, 128);

    fprintf(stderr, "\n=== CRASH HANDLER ===\n");
    fprintf(stderr, "Signal: %d\n", sig);
    fprintf(stderr, "Backtrace (%d frames):\n", n);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
    fprintf(stderr, "=== END CRASH HANDLER ===\n");

    // Re-raise to get the default behavior (core dump if enabled)
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor))
static void install_crash_handler(void) {
    signal(SIGTRAP, crash_handler);
    signal(SIGABRT, crash_handler);
    signal(SIGSEGV, crash_handler);
}
