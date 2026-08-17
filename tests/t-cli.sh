#!/bin/sh
# t-cli.sh — the kavkash CLI against a sandbox daemon.
. "$(dirname "$0")/lib.sh"
sandbox_new
daemon_start

# The CLI is invoked with an isolated HOME so restore takes the
# pid-file path (a real systemd unit would start the real daemon with
# real paths, not this sandbox's).
cli() { env HOME="$SANDBOX/home" "$KAVKASH_DIR/kavkash" "$@"; }
# Seed: three distinct commands, one duplicated non-consecutively.
# Future-dated ids survive the prune test below.
ns_send W "cli alpha" "$PWD" 8000000000000000001 "s1"
sleep 0.1
ns_send W "cli beta" "$PWD" 8000000000000000002 "s1"
sleep 0.1
ns_send W "cli alpha" "$PWD" 8000000000000000003 "s1"
sleep 0.1
ns_send W "cli gamma" "$PWD" 8000000000000000004 "s1"
sleep 0.3

t_begin "cli: status shows rows"
out=$(cli status 2>&1)
t_contains "4 rows, 3 distinct" "$out" "status counts"

t_begin "cli: stats works under a write hammer (lock regression)"
( i=0; while [ $i -lt 15 ]; do
    ns_send W "cli hammer $i" "$PWD" $((8100000000000000000 + i)) "s1" &
    i=$((i + 1))
  done
  wait ) &
t_rc 0 "stats exits cleanly under hammer" cli history stats

t_begin "cli: no sql-filename junk files in the CWD (hang regression)"
mkdir -p "$SANDBOX/cwd"
( cd "$SANDBOX/cwd" && cli history stats > /dev/null 2>&1 )
junk=$(ls "$SANDBOX/cwd" | grep -c '^SELECT\|^DELETE\|^UPDATE\|^VACUUM' || true)
t_eq "0" "$junk" "no junk files created"

# Two past-dated rows for the prune test (old ids = 2001).
ns_send W "cli old one" "$PWD" 1000000000000000001 "s1"
sleep 0.1
ns_send W "cli old two" "$PWD" 1000000000000000002 "s1"
sleep 0.2

t_begin "cli: prune dry run then apply removes only old rows"
out=$(cli history prune --older-than=30d 2>&1)
t_contains "would remove" "$out" "dry run reports"
t_rc 0 "prune applies" cli history prune --older-than=30d --mean-it
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command LIKE 'cli old%';")" "old rows pruned"
t_eq "4" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command IN ('cli alpha','cli beta','cli gamma');")" "future rows kept"

t_begin "cli: dedup --all folds duplicates"
out=$(cli history dedup --all --mean-it 2>&1)
t_contains "deduped" "$out" "dedup ran"
t_eq "3" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command IN ('cli alpha','cli beta','cli gamma');")" "alpha folded into one"

t_begin "cli: compact passes integrity check"
t_rc 0 "compact" cli history compact

t_begin "cli: backup + restore round trip"
mkdir -p "$SANDBOX/bk"
t_rc 0 "backup" cli backup "$SANDBOX/bk"
bk=$(ls "$SANDBOX"/bk/history.db.* 2> /dev/null | tail -1)
[ -n "$bk" ] && t_ok || t_fail "no backup file"
t_rc 0 "restore" cli restore "$bk"
sleep 1
[ -S "$KAV_SOCK_FILE" ] && t_ok || t_fail "daemon did not restart"
t_eq "wal" "$(kav_db "$KAV_DB_FILE" 'PRAGMA journal_mode;')" "WAL survives restore"
t_eq "3" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command IN ('cli alpha','cli beta','cli gamma');")" "rows survive restore"
{ [ -e "$KAV_DB_FILE-wal" ] || [ -e "$KAV_DB_FILE-shm" ]; } && t_fail "stale sidecars after restore" || t_ok
[ -f "$KAV_DB_FILE.pre-restore" ] && t_ok || t_fail "pre-restore copy kept"

daemon_stop
t_summary
