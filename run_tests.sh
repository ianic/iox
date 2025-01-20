#!/bin/bash

set -e

zig build

function title() {
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
    printf "\n${BLUE}$1${NC}\n"
}

title "TCP client/server"
zig-out/bin/tcp_echo_server &
server_pid=$!
sleep 0.5
zig-out/bin/tcp_echo_client
kill $server_pid

title "TLS client/server"
zig-out/bin/tls_echo_server &
server_pid=$!
sleep 0.5
zig-out/bin/tls_echo_client
kill $server_pid

title "HTTPS get"
zig-out/bin/tls_client google.com

title "WS echo"
zig-out/bin/ws_echo_client "ws://ws.vi-server.org/mirror/";

title "WSS echo"
zig-out/bin/ws_echo_client "wss://ws.vi-server.org/mirror/";
