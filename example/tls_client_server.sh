#!/bin/bash
set -e
set -x

zig build

zig-out/bin/tls_echo_server &
server_pid=$!

for i in {0..99}
do
  zig-out/bin/tls_echo_client &
done

sleep 20
kill $server_pid
