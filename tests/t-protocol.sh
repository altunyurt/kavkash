#!/bin/sh
# t-protocol.sh — W/U/Q/D wire protocol against a sandbox daemon.
. "$(dirname "$0")/lib.sh"
sandbox_new
daemon_start

# --- W: basic write + trailing trim ---
t_begin "W: basic write trims trailing whitespace"
ns_send W "echo hello   " "$PWD" 1000000000000000001 "s1"
sleep 0.2
t_eq "echo hello" "$(kav_db "$KAV_DB_FILE" "SELECT command FROM history WHERE id=1000000000000000001;")" "trailing whitespace trimmed"

# --- W: leading whitespace / # comments skipped (the gate is hook.sh, not the wire) ---
t_begin "W: leading whitespace and # comments skipped (hook.sh)"
out=$("$KAVKASH_DIR/hook.sh" W " secret" "$PWD" s1)
sleep 0.3
t_eq "" "$out" "no id minted for a leading-space command"
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command LIKE ' secret';")" "command not stored"
out=$("$KAVKASH_DIR/hook.sh" W "# comment" "$PWD" s1)
sleep 0.3
t_eq "" "$out" "no id minted for a # command"
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='# comment';")" "comment not stored"

# --- W: multiline + UTF-8 + quotes survive ---
t_begin "W: multiline + UTF-8 + quotes survive"
multi=$(printf 'line1\nline2 → ünïcode "quoted" it'"'"'s')
ns_send W "$multi" "$PWD" 1000000000000000004 "s1"
sleep 0.2
t_eq "$multi" "$(kav_db "$KAV_DB_FILE" "SELECT command FROM history WHERE id=1000000000000000004;")" "command round-trips intact"

# --- escaping: single quotes on every interpolation path (kav_sql_quote) ---
t_begin "escaping: W stores a quoted command verbatim"
ns_send W "it's 'quoted'" "$PWD" 1000000000000000005 "s1"
sleep 0.2
t_eq "it's 'quoted'" "$(kav_db "$KAV_DB_FILE" "SELECT command FROM history WHERE id=1000000000000000005;")" "stored verbatim"
t_begin "escaping: U with a quoted command pins its row"
ns_send U 1000000000000000005 5 100 "it's 'quoted'"
sleep 0.3
t_eq "5|100" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code||'|'||duration_ms FROM history WHERE id=1000000000000000005;")" "pinned update applied"
t_begin "escaping: Q prefix containing a quote matches"
t_eq "it's 'quoted'" "$(q_rows 10 "it's")" "quoted prefix matches"

# --- W: invalid id dropped ---
t_begin "W: non-numeric id dropped"
ns_send W "bogus id" "$PWD" "notanumber" "s1"
sleep 0.2
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='bogus id';")" "garbage id rejected"

# --- W: consecutive-repeat collapse ---
t_begin "W: consecutive repeat collapses into one row"
ns_send W "repeat me" "$PWD" 1000000000000000100 "s1"
sleep 0.1
ns_send W "repeat me" "$PWD" 1000000000000000200 "s1"
sleep 0.2
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='repeat me';")" "one row"
t_eq "1000000000000000200" "$(kav_db "$KAV_DB_FILE" "SELECT id FROM history WHERE command='repeat me';")" "row takes the newest id"

# --- U: exit + duration ---
t_begin "U: stores exit code and duration"
ns_send W "u test" "$PWD" 1000000000000000300 "s1"
sleep 0.2
ns_send U 1000000000000000300 7 42
sleep 0.3
t_eq "7|42" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code||'|'||duration_ms FROM history WHERE id=1000000000000000300;")" "exit+duration stored"

# --- Q: payload carries last-run metadata ---
t_begin "Q: payload carries last-run metadata"
raw=$(q_raw 10 u | grep 'u test')
t_contains "✗" "$raw" "failure marker for non-zero exit"
t_contains "42ms" "$raw" "duration shown"
t_contains "s" "$raw" "age shown"
t_begin "Q: bare command survives the metadata strip"
t_eq "u test" "$(q_rows 10 u)" "stripped row is the clean command"

# --- U: legacy 4-field form still works ---
t_begin "U: legacy form (no command field) still works"
ns_send U 1000000000000000300 3 9
sleep 0.3
t_eq "3|9" "$(kav_db "$KAV_DB_FILE" "SELECT exit_code||'|'||duration_ms FROM history WHERE id=1000000000000000300;")" "id-only update"

# --- Q: dedup + order ---
ns_send W "qalpha" "$PWD" 2000000000000000001 "s1"
sleep 0.1
ns_send W "qbeta" "$PWD" 2000000000000000002 "s1"
sleep 0.1
ns_send W "qalpha" "$PWD" 2000000000000000003 "s1"
sleep 0.2
t_begin "Q: dedup — one row per distinct command"
rows=$(q_rows 10)
t_eq "2" "$(printf '%s\n' "$rows" | grep -c '^q')" "distinct only"
t_begin "Q: newest occurrence first"
t_eq "qalpha" "$(printf '%s\n' "$rows" | sed -n '1p')" "newest run first"
t_begin "Q: metadata reflects the NEWEST occurrence"
ns_send U 2000000000000000001 1 100
sleep 0.3
raw=$(q_raw 10 qalpha | grep 'qalpha')
t_contains "✓" "$raw" "newest run succeeded, so the marker is ✓"

# --- age units: adaptive ladder (s m h d w mo y) + visible separator ---
# The row id IS the write timestamp (ns-since-epoch), so seeding ids in
# the past pins each unit without sleeping. Values floor within wide
# bands, so only the unit letter is asserted on the sub-minute rows;
# the rollover rows (w/mo/y) are asserted exactly.
age_token() { # age_token PREFIX — the age field of the newest matching row
    # row = "dur ✓/✗ age\x1fcommand\x1fid" — the metadata is the first field
    q_raw 10 "$1" | tr '\037' '\n' | awk 'NR == 1 { print $NF }'
}
now=$(date +%s%N)
ns_send W "age30s" "$PWD" $((now - 30 * 1000000000)) "s1"
ns_send W "age30m" "$PWD" $((now - 1800 * 1000000000)) "s1"
ns_send W "age3h" "$PWD" $((now - 10800 * 1000000000)) "s1"
ns_send W "age3d" "$PWD" $((now - 259200 * 1000000000)) "s1"
ns_send W "age20d" "$PWD" $((now - 20 * 86400 * 1000000000)) "s1"
ns_send W "age100d" "$PWD" $((now - 100 * 86400 * 1000000000)) "s1"
ns_send W "age360d" "$PWD" $((now - 360 * 86400 * 1000000000)) "s1"
ns_send W "age400d" "$PWD" $((now - 400 * 86400 * 1000000000)) "s1"
sleep 0.3
t_begin "age: seconds unit"
case "$(age_token age30s)" in *s) t_ok ;; *) t_fail "got [$(age_token age30s)]" ;; esac
t_begin "age: minutes unit"
case "$(age_token age30m)" in *m) t_ok ;; *) t_fail "got [$(age_token age30m)]" ;; esac
t_begin "age: hours unit"
case "$(age_token age3h)" in *h) t_ok ;; *) t_fail "got [$(age_token age3h)]" ;; esac
t_begin "age: days unit"
case "$(age_token age3d)" in *d) t_ok ;; *) t_fail "got [$(age_token age3d)]" ;; esac
t_begin "age: weeks rollover"
t_eq "2w" "$(age_token age20d)" "20 days floors to 2w"
t_begin "age: months rollover"
t_eq "3mo" "$(age_token age100d)" "100 days floors to 3mo"
t_begin "age: years rollover"
t_eq "1y" "$(age_token age400d)" "400 days floors to 1y"
t_begin "age: a space separates the metadata from the command"
# 360d -> "12mo": a 4-char age, so the %-4s padding is zero and the
# meta's trailing space before the \x1f is the only gap.
sep=$(printf '\037')
t_contains "12mo $sep""age360d" "$(q_raw 10 age360d)" "age, space, separator, command"

# --- Q: prefix filter ---
t_begin "Q: anchored prefix filter"
t_eq "qalpha" "$(q_rows 10 qa)" "prefix qa matches qalpha only"
t_begin "Q: prefix is case-insensitive"
t_eq "qalpha" "$(q_rows 10 QA)" "NOCASE match"
t_begin "Q: LIKE wildcards in the prefix are literal"
ns_send W "100% done" "$PWD" 2000000000000000004 "s1"
sleep 0.2
t_contains "100% done" "$(q_rows 10 '100%')" "percent is not a wildcard"
ns_send W "under_score" "$PWD" 2000000000000000005 "s1"
sleep 0.2
t_eq "under_score" "$(q_rows 10 'under_s')" "underscore is not a wildcard"

# --- Q: scope ---
t_begin "Q: cwd scope matches dir + subtree"
ns_send W "scoped cmd" "/tmp/kavsub" 2000000000000000006 "s1"
sleep 0.2
t_contains "scoped cmd" "$(q_rows 10 '' /tmp/kavsub)" "exact dir"
t_contains "scoped cmd" "$(q_rows 10 '' /tmp)" "subtree"
t_begin "Q: session scope"
t_eq "scoped cmd" "$(q_rows 10 '' '' s1 | grep scoped)" "session filter"

# --- Q: offset ---
t_begin "Q: offset pages through the deduped set"
first=$(q_rows 2 | sed -n '1p')
second=$(q_rows 2 '' '' '' 2 | sed -n '1p')
[ -n "$first" ] && [ -n "$second" ] && [ "$first" != "$second" ] && t_ok || t_fail "pages differ"

# --- D: delete all occurrences ---
t_begin "D: deletes every occurrence, others untouched"
ns_send W "del me" "$PWD" 3000000000000000001 "s1"
sleep 0.1
ns_send W "keep me" "$PWD" 3000000000000000002 "s1"
sleep 0.1
ns_send W "del me" "$PWD" 3000000000000000003 "s1"
sleep 0.2
ns_send D 3000000000000000003
sleep 0.3
t_eq "0" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='del me';")" "all occurrences gone"
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='keep me';")" "other row untouched"
t_begin "D: unknown id is a no-op"
ns_send D 9999999999999999999
sleep 0.3
t_eq "1" "$(kav_db "$KAV_DB_FILE" "SELECT count(*) FROM history WHERE command='keep me';")" "rows untouched"

daemon_stop
t_summary
