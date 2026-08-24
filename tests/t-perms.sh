#!/bin/sh
# t-perms.sh — history.db and the socket must be owner-only. The db
# holds every command verbatim; a lax umask (default 022) would leave
# it world-readable. The socket is already 0600 (socat mode=0600) —
# kept here as a regression guard.
. "$(dirname "$0")/lib.sh"

t_begin "db and socket are 0600 after daemon boot"
sandbox_new
daemon_start
db_mode=$(stat -c %a "$KAV_DB_FILE")
sock_mode=$(stat -c %a "$KAV_SOCK_FILE")
daemon_stop
t_eq "600" "$db_mode" "history.db must be owner-only"
t_eq "600" "$sock_mode" "socket must be owner-only"

# Upgraded installs may carry a db created under a lax umask — the
# schema-ensure step at daemon boot must tighten it, not leave it.
t_begin "pre-existing 0644 db is tightened at daemon boot"
sandbox_new
( umask 022; sqlite3 "$KAV_DB_FILE" 'CREATE TABLE t (x);' )
[ "$(stat -c %a "$KAV_DB_FILE")" = "644" ] \
    || t_fail "precondition: lax-umask db should be 0644"
daemon_start
db_mode=$(stat -c %a "$KAV_DB_FILE")
daemon_stop
t_eq "600" "$db_mode" "boot must tighten an existing 0644 db"

# Sidecars inherit the db's mode only at CREATION (SQLite mode-copies),
# so a -wal born in the 0644 era stays 0644 forever. The keeper
# connection (reading a fifo) stays open so schema-ensure's own close —
# which would checkpoint the WAL away — can't delete the file under
# the assertion.
t_begin "stale WAL sidecar is tightened at boot"
sandbox_new
( umask 022; sqlite3 "$KAV_DB_FILE" 'PRAGMA journal_mode=WAL; CREATE TABLE t (x);' )
mkfifo "$KAV_RUNTIME_DIR/walfifo"
sqlite3 "$KAV_DB_FILE" < "$KAV_RUNTIME_DIR/walfifo" &
wpid=$!
exec 9> "$KAV_RUNTIME_DIR/walfifo"
printf 'BEGIN; INSERT INTO t VALUES (1);\n' >&9
sleep 0.3
[ "$(stat -c %a "$KAV_DB_FILE-wal")" = "644" ] \
    || t_fail "precondition: stale -wal should be 0644"
kav_ensure_history_schema
wal_mode=$(stat -c %a "$KAV_DB_FILE-wal")
db_mode=$(stat -c %a "$KAV_DB_FILE")
exec 9>&-
kill -9 "$wpid" 2> /dev/null
t_eq "600" "$wal_mode" "boot must tighten a stale -wal"
t_eq "600" "$db_mode" "and the db itself"

t_summary
