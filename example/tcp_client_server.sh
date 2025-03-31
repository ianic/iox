#!/bin/bash
set -e
set -x

zig build -Doptimize=ReleaseSafe

ulimit -n 8192

zig-out/bin/tcp_echo_server &
server_pid=$!

zig-out/bin/tcp_echo_client

sleep 1
kill $server_pid


