#!/usr/bin/dash
# server.sh - Pure utility daemon using socat, dash, and sqlite3
DB_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/kavkash-history.db"
SOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/history.sock"
PROC_SCRIPT="$(dirname "$0")/processor.sh"

# Initialize SQLite Schema
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
EOF

rm -f "$SOCK_FILE"

# Listen on UNIX Domain Socket with socat
exec socat -u UNIX-LISTEN:"$SOCK_FILE",fork,mode=0600 EXEC:"$PROC_SCRIPT $DB_FILE"
