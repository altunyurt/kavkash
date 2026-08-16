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

# Nanosecond epoch — the id doubles as the row's timestamp. INTEGER
# PRIMARY KEY aliases the rowid, so the table itself is stored in id
# (== time) order: ORDER BY id DESC is a pure reverse leaf scan.
# GNU date's %N (19 digits, int64-safe past year 2200); fallbacks keep
# ms/seconds precision (id uniqueness then relies on command spacing).
kav_new_id() {
    date +%s%N 2> /dev/null \
        || printf '%s000000' "$(date +%s%3N 2> /dev/null || date +%s)"
}

# sqlite3 with a lock wait on this connection. Bare sqlite3 calls race
# the daemon's writes (journal mode is delete — readers block during a
# write) and die with SQLITE_BUSY; .timeout is a dot-command that sets
# the wait and prints nothing, unlike PRAGMA busy_timeout, which would
# echo its value as a row into the result stream (and, run in its own
# process, would die with that process anyway).
kav_db() { sqlite3 -cmd '.timeout 5000' "$@"; }

# Create the history table if missing. Idempotent — existing databases
# are left untouched.
kav_ensure_history_schema() {
    # WAL journal mode: readers never block writers (and vice versa),
    # and a crash can't leave a stale rollback journal. Persistent per
    # database file. The PRAGMA echoes a row — silenced; stderr still
    # reaches the daemon log.
    kav_db "$KAV_DB_FILE" "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT NOT NULL, exit_code INTEGER NOT NULL, duration_ms INTEGER NOT NULL, session TEXT);" > /dev/null
}


