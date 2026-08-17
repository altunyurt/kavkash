#!/bin/sh
# t-regressions.sh — every fixed bug, replayed as a test.
. "$(dirname "$0")/lib.sh"
sandbox_new
daemon_start

# --- WAL active ---
t_begin "regression: WAL journal mode"
t_eq "wal" "$(kav_db "$KAV_DB_FILE" 'PRAGMA journal_mode;')" "journal mode is wal"

# --- PK collision: both commands stored, U pinned by command ---
t_begin "regression: PK collision stores both commands"
ns_send W "collide one" "$PWD" 4000000000000000001 "s1"
sleep 0.1
ns_send W "collide two" "$PWD" 4000000000000000001 "s1"
sleep 0.2
t_eq "2" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE id IN (4000000000000000001,4000000000000000002);")" "bumped row stored"
t_begin "regression: U with the wrong command cannot overwrite"
ns_send U 4000000000000000001 5 100 "collide two"
sleep 0.3
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code FROM history WHERE id=4000000000000000001;")" "winner row untouched"
t_begin "regression: U with the matching command updates"
ns_send U 4000000000000000001 5 100 "collide one"
sleep 0.3
t_eq "5" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code FROM history WHERE id=4000000000000000001;")" "exit code stored"

# --- lock waits: reads never fail under a write hammer ---
t_begin "regression: reads never fail under a write hammer"
# Writes run in a subshell so their `wait` can't see the daemon job.
( i=0
  while [ $i -lt 40 ]; do
      ns_send W "hammer $i" "$PWD" $((5000000000000000000 + i)) "s1" &
      i=$((i + 1))
  done
  wait )
fail=0
i=0
while [ $i -lt 30 ]; do
    kav_db "$KAV_DB_FILE" 'SELECT count(*) FROM history;' > /dev/null 2>&1 || fail=$((fail + 1))
    i=$((i + 1))
done
t_eq "0" "$fail" "no failed reads"

# --- daily backup: first W of the day snapshots ---
t_begin "regression: daily backup on first W"
rm -f "$KAV_DATA_HOME"/history.db.*
ns_send W "backup trigger" "$PWD" 6000000000000000001 "s1"
i=0
while [ $i -lt 40 ] && ! ls "$KAV_DATA_HOME"/history.db.* > /dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
done
t_eq "1" "$(ls "$KAV_DATA_HOME"/history.db.* 2> /dev/null | wc -l | tr -d ' ')" "snapshot created"

# --- daily backup: stale lock recovery ---
t_begin "regression: stale backup lock is cleared"
rm -f "$KAV_DATA_HOME"/history.db.*
mkdir -p "$KAV_RUNTIME_DIR/backup.lock"
touch -d '2 hours ago' "$KAV_RUNTIME_DIR/backup.lock"
ns_send W "backup trigger 2" "$PWD" 6000000000000000002 "s1"
i=0
while [ $i -lt 40 ] && [ -d "$KAV_RUNTIME_DIR/backup.lock" ]; do
    sleep 0.1
    i=$((i + 1))
done
t_eq "1" "$(ls "$KAV_DATA_HOME"/history.db.* 2> /dev/null | wc -l | tr -d ' ')" "stale lock cleared and snapshot taken"

# --- server.log rotation cap ---
t_begin "regression: server.log capped at 1 MB"
head -c 1500000 /dev/zero | tr '\0' 'x' > "$KAV_RUNTIME_DIR/server.log"
ns_send W "rotate probe" "$PWD" 7000000000000000001 "s1"
sleep 0.5
size=$(stat -c %s "$KAV_RUNTIME_DIR/server.log" 2> /dev/null || echo 999999999)
[ "$size" -lt 1000000 ] && t_ok || t_fail "server.log still $size bytes"

# --- boot integrity check (last: the db is corrupt from here on) ---
daemon_stop
t_begin "regression: corrupt db at boot sets the marker and status warns"
printf 'this is not a sqlite database' > "$KAV_DB_FILE"
daemon_start
sleep 0.3
[ -f "$KAV_RUNTIME_DIR/integrity_failed" ] && t_ok || t_fail "integrity marker missing"
out=$("$KAVKASH_DIR/kavkash" status 2>&1)
t_contains "WARNING" "$out" "status surfaces the failure"
daemon_stop

t_summary
