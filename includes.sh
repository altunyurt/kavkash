#! /usr/bin/dash

# Data location follows the XDG spec. The socket and pid file always live
# under XDG_RUNTIME_DIR and are NOT configurable, so the daemon and the
# shell integrations — which compute the socket path themselves — can never
# disagree on where to talk.
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"

__RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
mkdir -p "$__RUNTIME_DIR" "$DATA_HOME"

SOCK_FILE="$__RUNTIME_DIR/history.sock"
PID_FILE="$__RUNTIME_DIR/server.pid"
DB_FILE="$DATA_HOME/history.db"
