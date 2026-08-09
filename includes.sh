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

# Create/migrate the history table. v0.2.x stored id as a TEXT UUIDv7
# (ms timestamp in hex); the id is now ns-since-epoch. Migration: the old
# id's first 12 hex chars decode to ms, re-expressed as ns. SQL can't
# parse '0x...' text (CAST gives 0), so each row's id is converted in dash
# ($((0x...)) is exact 64-bit) from a hex(quote()) dump — hex keeps
# multiline commands on one line. The history_old check makes the carry-
# over rerunnable after a crash between the rename and the inserts.
kav_ensure_history_schema() {
    if sqlite3 "$KAV_DB_FILE" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='history' AND sql LIKE '%id TEXT%';" | grep -q 1; then
        sqlite3 "$KAV_DB_FILE" "BEGIN; ALTER TABLE history RENAME TO history_old; CREATE TABLE history (id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT NOT NULL, exit_code INTEGER NOT NULL, duration_ms INTEGER NOT NULL, session TEXT); COMMIT;"
    fi
    if sqlite3 "$KAV_DB_FILE" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='history_old';" | grep -q 1; then
        # old id is xxxxxxxx-xxxx-...: chars 1-8 + 10-13 are the ms in hex.
        # hex() of the raw command keeps multiline commands on one line;
        # CAST(unhex(...) AS TEXT) restores them (no quote() wrapper, so no
        # unescaping). The 48-bit ms value needs dash $((0x...)) — mawk and
        # sqlite's CAST can't parse '0x' text, and mawk %d is 32-bit.
        prev=0
        sqlite3 -noheader "$KAV_DB_FILE" "SELECT id, hex(command), hex(COALESCE(cwd,'')), exit_code, duration_ms FROM history_old ORDER BY substr(replace(id, '-', ''), 1, 12);" |
        while IFS='|' read -r oldid hcmd hcwd exitc dur; do
            mshex=$(printf '%s' "$oldid" | cut -c1-8,10-13)  # ms in hex
            ns=$((0x$mshex * 1000000))
            # old ids carried a random suffix: two rows can share the same
            # ms (second-resolution atuin, bash+zsh pseudo range); bump
            # monotonic so the PK never collides.
            [ "$ns" -le "$prev" ] && ns=$((prev + 1))
            prev=$ns
            printf "INSERT INTO history (id, command, cwd, exit_code, duration_ms) VALUES (%s, CAST(unhex('%s') AS TEXT), CAST(unhex('%s') AS TEXT), %s, %s);\n" "$ns" "$hcmd" "$hcwd" "$exitc" "$dur"
        done | sqlite3 "$KAV_DB_FILE"
        sqlite3 "$KAV_DB_FILE" "DROP TABLE history_old;"
    fi
    sqlite3 "$KAV_DB_FILE" "CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT NOT NULL, exit_code INTEGER NOT NULL, duration_ms INTEGER NOT NULL, session TEXT);"
    # v0.3.x tables lack the session column (additive; pre-session rows are
    # NULL, which session scoping naturally excludes).
    if ! sqlite3 "$KAV_DB_FILE" "PRAGMA table_info(history);" | grep -q '|session|'; then
        sqlite3 "$KAV_DB_FILE" "ALTER TABLE history ADD COLUMN session TEXT;"
    fi
}

