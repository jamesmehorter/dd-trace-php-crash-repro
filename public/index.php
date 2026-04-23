<?php

// Exercise more dd-trace instrumentation hooks to increase crash likelihood.
// Each request triggers: file I/O, curl (if available), PDO-like operations,
// and JSON serialization — all auto-instrumented by dd-trace-php.

header('Content-Type: application/json');

// File I/O (instrumented by dd-trace)
$tmp = tempnam('/tmp', 'dd_');
file_put_contents($tmp, str_repeat('x', 1024));
$data = file_get_contents($tmp);
unlink($tmp);

// Simulate work that dd-trace hooks into
$result = [
    'status'      => 'ok',
    'timestamp'   => date('c'),
    'pid'         => getmypid(),
    'sapi'        => php_sapi_name(),
    'thread_safe' => PHP_ZTS ? true : false,
    'request_id'  => bin2hex(random_bytes(8)),
    'extensions'  => [
        'ddtrace'  => phpversion('ddtrace') ?: false,
        'ddappsec' => phpversion('ddappsec') ?: false,
    ],
    'work' => [
        'file_io'    => strlen($data),
        'hash'       => md5($data),
        'json_depth' => 3,
    ],
];

// Nested JSON encode/decode (exercises serialization hooks)
for ($i = 0; $i < 3; $i++) {
    $result['nested'][$i] = json_decode(json_encode($result), true);
}

echo json_encode($result, JSON_PRETTY_PRINT) . "\n";
