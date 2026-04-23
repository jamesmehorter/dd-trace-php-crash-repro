FROM dunglas/frankenphp:php8.4-trixie

# Install debugging tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    gdb \
    curl \
    procps \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Install dd-trace-php at a specific version
ARG DD_TRACE_VERSION=1.18.0
RUN curl -LO https://github.com/DataDog/dd-trace-php/releases/download/${DD_TRACE_VERSION}/datadog-setup.php \
    && php datadog-setup.php --php-bin=all --enable-appsec --enable-profiling \
    && rm -f datadog-setup.php

# Build crash handler (prints backtrace on SIGTRAP/SIGABRT/SIGSEGV)
COPY crash_handler.c /tmp/crash_handler.c
RUN gcc -shared -fPIC -rdynamic -o /usr/local/lib/crash_handler.so /tmp/crash_handler.c \
    && rm /tmp/crash_handler.c


COPY Caddyfile /etc/caddy/Caddyfile
COPY public/ /app/public/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
