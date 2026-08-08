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
        printf "error: %s\n" "A kavkash daemon is already running (pid $old_pid)" >&2
        exit 1
    fi
    # stale pid: process is gone — drop it and start fresh
    rm -f "$KAV_PID_FILE"
fi

# Path to processor.sh (resolved here, relative to this script)
KAV_PROC_SCRIPT="${_SCRIPT_DIR}/processor.sh"

# Schema: id is ns-since-epoch (INTEGER PRIMARY KEY = rowid alias, so the
# table is stored in time order); created/migrated by includes.sh.
kav_ensure_history_schema

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
