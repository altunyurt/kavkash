#!/usr/bin/dash
# server.sh - Daemon: accepts shell history events over Unix socket, stores in SQLite

# Source includes.sh relative to THIS script (server may be started from any CWD).
_SCRIPT_DIR="$(dirname -- "$(realpath -- "$0")")"
. "$_SCRIPT_DIR/includes.sh"

# Refuse to start when a live daemon is already running, but tolerate a
# stale pid file (crashed daemon): a dead pid is a leftover, not a lock.
if [ -f "$KAV_PID_FILE" ]; then
    old_pid=$(cat "$KAV_PID_FILE" 2> /dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2> /dev/null; then
        printf "kavkash: a daemon is already running (pid %s) — leaving it as is\n" "$old_pid" >&2
        # Exit 0 ("success"): the service is satisfied — another instance is
        # live. An exit 1 here would make systemd's Restart=on-abnormal unit
        # retry every RestartSec until the foreign daemon dies (a hot
        # restart loop when an old daemon outlives its session).
        exit 0
    fi
    # stale pid: process is gone — drop it and start fresh
    rm -f "$KAV_PID_FILE"
fi

# Path to processor.sh (resolved here, relative to this script)
KAV_PROC_SCRIPT="${_SCRIPT_DIR}/processor.sh"

# Schema: id is ns-since-epoch (INTEGER PRIMARY KEY = rowid alias, so the
# table is stored in time order); created by includes.sh.
kav_ensure_history_schema

# Boot integrity check: never write into a database silently beyond
# repair. WAL recovery handles crashes; if the file still fails, warn
# loudly (server.log + a marker that `kavkash status` surfaces) and keep
# recording rather than going dark.
if kav_db "$KAV_DB_FILE" 'PRAGMA integrity_check;' 2> /dev/null | grep -qx ok; then
    rm -f "$KAV_RUNTIME_DIR/integrity_failed"
else
    echo "kavkash: integrity check FAILED for $KAV_DB_FILE — the database may be corrupt" >&2
    echo "kavkash: restore the newest snapshot with: kavkash restore <history.db.TIMESTAMP>" >&2
    : > "$KAV_RUNTIME_DIR/integrity_failed"
fi

# Daily snapshot at boot (the per-command trigger covers days without a
# restart).
kav_maybe_backup "$_SCRIPT_DIR/backup.sh"

# Remove stale socket file from a previous crash
rm -f "$KAV_SOCK_FILE"

# Write PID file for external ops (status check, graceful kill)
echo $$ > "$KAV_PID_FILE"

# On exit: remove socket + pid files (stale ones block the next start).
# socat is a background child; TERM/INT/HUP kill it first, then EXIT
# cleans up.
cleanup() {
    rm -f "$KAV_SOCK_FILE" "$KAV_PID_FILE"
}
trap cleanup EXIT
trap 'kill -TERM "$KAV_SOCAT_PID" 2> /dev/null' TERM INT HUP

# - fork: one process per connection (isolates requests)
# - mode=0600: socket owner-only
# - Bidirectional (no -u): query responses must reach the client
# - EXEC: processor.sh sources includes.sh itself, so it knows the DB path
#   with no argv/env handoff. stderr -> server.log (broken pipes from fzf
#   exits are normal; real errors still land there).
socat UNIX-LISTEN:"$KAV_SOCK_FILE",fork,mode=0600 EXEC:"$KAV_PROC_SCRIPT" 2>> "$KAV_RUNTIME_DIR/server.log" &
KAV_SOCAT_PID=$!
wait "$KAV_SOCAT_PID"
