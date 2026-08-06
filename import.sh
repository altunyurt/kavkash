#!/bin/sh
# import.sh — import existing history (bash/zsh/fish + atuin) into kavkash DB.
#
# Runs standalone any time (install.sh invokes it when the user opts in) and
# is idempotent: rows already in the DB are skipped, matching on
# (command, timestamp) — the timestamp lives in the imported row's UUIDv7 id
# — so re-running an import adds nothing, while distinct invocations of the
# same command (different timestamps) are all kept.
#
# Sources and their formats:
#   bash  ~/.bash_history            plain lines, or "#<epoch>" + line pairs
#                                    when HISTTIMEFORMAT was set
#   zsh   ${HISTFILE:-~/.zsh_history} plain lines, or extended ": <epoch>:<dur>;<cmd>"
#   fish  ${XDG_DATA_HOME}/fish/fish_history   YAML: "- cmd:", "  when:", "  paths:"
#   atuin (v17-): records.db absent, plaintext SQLite (history / history_v2)
#   atuin (v18+): records.db — history is PASETO-encrypted, so it is read via
#                 the atuin CLI ("history list -f ... --print0") which decrypts

set -eu

# Paths from includes.sh (same dir as this script).
. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

DB="$KAV_DB_FILE"

kav_have sqlite3 || kav_die "sqlite3 required for history import"

# Ensure the schema exists (same as server.sh) so import works before the
# first server run. Imported rows get a UUIDv7 id minted from their original
# timestamp in SQL below, so ordering survives.
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS history (
    id TEXT PRIMARY KEY,
    command TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL
);"

tmpdir=${TMPDIR:-/tmp}
ENTRIES=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
SQLOUT=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT"' EXIT

# emit <epoch_ms> <cmd> [<cwd> [<dur_ms> <exit> <src>]]
# src=A marks atuin-sourced rows: their cwd/duration enrich existing rows
# (see INSERT loop). Commands without a real timestamp get a deterministic
# pseudo-timestamp from a per-parser line counter: un-timestamped files
# keep their order (newest last = first Up) and a re-import of the same
# files produces the same pseudo-timestamps, so the dedup stays idempotent.
# bash and zsh share counter/base 0 because both read $HISTFILE — the same
# physical lines must get the same pseudo-timestamps or the shared file
# would be imported twice; fish and atuin use disjoint bases.
#
# ENTRIES records are framed with 0x1E (record) / 0x1F (field) separators
# instead of base64: shell-history commands never carry those bytes (and
# processor.sh strips them anyway), and it lets the whole parse phase run
# without spawning a subprocess per line.
counter=0
PSEUDO_BASE=0

emit() {
    counter=$((counter + 1))
    ts=$1
    cmd=$2
    cwd=${3:-}
    dur=${4:-}
    exit=${5:-}
    src=${6:-}
    [ -n "$cmd" ] || return 0
    case "$ts" in '' | *[!0-9]*) ts=$((PSEUDO_BASE + counter)) ;; esac
    printf '%s\037%s\037%s\037%s\037%s\037%s\036' "$ts" "$cmd" "$cwd" "$dur" "$exit" "$src" >> "$ENTRIES"
}

import_bash() {
    f="${HISTFILE:-$HOME/.bash_history}"
    [ -f "$f" ] || return 0
    echo "reading $f ($(wc -l < "$f") lines)" >&2
    prev_ts=""
    counter=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*)
                prev_ts=${line#\#}
                case "$prev_ts" in *[!0-9]*) prev_ts="" ;; esac
                ;;
            ": "[0-9]*:[0-9]*\;*)
                # zsh extended-format line — not ours, skip (and don't
                # treat the next line as if a # timestamp preceded it)
                prev_ts=""
                ;;
            *)
                [ -z "$line" ] && { prev_ts=""; continue; }
                emit "$prev_ts" "$line"
                prev_ts=""
                ;;
        esac
    done < "$f"
}

import_zsh() {
    f="${HISTFILE:-$HOME/.zsh_history}"
    [ -f "$f" ] || return 0
    echo "reading $f ($(wc -l < "$f") lines)" >&2
    counter=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "#"*) # bash HISTTIMEFORMAT marker — not ours, skip
                continue
                ;;
            ": "*) # extended: ": <epoch>:<duration>;<command>"
                rest=${line#": "}
                ts=${rest%%:*}
                cmd=${rest#*:}
                cmd=${cmd#*;}
                ;;
            *)
                ts=""
                cmd=$line
                ;;
        esac
        [ -z "$cmd" ] && continue
        emit "$ts" "$cmd"
    done < "$f"
}

import_fish() {
    f="${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history"
    [ -f "$f" ] || return 0
    echo "reading $f" >&2
    ts=""
    cmd=""
    counter=0
    PSEUDO_BASE=1000000000
    flush() {
        [ -n "$cmd" ] || return 0
        emit "$ts" "$cmd"
    }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "- cmd: "*)
                flush
                cmd=${line#"- cmd: "}
                ts=""
                ;;
            "  when: "*)
                ts=${line#"  when: "}
                case "$ts" in *[!0-9]*) ts="" ;; esac
                [ -n "$ts" ] && ts=$((ts * 1000)) # fish stores epoch seconds
                ;;
            "  paths:"*)
                : # ignore path lists
                ;;
        esac
    done < "$f"
    flush
}

import_atuin() {
    # Nothing to read? Skip silently: no atuin CLI, no default store, and
    # no config that might point elsewhere. The plaintext path re-resolves
    # db_path from config.toml later.
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/atuin/config.toml"
    if ! kav_have atuin && [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db" ] && [ ! -f "$cfg" ]; then
        return 0
    fi
    echo "reading atuin history" >&2
    counter=0
    PSEUDO_BASE=2000000000
    if kav_have atuin; then
        ATUINOUT=$(mktemp "$tmpdir/kavkash-atuin.XXXXXX")
        if atuin history list -r false -f '{time}|{directory}|{duration}|{exit}|{command}' --print0 > "$ATUINOUT" 2> /dev/null && [ -s "$ATUINOUT" ]; then
            tr '\0' '\n' < "$ATUINOUT" \
                | {
                    pending=""
                    while IFS= read -r line || [ -n "$line" ]; do
                        case "$line" in
                            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
                                # start of a new record: flush the previous one
                                if [ -n "$pending" ]; then
                                    emit "$p_ts" "$pending" "$p_dir" "$p_dur" "$p_exit" A
                                fi
                                t=${line%%|*};   rest=${line#*|}
                                p_dir=${rest%%|*}; rest=${rest#*|}
                                dur=${rest%%|*};  rest=${rest#*|}
                                p_exit=${rest%%|*}; pending=${rest#*|}
                                # "2026-08-02 05:09:14" -> epoch ms (GNU date)
                                p_ts=$(date -d "$t" +%s%3N 2> /dev/null || true)
                                case "$dur" in
                                    *ms) p_dur=${dur%ms} ;;
                                    *s)  p_dur=$(( ${dur%s} * 1000 )) ;;
                                    *m)  p_dur=$(( ${dur%m} * 60000 )) ;;
                                    *h)  p_dur=$(( ${dur%h} * 3600000 )) ;;
                                    *)   p_dur=0 ;;
                                esac
                                ;;
                            *)
                                # continuation line of a multiline command
                                [ -n "$pending" ] && pending="$pending
$line"
                                ;;
                        esac
                    done
                    [ -n "$pending" ] && emit "$p_ts" "$pending" "$p_dir" "$p_dur" "$p_exit" A || true
                }
            rm -f "$ATUINOUT"
            return 0
        fi
        rm -f "$ATUINOUT"
    fi
    # No CLI (or nothing read): read plaintext SQLite directly. Resolve the
    # DB path like atuin does (config.toml db_path, else the default). The
    # IFS='|' read keeps command LAST: commands may contain '|' and read
    # assigns the remainder to the final variable.
    data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/atuin"
    f="$data_dir/history.db"
    if [ -f "$cfg" ]; then
        db=$(sed -n 's/^[[:space:]]*db_path[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$cfg" | head -1)
        [ -n "$db" ] && f=$db
    fi
    case "$f" in
        "~/"*) f="$HOME/${f#"~/"}" ;;
    esac
    f=$(printf '%s' "$f" | sed "s/\$USER/$USER/g")
    [ -f "$f" ] || return 0
    # schema variants: history_v2 (atuin v14-17) / history (v18+ and v1)
    table=""
    for t in history_v2 history; do
        if sqlite3 "$f" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t';" | grep -q 1; then
            table=$t
            break
        fi
    done
    [ -n "$table" ] || return 0
    # atuin v18+ stores ns timestamps; older versions use ms. Detect from data.
    ns=$(sqlite3 "$f" "SELECT max(timestamp) FROM $table;")
    div=1
    [ "${#ns}" -gt 16 ] && div=1000000
    # cwd may be NULL in some versions. Order by timestamp so the import
    # follows atuin's chronology even if the table's rowid order differs.
    # exit/duration come before command — command must stay the LAST field so
    # pipe-containing commands survive the IFS='|' read. Records start with
    # the numeric ts; any line without it is a continuation of the previous
    # command (multiline commands) and is re-attached like the CLI path does.
    sqlite3 -noheader "$f" "SELECT CAST(timestamp/$div AS INTEGER), COALESCE(cwd,''), exit, CAST(COALESCE(duration,0)/$div AS INTEGER), command FROM $table ORDER BY timestamp ASC;" \
        | {
            pending=""
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    [0-9]*\|*)
                        # start of a new record: flush the previous one
                        if [ -n "$pending" ]; then
                            emit "$p_ts" "$pending" "$p_cwd" "$p_dur" "$p_exit" A
                        fi
                        p_ts=${line%%|*}; rest=${line#*|}
                        p_cwd=${rest%%|*}; rest=${rest#*|}
                        p_exit=${rest%%|*}; rest=${rest#*|}
                        p_dur=${rest%%|*}; pending=${rest#*|}
                        ;;
                    *)
                        # continuation line of a multiline command
                        [ -n "$pending" ] && pending="$pending
$line"
                        ;;
                esac
            done
            [ -n "$pending" ] && emit "$p_ts" "$pending" "$p_cwd" "$p_dur" "$p_exit" A || true
        }
}

import_bash
import_zsh
import_fish
import_atuin

[ -s "$ENTRIES" ] || { echo "nothing to import (no history found)"; exit 0; }
total=$(tr -cd '\036' < "$ENTRIES" | wc -c)
echo "parsed $total commands" >&2

# Bulk insert in a single sqlite3 session; NOT EXISTS skips duplicates.
# atuin rows (src=A) first enrich any existing cwd-less row (a bash/zsh/fish
# import may already hold the same command without a path), then insert if
# the command is still unknown. The SQL is generated by ONE awk pass — it
# reads the 0x1E/0x1F-framed ENTRIES directly (no per-row base64/sed
# spawns; a 50k-command import now takes seconds) and emits the statements
# below. The id is a UUIDv7 minted from the row's own timestamp, so the imported
# chronology maps onto the id ordering (ORDER BY id DESC == time order).
# Dedup is on (command, ts): the timestamp lives in the id's first 48 bits
# (chars 1-13), so the NOT EXISTS test is against that prefix. cwd is
# deliberately NOT part of the key: the atuin enrichment UPDATE moves rows
# from cwd='' to their real cwd, and a re-import must still dedup against
# the enriched state or every re-import would re-insert those commands.
# Distinct invocations stay distinct because their timestamps differ.
# The SQL printf() format specifiers (%08x …) are escaped as %% for AWK's
# printf; the ts arithmetic itself happens inside sqlite, not in awk.
AWKPROG=$(mktemp "$tmpdir/kavkash-awk.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT" "$AWKPROG"' EXIT
cat > "$AWKPROG" <<'EOF'
BEGIN {
    RS = "\036"   # 0x1E record separator (matches emit)
    FS = "\037"   # 0x1F field separator
}
{
    cmd = $2
    if (cmd == "") next
    gsub(/'/, "''", cmd)
    cwd = $3
    gsub(/'/, "''", cwd)
    ts = $1
    dur = $4 + 0
    exitc = $5 + 0
    if ($6 == "A")
        printf "UPDATE history SET cwd='%s', duration_ms=%s, exit_code=%s WHERE command='%s' AND cwd='';\n", cwd, dur, exitc, cmd
    printf "INSERT INTO history (id, command, cwd, exit_code, duration_ms) SELECT printf('%%08x-%%04x-%%04x-%%04x-%%012x', (%s >> 16) & 0xffffffff, %s & 0xffff, 0x7000 | (abs(random()) & 0x0fff), 0xa000 | (abs(random()) & 0x0fff), abs(random()) & 0xffffffffffff), '%s', '%s', %s, %s WHERE NOT EXISTS (SELECT 1 FROM history WHERE command = '%s' AND substr(id, 1, 13) = printf('%%08x-%%04x', (%s >> 16) & 0xffffffff, %s & 0xffff));\n", ts, ts, cmd, cwd, dur, exitc, cmd, ts, ts
}
EOF
awk -f "$AWKPROG" "$ENTRIES" > "$SQLOUT"

echo "inserting $total commands" >&2
n_before=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
{
    # dedup index: the NOT EXISTS probe below becomes O(log n); without it a
    # big import degrades to a full scan per row. The expression index also
    # speeds up the atuin enrichment UPDATE and the live picker's UPDATEs.
    echo "CREATE INDEX IF NOT EXISTS idx_import_dedup ON history(command, substr(id, 1, 13));"
    echo "BEGIN;"
    cat "$SQLOUT"
    echo "COMMIT;"
} | sqlite3 "$DB"
n_after=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
new=$((n_after - n_before))
printf 'imported %d new commands (duplicates skipped) into %s\n' "$new" "$DB"
