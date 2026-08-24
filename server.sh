#!/usr/bin/dash
# server.sh - Daemon: accepts shell history events over Unix socket, stores in SQLite

# Source includes.sh relative to THIS script (server may be started from any CWD).
_SCRIPT_DIR="$(dirname -- "$(realpath -- "$0")")"
. "$_SCRIPT_DIR/includes.sh"

# Refuse to start when a live daemon is already running; a dead pid is
# a leftover, not a lock.
if [ -f "$KAV_PID_FILE" ]; then
    old_pid=$(cat "$KAV_PID_FILE" 2> /dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2> /dev/null; then
        kav_log "a daemon is already running (pid $old_pid) — leaving it as is"
        # Exit 0: the service is satisfied — another instance is live.
        # Exit 1 would make systemd's Restart=on-abnormal retry until
        # the foreign daemon dies (a hot restart loop).
        exit 0
    fi
    # stale pid: process is gone — drop it and start fresh
    rm -f "$KAV_PID_FILE"
fi

KAV_PROC_SCRIPT="${_SCRIPT_DIR}/processor.sh"

kav_ensure_history_schema

# Boot integrity check: never write into a database beyond repair. WAL
# recovery handles crashes; if the file still fails, warn loudly and
# keep recording rather than going dark.
if kav_db "$KAV_DB_FILE" 'PRAGMA integrity_check;' 2> /dev/null | grep -qx ok; then
    rm -f "$KAV_RUNTIME_DIR/integrity_failed"
else
    kav_log "integrity check FAILED for $KAV_DB_FILE — the database may be corrupt"
    kav_log "restore the newest snapshot with: kavkash restore <history.db.TIMESTAMP>"
    : > "$KAV_RUNTIME_DIR/integrity_failed"
fi

kav_maybe_backup "$_SCRIPT_DIR/backup.sh"
kav_rotate_log

# Stale socket from a previous crash
rm -f "$KAV_SOCK_FILE"

echo $$ > "$KAV_PID_FILE"

cleanup() {
    rm -f "$KAV_SOCK_FILE" "$KAV_PID_FILE"
}
trap cleanup EXIT
trap 'kill -TERM "$KAV_SOCAT_PID" 2> /dev/null' TERM INT HUP

# - fork: one process per connection (isolates requests)
# - mode=0600: owner-only socket
# - Bidirectional (no -u): query responses must reach the client
# - EXEC: processor.sh sources includes.sh itself — no argv/env handoff
# - -T 5: drop idle connections (a silent client would otherwise park a
#   handler forever — an fd/process exhaustion DoS against the daemon)
socat -T 5 UNIX-LISTEN:"$KAV_SOCK_FILE",fork,mode=0600 EXEC:"$KAV_PROC_SCRIPT" 2>> "$KAV_RUNTIME_DIR/server.log" &
KAV_SOCAT_PID=$!
wait "$KAV_SOCAT_PID"
