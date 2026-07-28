#! /usr/bin/dash

__RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp}/kavkash
__DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}/kavkash
_SCRIPT_DIR=$(dirname "$(realpath "$0")")

mkdir -p $__RUNTIME_DIR $__DATA_HOME

SOCK_FILE="$__RUNTIME_DIR/history.sock"
PID_FILE="$__RUNTIME_DIR/server.pid"
DB_FILE="$__DATA_HOME/history.db"

_HIST_BATCH=100
