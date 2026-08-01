#! /usr/bin/dash

# Data location follows the XDG spec; nothing configurable — the daemon and
# the shell integrations (bash/zsh source this file, fish mirrors it) can
# never disagree on paths.
KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"

KAV_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
mkdir -p "$KAV_RUNTIME_DIR" "$KAV_DATA_HOME"

KAV_SOCK_FILE="$KAV_RUNTIME_DIR/history.sock"
KAV_PID_FILE="$KAV_RUNTIME_DIR/server.pid"
KAV_DB_FILE="$KAV_DATA_HOME/history.db"

# History batch size for the shell integrations (functions.bash/.zsh source
# this file; functions.fish can't — fish syntax — so keep its copy in sync).
KAV_HIST_BATCH=100

KAV_DEBUG=${KAV_DEBUG:-0}

# Small shared helpers. kav_ prefix: this file is also sourced into
# interactive shells (functions.bash/.zsh), where plain names like `die`
# or `have` could clash with user-defined functions. install.sh keeps its
# own copies — it must run standalone before includes.sh is installed.
kav_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
kav_have() { command -v "$1" > /dev/null 2>&1; }
kav_say() { printf '%s\n' "$*"; }
kav_warn() { printf 'warning: %s\n' "$*" >&2; }
