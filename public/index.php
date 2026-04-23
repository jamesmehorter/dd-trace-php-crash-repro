<?php

// Trivial PHP script — file I/O, hashing, and JSON serialization.
// No framework, no database, no external calls.

header('Content-Type: application/json');

$tmp = tempnam('/tmp', 'dd_');
file_put_contents($tmp, str_repeat('x', 1024));
$data = file_get_contents($tmp);
unlink($tmp);

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
        'file_io' => strlen($data),
        'hash'    => md5($data),
    ],
];

echo json_encode($result, JSON_PRETTY_PRINT) . "\n";
