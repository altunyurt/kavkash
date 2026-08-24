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
# ms/seconds precision (the PK retry in processor W absorbs any
# collision).
kav_new_id() {
    date +%s%N 2> /dev/null \
        || printf '%s000000' "$(date +%s%3N 2> /dev/null || date +%s)"
}

# sqlite3 with a lock wait on this connection: writers serialize and
# WAL has transient shm/checkpoint windows, so a bare call could still
# hit SQLITE_BUSY. .timeout is a dot-command — it prints nothing,
# unlike PRAGMA busy_timeout, which would echo its value into the
# result stream.
#
# Owner-only files: sqlite3 applies the umask, so the default 022 would
# leave the history db (and its -wal/-shm sidecars, which inherit the
# db's mode) world-readable — every command verbatim. The subshell
# confines the umask to this call; it also covers backup.sh snapshots,
# which are created through the same helper.
kav_db() { ( umask 077; sqlite3 -cmd '.timeout 5000' "$@" ); }

# Writer variant of kav_db — every connection that COMMITS (processor W/U/D).
# PRAGMA synchronous=NORMAL is the SQLite-blessed WAL setting: commits
# skip the fsync (the WAL is synced at checkpoint instead), so concurrent
# writers hold the lock for microseconds, not disk-latency. Unlike
# journal_mode (persistent, set once in kav_ensure_history_schema)
# synchronous is PER-CONNECTION, so it must ride on every writing call;
# readers/backup don't sync and stay on kav_db. Trade-off: a power cut
# (not a daemon crash — the WAL lives in the page cache) can lose the
# most recent commands, bounded by the auto-checkpoint (~4MB WAL); the
# file can never corrupt either way. The CLI echoes the pragma's result
# row ("normal") to stdout, which would corrupt parsed streams
# (processor W/U read SELECT changes()) — the .output round-trip
# swallows it.
kav_db_w() { ( umask 077; sqlite3 -cmd '.timeout 5000' -cmd '.output /dev/null' -cmd 'PRAGMA synchronous=NORMAL;' -cmd '.output stdout' "$@" ); }

# SQL literal escaping — the single source of truth. The sqlite3 CLI
# takes no bind parameters, so every value interpolated into a query
# string (processor.sh W/U/Q) must have its quotes doubled here first;
# a literal `sed "s/'/''/g"` in a query path is a bug. import.sh's awk
# esc() mirrors this rule — it runs in its own process and can't call
# this helper; keep the two in sync.
kav_sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

# Cap server.log at 1 MB — raw handler stderr lands there via socat's
# 2>> redirect, bypassing kav_log. Checked at boot and on every W;
# journald rotates its own side.
kav_rotate_log() {
    [ -f "$KAV_RUNTIME_DIR/server.log" ] || return 0
    size=$(stat -c %s "$KAV_RUNTIME_DIR/server.log" 2> /dev/null || echo 0)
    [ "${size:-0}" -gt 1048576 ] && : > "$KAV_RUNTIME_DIR/server.log"
}

# kav_log — daemon logging. Writes to stderr (the daemon's log stream:
# server.log under socat, journald under systemd) and forwards to
# syslog/journald via `logger` when available.
kav_log() {
    kav_rotate_log
    printf 'kavkash: %s\n' "$*" >&2
    command -v logger > /dev/null 2>&1 && logger -t kavkash -- "$*"
}

# Daily snapshot, at most one per day — called at daemon boot and on
# every recorded command, so a machine that is off for weeks still gets
# a fresh snapshot on its first command (backup.sh also prunes to the
# newest 7). The mkdir lock serializes concurrent triggers; a lock older
# than an hour is a killed backup and is cleared.
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

# Create the history table if missing. Idempotent — existing databases
# are left untouched.
kav_ensure_history_schema() {
    # WAL journal mode: readers never block writers (and vice versa),
    # and a crash can't leave a stale rollback journal. Persistent per
    # database file. The PRAGMA echoes a row — silenced; stderr still
    # reaches the daemon log.
    kav_db "$KAV_DB_FILE" "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT NOT NULL, exit_code INTEGER NOT NULL, duration_ms INTEGER NOT NULL, session TEXT);" > /dev/null
    # The db predates the umask guard in kav_db on upgraded installs:
    # tighten it here, at every boot/import, so an old 0644 db (lax
    # umask) doesn't stay world-readable. Sidecars too: SQLite mode-copies the db at -wal/-shm
    # CREATION, so a stale sidecar born in
    # the 0644 era keeps 0644 forever otherwise. Missing sidecars are
    # normal (WAL checkpoints away on the last close) — ignore them.
    chmod 600 "$KAV_DB_FILE" "$KAV_DB_FILE"-wal "$KAV_DB_FILE"-shm 2> /dev/null || true
}


