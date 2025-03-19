#!/bin/bash
set -e
set -x

zig build -Doptimize=ReleaseFast

ulimit -n 8192

zig-out/bin/tcp_echo_server &
server_pid=$!

# for i in {0..99}
# do
zig-out/bin/tcp_echo_client
# done

sleep 1
kill $server_pid


