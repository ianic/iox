#!/bin/bash

set -e

function title() {
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
    printf "${BLUE}$1${NC}\n"
}

title "build iox"
zig build
zig build test

title "build tls.zig"
cd ../tls.zig/
zig build test

title "build websocket.zig"
cd ../websocket.zig/
zig build test
cd ../iox/

title "TCP client/server"
zig-out/bin/tcp_echo_server &
server_pid=$!
#sleep 0.5
zig-out/bin/tcp_echo_client
kill $server_pid

title "TLS client/server"
zig-out/bin/tls_echo_server &
server_pid=$!
#sleep 0.5
zig-out/bin/tls_echo_client
kill $server_pid

title "HTTPS get"
zig-out/bin/tls_client google.com

title "WS echo"
zig-out/bin/ws_echo_client "ws://ws.vi-server.org/mirror/";

title "WSS echo"
zig-out/bin/ws_echo_client "wss://ws.vi-server.org/mirror/";


title "WS client/server"
zig-out/bin/ws_echo_server &
server_pid=$!
#sleep 0.5
zig-out/bin/ws_echo_client "ws://localhost:9002"

title "WSS client/server"
zig-out/bin/ws_echo_client "wss://localhost:9003"
kill $server_pid
