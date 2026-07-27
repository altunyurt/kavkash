#!/usr/bin/dash
# server.sh - Daemon: accepts shell history events over Unix socket, stores in SQLite

# Config paths (XDG-compliant with fallbacks)
DB_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash-history.db"
SOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/history.sock"
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/kavkash-server.pid"

# Resolve script dir: try $0 first, fall back to PATH lookup
# Handles: ./server.sh, /full/path/server.sh, symlinks, PATH invocation
_SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "$(dirname "$(command -v server.sh 2>/dev/null || echo "$0")")")
PROC_SCRIPT="${_SCRIPT_DIR}/processor.sh"

# Initialize SQLite schema (idempotent — uses IF NOT EXISTS)
# - WAL mode: better concurrency for concurrent reads/writes
# - idx_history_timestamp: speeds up ORDER BY timestamp DESC (used by every query)
# - idx_history_command: speeds up future dedup/frequency queries
sqlite3 "$DB_FILE" <<'EOF'
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
# - EXEC:"$PROC_SCRIPT $DB_FILE": runs processor.sh per connection with DB path
# Bidirectional (no -u): required for query responses to reach the client
exec socat UNIX-LISTEN:"$SOCK_FILE",fork,mode=0600 EXEC:"$PROC_SCRIPT $DB_FILE"
