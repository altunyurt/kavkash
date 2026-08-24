#! /usr/bin/dash

# Shared paths (fish mirrors these — it can't source POSIX sh).
KAV_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash"

KAV_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/kavkash"
mkdir -p "$KAV_RUNTIME_DIR" "$KAV_DATA_HOME"

KAV_SOCK_FILE="$KAV_RUNTIME_DIR/history.sock"
KAV_PID_FILE="$KAV_RUNTIME_DIR/server.pid"
KAV_DB_FILE="$KAV_DATA_HOME/history.db"

# kav_ prefix: sourced into interactive shells — plain names could clash.
# install.sh keeps its own copies (it must run standalone pre-install).
kav_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
kav_have() { command -v "$1" > /dev/null 2>&1; }

# ns-since-epoch id = row timestamp; INTEGER PRIMARY KEY stores the table
# in time order, so ORDER BY id DESC is a reverse leaf scan. %N gives 19
# digits (int64-safe); fallbacks lose precision — the W id-bump retry
# absorbs collisions.
kav_new_id() {
    date +%s%N 2> /dev/null \
        || printf '%s000000' "$(date +%s%3N 2> /dev/null || date +%s)"
}

# sqlite3 with a lock wait (.timeout — unlike PRAGMA busy_timeout it
# prints nothing into the result stream) and an owner-only umask:
# sqlite3 applies the umask, so 022 would leave the db, its -wal/-shm
# sidecars, and backup snapshots world-readable.
kav_db() { ( umask 077; sqlite3 -cmd '.timeout 5000' "$@" ); }

# Writer variant for every connection that commits (processor W/U/D):
# synchronous=NORMAL — per-connection (journal_mode is persistent, set
# once in kav_ensure_history_schema), so it must ride on each write.
# Power cut can lose the most recent commands (bounded by the ~4MB WAL
# checkpoint); the file can never corrupt. The pragma form can echo a
# row (journal_mode prints "wal") — the .output round-trip silences it,
# keeping parsed streams (W/U read SELECT changes()) clean.
kav_db_w() { ( umask 077; sqlite3 -cmd '.timeout 5000' -cmd '.output /dev/null' -cmd 'PRAGMA synchronous=NORMAL;' -cmd '.output stdout' "$@" ); }

# SQL literal escaping — single source of truth (the sqlite3 CLI takes
# no bind parameters). import.sh's awk esc() mirrors it in its own
# process; keep the two in sync.
kav_sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

# Cap server.log at 1 MB (raw handler stderr lands there; journald
# rotates its own side).
kav_rotate_log() {
    [ -f "$KAV_RUNTIME_DIR/server.log" ] || return 0
    size=$(stat -c %s "$KAV_RUNTIME_DIR/server.log" 2> /dev/null || echo 0)
    [ "${size:-0}" -gt 1048576 ] && : > "$KAV_RUNTIME_DIR/server.log"
}

# Daemon log: stderr (server.log / journald) + syslog via logger.
kav_log() {
    kav_rotate_log
    printf 'kavkash: %s\n' "$*" >&2
    command -v logger > /dev/null 2>&1 && logger -t kavkash -- "$*"
}

# One daily snapshot (boot + first command of the day; backup.sh prunes
# to 7). mkdir lock serializes triggers; a lock older than 1h is a dead
# backup.
kav_maybe_backup() {
    backup_script="${1:-}"
    [ -n "$backup_script" ] || return 0
    [ -d "$KAV_DATA_HOME" ] || return 0
    ls "$KAV_DATA_HOME"/history.db.$(date +%F).* > /dev/null 2>&1 && return 0
    lock="$KAV_RUNTIME_DIR/backup.lock"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -mmin +60 2> /dev/null)" ]; then
        rm -rf "$lock"
    fi
    mkdir "$lock" 2> /dev/null || return 0
    "$backup_script"
    rmdir "$lock" 2> /dev/null || true
}

# Idempotent: creates the table if missing, nothing else.
kav_ensure_history_schema() {
    # WAL: readers never block writers; persistent per db file. The
    # pragma echoes a row — silenced.
    kav_db "$KAV_DB_FILE" "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT NOT NULL, exit_code INTEGER NOT NULL, duration_ms INTEGER NOT NULL, session TEXT);" > /dev/null
    # Tighten pre-existing 0644 dbs (created under a lax umask) and
    # stale sidecars — SQLite mode-copies the db only at sidecar
    # creation. Missing sidecars are normal; ignore them.
    chmod 600 "$KAV_DB_FILE" "$KAV_DB_FILE"-wal "$KAV_DB_FILE"-shm 2> /dev/null || true
}
