#!/usr/bin/dash
# server.sh - Daemon: accepts shell history events over Unix socket, stores in SQLite

# Source includes.sh relative to THIS script (server may be started from any CWD).
_SCRIPT_DIR="$(dirname -- "$(realpath -- "$0")")"
. "$_SCRIPT_DIR/includes.sh"

[ -f $KAV_PID_FILE ] \
    && printf "error: %s\n" "A pid file already exists at $KAV_PID_FILE" \
    && exit 1

# Path to processor.sh (resolved from _SCRIPT_DIR in includes.sh)
KAV_PROC_SCRIPT="${_SCRIPT_DIR}/processor.sh"

# Create the schema (id is a UUIDv7: it doubles as the write timestamp, so
# there is no separate timestamp/corr column).
sqlite3 "$KAV_DB_FILE" "CREATE TABLE IF NOT EXISTS history (
    id TEXT PRIMARY KEY,
    command TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL
);"

# Remove stale socket file from a previous crash
rm -f "$KAV_SOCK_FILE"

# Write PID file for external ops (status check, graceful kill)
echo $$ > "$KAV_PID_FILE"

# Cleanup on exit: a stale socket file would block the next bind, and a
# stale pid file would trip the startup guard — both must go when the
# daemon stops. socat runs as a background child so the shell stays in
# control of its lifetime: signals (SIGTERM from the pid file, etc.)
# kill socat first, then the EXIT trap removes the socket and pid files.
cleanup() {
    rm -f "$KAV_SOCK_FILE" "$KAV_PID_FILE"
}
trap cleanup EXIT
trap 'kill -TERM "$SOCAT_PID" 2> /dev/null' TERM INT HUP

# - fork: one child process per connection (isolates each request)
# - mode=0600: socket accessible only to owner
# - Bidirectional (no -u): required for query responses to reach the client
# - EXEC:"$KAV_PROC_SCRIPT": processor.sh sources includes.sh itself, so it
#   knows the DB path (KAV_DB_FILE) with no argv/env handoff.
#
# stderr -> server.log: clients disconnecting mid-response is normal
# (fzf exit) and would otherwise spam broken-pipe noise
# on the daemon's terminal. Real errors (bind failures, sqlite problems)
# are still recorded in the log.
socat UNIX-LISTEN:"$KAV_SOCK_FILE",fork,mode=0600 EXEC:"$KAV_PROC_SCRIPT" 2>> "$KAV_RUNTIME_DIR/server.log" &
KAV_SOCAT_PID=$!
wait "$KAV_SOCAT_PID"
