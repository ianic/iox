#!/bin/bash
set -e
set -x

ulimit -n 8192

zig build -Doptimize=ReleaseSafe

zig-out/bin/tls_echo_server &
server_pid=$!

zig-out/bin/tls_echo_client

sleep 1
kill $server_pid
