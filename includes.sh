#! /usr/bin/dash

# XDG paths shared by daemon + shell hooks; fish mirrors them (can't
# source POSIX sh).
KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"

KAV_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
mkdir -p "$KAV_RUNTIME_DIR" "$KAV_DATA_HOME"

KAV_SOCK_FILE="$KAV_RUNTIME_DIR/history.sock"
KAV_PID_FILE="$KAV_RUNTIME_DIR/server.pid"
KAV_DB_FILE="$KAV_DATA_HOME/history.db"

# Shared helpers. kav_ prefix: this file is also sourced into interactive
# shells, so plain names like `die` could clash with user functions.
# install.sh keeps its own copies — it must run standalone pre-install.
kav_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
kav_have() { command -v "$1" > /dev/null 2>&1; }
kav_say() { printf '%s\n' "$*"; }
kav_warn() { printf 'warning: %s\n' "$*" >&2; }

# Nanosecond epoch — the id doubles as the row's timestamp. INTEGER
# PRIMARY KEY aliases the rowid, so the table itself is stored in id
# (== time) order: ORDER BY id DESC is a pure reverse leaf scan.
# GNU date's %N (19 digits, int64-safe past year 2200); fallbacks keep
# ms/seconds precision (id uniqueness then relies on command spacing).
kav_new_id() {
    date +%s%N 2> /dev/null \
        || printf '%s000000' "$(date +%s%3N 2> /dev/null || date +%s)"
}

# kav_new_id_to_time ID — human-readable time from an ns-since-epoch id.
kav_new_id_to_time() {
    date -d "@$(( $1 / 1000000000 ))" +"%Y-%m-%d %H:%M:%S" 2> /dev/null || printf '%s\n' "$1"
}

# Create the history table if missing. Idempotent — existing databases
# are left untouched.
kav_ensure_history_schema() {
    sqlite3 "$KAV_DB_FILE" "CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT NOT NULL, exit_code INTEGER NOT NULL, duration_ms INTEGER NOT NULL, session TEXT);"
}


