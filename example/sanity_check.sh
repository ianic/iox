#!/bin/bash
set -e
#set -x

function title {
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
    printf "${BLUE}$1${NC}\n"
}

# title "build"
zig build
zig build test

title "TCP"
zig-out/bin/tcp_echo_server &
server_pid=$!
zig-out/bin/tcp_echo_client
kill $server_pid

title "TLS"
zig-out/bin/tls_echo_server &
server_pid=$!
zig-out/bin/tls_echo_client
kill $server_pid

title "WS"
zig-out/bin/ws_echo_server &
server_pid=$!
zig-out/bin/ws_echo_client ws://localhost:9002
title "WSS"
zig-out/bin/ws_echo_client wss://localhost:9003
kill $server_pid
