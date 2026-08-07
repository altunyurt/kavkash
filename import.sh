#!/bin/sh
# import.sh — import existing history (bash/zsh/fish + atuin) into kavkash DB.
#
# Runs standalone any time (install.sh invokes it when the user opts in).
# Every parsed command becomes a row, duplicates included: shell histories
# legitimately hold the same command many times, and each occurrence keeps
# its own timestamp-derived id (a UUIDv7 minted from the row's original
# timestamp below), so no import step ever suppresses a command.
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
# pseudo-timestamp from a per-parser line counter, so un-timestamped files
# keep their order (newest last = first Up). bash and zsh share counter/
# base 0 because both read $HISTFILE — the same physical lines must get the
# same pseudo-timestamps or the shared file would be imported twice; fish
# and atuin use disjoint bases.
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
    counter=0
    PSEUDO_BASE=2000000000
    f=${1:-}   # explicit --atuin=PATH (plaintext store); else infer
    if [ -z "$f" ]; then
        # Nothing to read? Skip silently: no atuin CLI, no default store,
        # and no config that might point elsewhere. The plaintext path
        # re-resolves db_path from config.toml later.
        cfg="${XDG_CONFIG_HOME:-$HOME/.config}/atuin/config.toml"
        if ! kav_have atuin && [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db" ] && [ ! -f "$cfg" ]; then
            return 0
        fi
        if kav_have atuin; then
            echo "reading atuin history" >&2
        ATUINOUT=$(mktemp "$tmpdir/kavkash-atuin.XXXXXX")
        if atuin history list -r false -f '{time}|{directory}|{duration}|{exit}|{command}' --print0 > "$ATUINOUT" 2> /dev/null && [ -s "$ATUINOUT" ]; then
            tr '\0' '\n' < "$ATUINOUT" \
                | {
                    # atuin {time} is local wall-clock "YYYY-MM-DD HH:MM:SS".
                    # Convert to epoch ms with pure arithmetic (a GNU date
                    # spawn per record cost ~52 s per 50k rows). Howard
                    # Hinnant's days_from_civil (proleptic Gregorian). The
                    # local-TZ offset is constant for ordering purposes;
                    # rows within an hour of a DST switch may swap order,
                    # invisible to the picker.
                    epoch_ms() {
                        s=$1
                        e_y=${s%%-*}; e_r=${s#*-}
                        e_mo=${e_r%%-*}; e_r=${e_r#*-}
                        e_d=${e_r%% *}; e_r=${e_r#* }
                        e_hh=${e_r%%:*}; e_r=${e_r#*:}
                        e_mi=${e_r%%:*}; e_se=${e_r#*:}
                        # strip leading zeros: "08" is invalid octal in $(( ))
                        e_y=${e_y#${e_y%%[1-9]*}};  e_mo=${e_mo#${e_mo%%[1-9]*}}
                        e_d=${e_d#${e_d%%[1-9]*}};  e_hh=${e_hh#${e_hh%%[1-9]*}}
                        e_mi=${e_mi#${e_mi%%[1-9]*}}; e_se=${e_se#${e_se%%[1-9]*}}
                        e_y=$(( e_y - (e_mo <= 2) ))
                        e_era=$(( e_y / 400 ))
                        e_yoe=$(( e_y - e_era * 400 ))
                        e_mp=$(( e_mo + (e_mo > 2 ? -3 : 9) ))
                        e_doy=$(( (153 * e_mp + 2) / 5 + e_d - 1 ))
                        e_doe=$(( e_yoe * 365 + e_yoe / 4 - e_yoe / 100 + e_doy ))
                        e_days=$(( e_era * 146097 + e_doe - 719468 ))
                        e_ts=$(( (e_days * 86400 + e_hh * 3600 + e_mi * 60 + e_se) * 1000 ))
                    }
                    # atuin durations come as "500ms", "1.2s", "45m", "3h" — and
                    # occasionally sub-ms units ("329us") or fractions ("1.5s");
                    # reduce to integer ms, anything unparsable -> 0.
                    dur_ms() {
                        case "$1" in
                            *ms) n=${1%ms} ;;
                            *us | *µs | *ns) echo 0; return ;;
                            *s)  n=${1%s} ;;
                            *m)  n=${1%m} ;;
                            *h)  n=${1%h} ;;
                            *)   echo 0; return ;;
                        esac
                        n=${n%%.*}
                        case "$n" in *[!0-9]*) echo 0; return ;; esac
                        case "$1" in
                            *ms) echo "$n" ;;
                            *s)  echo $(( n * 1000 )) ;;
                            *m)  echo $(( n * 60000 )) ;;
                            *h)  echo $(( n * 3600000 )) ;;
                        esac
                    }
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
                                # "2026-08-02 05:09:14" -> epoch ms, arithmetic
                                # only (no date subprocess per record)
                                case "$t" in
                                    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]:[0-9][0-9])
                                        epoch_ms "$t"
                                        ;;
                                    *) e_ts="" ;;
                                esac
                                p_ts=$e_ts
                                p_dur=$(dur_ms "$dur")
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
        # No CLI (or nothing read): fall through to plaintext SQLite.
        # Resolve the DB path like atuin does (config.toml db_path, else
        # the default). The IFS='|' read keeps command LAST: commands may
        # contain '|' and read assigns the remainder to the final variable.
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
    else
        # Explicit --atuin=PATH: read that file directly (plaintext schema).
        [ -f "$f" ] || { echo "import.sh: atuin db not found: $f" >&2; return 0; }
    fi
    echo "reading atuin history ($f)" >&2
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

# --- source selection --------------------------------------------------------
# Sources are selected explicitly; with no options the usage is printed
# (no flags == --help). install.sh passes --all so a plain install import
# keeps working.
usage() {
    cat <<'EOF'
usage: import.sh [OPTION...]

Import shell/atuin history into the kavkash database. Sources must be
selected explicitly; with no options this help is printed.

  -b, --bash          import bash history (${HISTFILE:-~/.bash_history})
  -z, --zsh           import zsh history (${HISTFILE:-~/.zsh_history})
  -f, --fish          import fish history (fish_history)
      --atuin         import atuin history (store inferred: config.toml
                      db_path, else the default; the atuin CLI is preferred
                      because v18+ stores are PASETO-encrypted)
      --atuin=PATH    import atuin from PATH directly (plaintext
                      history/history_v2 sqlite store; no CLI, no config)
      --all           shorthand for -b -z -f --atuin
  -h, --help          show this help and exit

The import is additive: every parsed command becomes a row, duplicates
included.
EOF
}

want_bash=0; want_zsh=0; want_fish=0; want_atuin=0; atuin_db=""
for a in "$@"; do
    case "$a" in
        -b | --bash)        want_bash=1 ;;
        -z | --zsh)         want_zsh=1 ;;
        -f | --fish)        want_fish=1 ;;
        --atuin)            want_atuin=1 ;;
        --atuin=*)          want_atuin=1; atuin_db=${a#--atuin=} ;;
        --all)              want_bash=1; want_zsh=1; want_fish=1; want_atuin=1 ;;
        -h | --help)        usage; exit 0 ;;
        *) echo "import.sh: unknown option: $a" >&2; usage >&2; exit 2 ;;
    esac
done
[ "$want_bash$want_zsh$want_fish$want_atuin" = "0000" ] && { usage; exit 0; }

[ "$want_bash" = 1 ] && import_bash
[ "$want_zsh" = 1 ] && import_zsh
[ "$want_fish" = 1 ] && import_fish
[ "$want_atuin" = 1 ] && import_atuin "$atuin_db"

[ -s "$ENTRIES" ] || { echo "nothing to import (no history found)"; exit 0; }
total=$(tr -cd '\036' < "$ENTRIES" | wc -c)
echo "parsed $total commands" >&2

# Bulk insert in a single sqlite3 session. Every row is inserted as-is —
# duplicates are deliberately NOT suppressed. atuin rows (src=A) first
# enrich any existing cwd-less row (a bash/zsh/fish import may already hold
# the same command without a path), then insert their own row with the
# atuin metadata. The SQL is generated by ONE awk pass — it reads the
# 0x1E/0x1F-framed ENTRIES directly (no per-row base64/sed spawns; a 50k-
# command import now takes seconds) and emits the statements below. Each id
# is a UUIDv7 minted from the row's own timestamp, so the imported
# chronology maps onto the id ordering (ORDER BY id DESC == time order).
# The SQL printf() format specifiers (%08x …) are escaped as %% for AWK's
# printf; the ts arithmetic itself happens inside sqlite, not in awk.
AWKPROG=$(mktemp "$tmpdir/kavkash-awk.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT" "$AWKPROG"; [ -n "${KAV_TMP_IDX:-}" ] && sqlite3 "$DB" "DROP INDEX IF EXISTS idx_import_cmd;"' EXIT
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
    printf "INSERT INTO history (id, command, cwd, exit_code, duration_ms) VALUES (printf('%%08x-%%04x-%%04x-%%04x-%%012x', (%s >> 16) & 0xffffffff, %s & 0xffff, 0x7000 | (abs(random()) & 0x0fff), 0xa000 | (abs(random()) & 0x0fff), abs(random()) & 0xffffffffffff), '%s', '%s', %s, %s);\n", ts, ts, cmd, cwd, dur, exitc
}
EOF
if kav_have pv; then
    pv -N "sql" "$ENTRIES" | awk -f "$AWKPROG" > "$SQLOUT"
else
    awk -f "$AWKPROG" "$ENTRIES" > "$SQLOUT"
fi

echo "inserting $total commands" >&2
# Index hygiene around the bulk load (matters more on re-imports of an
# already-large table):
#   - idx_import_dedup is a leftover from older imports — nothing queries
#     that expression index anymore, but every INSERT still maintains it.
#     Drop it once; it never comes back.
#   - the atuin enrichment UPDATE probes WHERE command='...' — a plain
#     index on command turns that from a full table scan per atuin row
#     (5000 atuin rows against a 100k-row table: 72 s) into a lookup
#     (~5 s). It is dropped again after the load so the live daemon never
#     pays index maintenance on its per-command INSERTs. Built only when
#     atuin rows are present (the generated SQL contains their UPDATEs).
sqlite3 "$DB" "DROP INDEX IF EXISTS idx_import_dedup;"
if grep -q '^UPDATE history SET' "$SQLOUT"; then
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_import_cmd ON history(command);"
    KAV_TMP_IDX=1
fi
n_before=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
{
    echo "BEGIN;"
    if kav_have pv; then
        pv -N "insert" "$SQLOUT"
    else
        cat "$SQLOUT"
    fi
    echo "COMMIT;"
} | sqlite3 "$DB"
if [ -n "${KAV_TMP_IDX:-}" ]; then sqlite3 "$DB" "DROP INDEX IF EXISTS idx_import_cmd;"; fi
n_after=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
new=$((n_after - n_before))
printf 'imported %d commands into %s\n' "$new" "$DB"
