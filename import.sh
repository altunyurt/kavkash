#!/bin/sh
# import.sh — import shell/atuin history into the kavkash DB.
# Additive: every parsed command becomes a row, duplicates included; each
# occurrence keeps its own timestamp-derived UUIDv7 id.
#
# Sources:
#   bash  ~/.bash_history             plain lines, or "#<epoch>" pairs (HISTTIMEFORMAT)
#   zsh   ${HISTFILE:-~/.zsh_history} plain lines, or ": <epoch>:<dur>;<cmd>"
#   fish  ${XDG_DATA_HOME}/fish/fish_history  YAML entries
#   atuin v17-: plaintext SQLite (history / history_v2), read directly
#   atuin v18+: PASETO-encrypted, read via the atuin CLI which decrypts

set -eu

. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

DB="$KAV_DB_FILE"

kav_have sqlite3 || kav_die "sqlite3 required for history import"

# Same schema as server.sh, so import works before the daemon's first run.
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
ATUINPARSE=$(mktemp "$tmpdir/kavkash-atuin-parse.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT" "$ATUINPARSE"' EXIT

cat > "$ATUINPARSE" <<'EOF'
BEGIN { RS = "\n" }

# flush the pending record; invalid timestamps get a pseudo-ts
function flush(   ts) {
    if (pending == "") return
    if (p_ts !~ /^[0-9]+$/) ts = PSEUDO + n; else ts = p_ts
    printf "%s\037%s\037%s\037%s\037%s\037A\036", ts, pending, p_cwd, p_dur, p_exit
    n++
    pending = ""
}

# wall-clock "YYYY-MM-DD HH:MM:SS" -> epoch ms, pure arithmetic
# (proleptic Gregorian; UTC keeps a constant TZ offset so ordering is
# preserved — rows within an hour of a DST switch may swap, invisible)
function epoch_ms(s,   y, mo, d, hh, mi, se, era, yoe, mp, doy, doe, days) {
    y  = substr(s, 1, 4) + 0
    mo = substr(s, 6, 2) + 0
    d  = substr(s, 9, 2) + 0
    hh = substr(s, 12, 2) + 0
    mi = substr(s, 15, 2) + 0
    se = substr(s, 18, 2) + 0
    y -= (mo <= 2)
    era = int(y / 400)
    yoe = y - era * 400
    mp = mo + (mo > 2 ? -3 : 9)
    doy = int((153 * mp + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    days = era * 146097 + doe - 719468
    return (days * 86400 + hh * 3600 + mi * 60 + se) * 1000
}

# atuin durations ("500ms", "1.2s", "45m", "3h", "329us") -> integer ms
function dur_ms(d,   u, x) {
    if (d ~ /ms$/)              { u = 1;       x = d; sub(/ms$/, "", x) }
    else if (d ~ /us$|µs$|ns$/) return 0
    else if (d ~ /s$/)          { u = 1000;    x = d; sub(/s$/, "", x) }
    else if (d ~ /m$/)          { u = 60000;   x = d; sub(/m$/, "", x) }
    else if (d ~ /h$/)          { u = 3600000; x = d; sub(/h$/, "", x) }
    else return 0
    x = int(x)
    if (x !~ /^[0-9]+$/) return 0
    return x * u
}

{
    start = 0
    if (MODE == "cli") {
        if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) start = 1
    } else if ($0 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\|/) {
        start = 1
    }
    if (start) {
        flush()
        nf = split($0, F, "|")
        p_ts = F[1]
        p_cwd = F[2]
        if (MODE == "cli") { p_dur = dur_ms(F[3]); p_exit = F[4] }
        else               { p_exit = F[3]; p_dur = F[4] + 0 }
        pending = F[5]
        for (i = 6; i <= nf; i++) pending = pending "|" F[i]
        if (MODE == "cli") {
            if (p_ts ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/)
                p_ts = epoch_ms(p_ts)
            else
                p_ts = ""
        } else if (p_ts !~ /^[0-9]+$/) {
            p_ts = ""
        }
    } else if (pending != "") {
        pending = pending "\n" $0
    }
}

END { flush() }
EOF



# emit <epoch_ms> <cmd> [<cwd> [<dur_ms> <exit> <src>]]
# src=A marks atuin rows: their cwd/duration enrich existing rows.
# Invalid timestamps get a per-parser pseudo-ts (bash+zsh share base 0 —
# both read $HISTFILE; fish and atuin use disjoint bases).
# ENTRIES framing: 0x1E record / 0x1F field — commands can't contain those
# bytes, so parsing needs no per-line subprocesses.
counter=0
PSEUDO_BASE=0

exec 3>> "$ENTRIES"   # emit's output fd — open once, not per record
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
    printf '%s\037%s\037%s\037%s\037%s\037%s\036' "$ts" "$cmd" "$cwd" "$dur" "$exit" "$src" >&3
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
                # zsh extended-format line; not ours
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
            "#"*) # bash marker; not ours
                continue
                ;;
            ": "*) # extended: ": <epoch>:<dur>;<cmd>"
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
    if [ -n "$f" ]; then
        # Explicit --atuin=PATH: skip guard/CLI/config — read PATH directly.
        :
    else
        # Infer mode only — never reached for an explicit path.
        cfg="${XDG_CONFIG_HOME:-$HOME/.config}/atuin/config.toml"
        if ! kav_have atuin && [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db" ] && [ ! -f "$cfg" ]; then
            return 0
        fi
        if kav_have atuin; then
            echo "reading atuin history" >&2
            ATUINOUT=$(mktemp "$tmpdir/kavkash-atuin.XXXXXX")
            if atuin history list -r false -f '{time}|{directory}|{duration}|{exit}|{command}' --print0 > "$ATUINOUT" 2> /dev/null && [ -s "$ATUINOUT" ]; then
                        # Parse with one awk process (the old shell loop forked a
            # subshell per duration: ~16 s per 40k records).
            tr '\0' '\n' < "$ATUINOUT" \
                | awk -v MODE=cli -v PSEUDO="$PSEUDO_BASE" -f "$ATUINPARSE" >> "$ENTRIES"
            rm -f "$ATUINOUT"
            return 0
        fi
        rm -f "$ATUINOUT"
    fi
        # Fallback: read plaintext SQLite directly (config.toml db_path,
        # else the default).
        data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/atuin"
        f="$data_dir/history.db"
        if [ -f "$cfg" ]; then
            db=$(sed -n 's/^[[:space:]]*db_path[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$cfg" | head -1)
            [ -n "$db" ] && f=$db
        fi
    fi
    # Expand ~/ and $USER (an explicit path may carry a literal tilde).
    case "$f" in
        "~/"*) f="$HOME/${f#"~/"}" ;;
    esac
    f=$(printf '%s' "$f" | sed "s/\$USER/$USER/g")
    if [ ! -f "$f" ]; then
        [ -n "$1" ] && echo "import.sh: atuin db not found: $f" >&2
        return 0
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
    # v18+ stores ns timestamps, older ms — detect from data.
    ns=$(sqlite3 "$f" "SELECT max(timestamp) FROM $table;")
    div=1
    [ "${#ns}" -gt 16 ] && div=1000000
    # cwd may be NULL. command stays LAST so pipes survive the IFS='|'
    # read; lines without a leading ts are multiline continuations.
    sqlite3 -noheader "$f" "SELECT CAST(timestamp/$div AS INTEGER), COALESCE(cwd,''), exit, CAST(COALESCE(duration,0)/$div AS INTEGER), command FROM $table ORDER BY timestamp ASC;" \
        | awk -v MODE=plain -v PSEUDO="$PSEUDO_BASE" -f "$ATUINPARSE" >> "$ENTRIES"
}

# --- source selection (no flags == --help; install.sh passes --all) --------
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

# Bulk insert in one sqlite3 session, via one awk pass over ENTRIES.
# Every row is inserted as-is (additive, no dedup). atuin rows (src=A)
# first enrich any existing cwd-less row. The id is a UUIDv7 minted from
# the row's timestamp (ORDER BY id DESC == time order). SQL printf()
# specifiers are %% for awk; ts arithmetic happens inside sqlite.
AWKPROG=$(mktemp "$tmpdir/kavkash-awk.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT" "$AWKPROG" "$ATUINPARSE"; [ -n "${KAV_TMP_IDX:-}" ] && sqlite3 "$DB" "DROP INDEX IF EXISTS idx_import_cmd;"' EXIT
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

# atuin parse: atuin CLI output (MODE=cli) or direct sqlite rows
# (MODE=plain) -> ENTRIES frames (0x1E record / 0x1F field). A record
# starts with a timestamp line; other lines continue the previous record
# (multiline commands). The command field is everything after the 4th
# '|' — commands may contain '|'.
if kav_have pv; then
    pv -N "sql" "$ENTRIES" | awk -f "$AWKPROG" > "$SQLOUT"
else
    awk -f "$AWKPROG" "$ENTRIES" > "$SQLOUT"
fi

echo "inserting $total commands" >&2
# Index hygiene: drop the legacy idx_import_dedup (unused, but every
# INSERT maintains it). The atuin enrichment UPDATE probes WHERE
# command='...' — a plain command index turns that from a full scan per
# row into a lookup; dropped after the load so the live daemon pays no
# maintenance, built only when atuin rows are present.
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
