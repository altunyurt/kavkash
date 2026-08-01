#!/usr/bin/dash
# server.sh - Daemon: accepts shell history events over Unix socket, stores in SQLite

# Source includes.sh relative to THIS script (server may be started from any CWD).
_SCRIPT_DIR="$(dirname -- "$(realpath -- "$0")")"
. "$_SCRIPT_DIR/includes.sh"

[ -f $PID_FILE ] \
    && printf "error: %s\n" "A pid file already exists at $PID_FILE" \
    && exit 1

# Path to processor.sh (resolved from _SCRIPT_DIR in includes.sh)
PROC_SCRIPT="${_SCRIPT_DIR}/processor.sh"

# Initialize SQLite schema (idempotent — uses IF NOT EXISTS)
sqlite3 "$DB_FILE" << 'EOF'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    command TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    timestamp INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_history_command ON history(command, timestamp DESC);
EOF

# Remove stale socket file from a previous crash
rm -f "$SOCK_FILE"

# Write PID file for external ops (status check, graceful kill)
echo $$ > "$PID_FILE"

# exec replaces this shell with socat (saves a process)
# - fork: one child process per connection (isolates each request)
# - mode=0600: socket accessible only to owner
# - Bidirectional (no -u): required for query responses to reach the client
#
# NOTE: socat's EXEC: address parses its argument as a shell-like command
# line, so embedding "$PROC_SCRIPT $DB_FILE" directly would silently
# word-split DB_FILE on any spaces (e.g. an XDG_DATA_HOME with a space in
# it). Pass DB_FILE via environment instead, so it's never re-tokenized.
#
# stderr -> server.log: clients disconnecting mid-response is normal
# (prefetch cancel, fzf exit) and would otherwise spam broken-pipe noise
# on the daemon's terminal. Real errors (bind failures, sqlite problems)
# are still recorded in the log.
exec env HIST_DB="$DB_FILE" socat UNIX-LISTEN:"$SOCK_FILE",fork,mode=0600 EXEC:"$PROC_SCRIPT" 2>> "$__RUNTIME_DIR/server.log"
