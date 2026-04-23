FROM dunglas/frankenphp:php8.4-trixie

# Install debugging tools and dd-trace-php debug symbols
RUN apt-get update && apt-get install -y --no-install-recommends \
    gdb \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install dd-trace-php at a specific version
ARG DD_TRACE_VERSION=1.18.0
RUN curl -LO https://github.com/DataDog/dd-trace-php/releases/download/${DD_TRACE_VERSION}/datadog-setup.php \
    && php datadog-setup.php --php-bin=all --enable-appsec --enable-profiling \
    && rm -f datadog-setup.php

# Enable core dumps inside the container
RUN echo 'kernel.core_pattern=/tmp/core.%e.%p' > /etc/sysctl.d/core.conf \
    && ulimit -c unlimited 2>/dev/null || true

COPY Caddyfile /etc/caddy/Caddyfile
COPY public/ /app/public/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app

EXPOSE 80

# Run under gdb to catch the crash. gdb wraps frankenphp so we get a backtrace
# on SIGTRAP/abort. Set RUN_WITH_GDB=false to run without gdb.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
