#! /usr/bin/dash

# Data location follows the XDG spec. The socket and pid file always live
# under XDG_RUNTIME_DIR and are NOT configurable, so the daemon and the
# shell integrations — which compute the socket path themselves — can never
# disagree on where to talk.
KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"

KAV_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
mkdir -p "$KAV_RUNTIME_DIR" "$KAV_DATA_HOME"

KAV_SOCK_FILE="$KAV_RUNTIME_DIR/history.sock"
KAV_PID_FILE="$KAV_RUNTIME_DIR/server.pid"
KAV_DB_FILE="$KAV_DATA_HOME/history.db"
