#!/bin/sh
# import.sh — import shell/atuin history into the kavkash DB.
# Idempotent: re-running imports nothing new — rows deduplicate on
# (command, cwd, timestamp), while the same command at different times
# keeps every occurrence. Each row's id is the ns-since-epoch timestamp
# (INTEGER PRIMARY KEY, so the table itself is stored in time order).
#
# Sources:
#   bash  ~/.bash_history             plain lines, or "#<epoch>" pairs (HISTTIMEFORMAT)
#   zsh   ${HISTFILE:-~/.zsh_history} plain lines, or ": <epoch>:<dur>;<cmd>"
#   fish  ${XDG_DATA_HOME}/fish/fish_history  YAML entries
#   atuin                            read via the atuin CLI, which decrypts
#                                    v18+ PASETO stores; the store layout
#                                    varies by version, so the CLI is the
#                                    only stable reader

set -eu

. "$(dirname -- "$(realpath -- "$0")")/includes.sh"

DB="$KAV_DB_FILE"

kav_have sqlite3 || kav_die "sqlite3 required for history import"

# Same schema as server.sh, so import works before the daemon's first run.
kav_ensure_history_schema

tmpdir=${TMPDIR:-/tmp}
ENTRIES=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
SQLOUT=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
ATUINPARSE=$(mktemp "$tmpdir/kavkash-atuin-parse.XXXXXX")
DBMAP=$(mktemp "$tmpdir/kavkash-dbmap.XXXXXX")
DAYS=""; OFFS=""; ATUINOUT=""   # atuin temp files (per-day TZ offset map)
trap 'rm -f "$ENTRIES" "$SQLOUT" "$ATUINPARSE" "$DBMAP" "$ATUINOUT" "$DAYS" "$OFFS"' EXIT

cat > "$ATUINPARSE" <<'EOF'
BEGIN {
    RS = "\n"
    if (OFFMAP != "") {
        # per-day local-UTC offsets ("YYYY-MM-DD +HHMM"); missing -> 0.
        # Parse "+HHMM" as minutes: +0300 = 180, not 300.
        while ((getline l < OFFMAP) > 0) {
            split(l, m, " ")
            offmap[m[1]] = off_min(m[2])
        }
        close(OFFMAP)
    }
}

function off_min(s,   sign, hh, mm) {
    sign = (substr(s, 1, 1) == "-") ? -1 : 1
    hh = substr(s, 2, 2) + 0
    mm = substr(s, 4, 2) + 0
    return sign * (hh * 60 + mm)
}

# flush the pending record; invalid timestamps get a pseudo-ts
function flush(   ts) {
    if (pending == "") return
    if (p_ts !~ /^[0-9]+$/) ts = (PSEUDO + n) "000000"; else ts = p_ts
    printf "%s\037%s\037%s\037%s\037%s\037A\036", ts, pending, p_cwd, p_dur, p_exit
    n++
    pending = ""
}

# wall-clock "YYYY-MM-DD HH:MM:SS" -> epoch ms, pure arithmetic
# (proleptic Gregorian). atuin {time} is LOCAL wall-clock: the caller
# passes per-day UTC offsets, which are subtracted here, so the result
# is the real epoch on any host (constant offsets, and ±1h for a few
# hours on the two DST-transition days per year). The caller appends
# "000000" to make the ns id.
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

# atuin CLI record: "YYYY-MM-DD HH:MM:SS|cwd|duration|exit|command" —
# the command is everything after the 4th '|' and may contain '|'. Other
# lines continue the previous record (multiline commands).
$0 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    flush()
    nf = split($0, F, "|")
    p_ts = F[1]
    p_cwd = F[2]
    p_dur = dur_ms(F[3])
    p_exit = F[4]
    pending = F[5]
    for (i = 6; i <= nf; i++) pending = pending "|" F[i]
    if (p_ts ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/)
        # epoch_ms yields ms; append 6 digits for ns. String
        # concat, not arithmetic: 19 digits exceed awk's double.
        p_ts = (epoch_ms(p_ts) - offmap[substr(F[1], 1, 10)] * 60000) "000000"
    else
        p_ts = ""
    next
}
pending != "" { pending = pending "\n" $0 }

END { flush() }
EOF



# emit <ts_ns> <cmd> [<cwd> [<dur_ms> <exit> <src>]]
# ts is the ns-since-epoch id (= timestamp). Invalid timestamps get a
# per-parser pseudo-ts, scaled to ns: bash 0, zsh 3e9, fish 1e9, atuin
# 2e9 — disjoint bases, so equal counters across parsers can't collide
# on the PK.
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
    # Shell convention: a command starting with whitespace is never saved
    # (see hook.sh W). Only the first character decides — indented
    # continuation lines of a multi-line command are unaffected.
    case "$cmd" in
        ' '* | '	'*) return 0 ;;
    esac
    case "$ts" in '' | *[!0-9]*) ts=$(((PSEUDO_BASE + counter) * 1000000)) ;; esac
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
                [ -n "$prev_ts" ] && prev_ts=$((prev_ts * 1000000000)) # s -> ns
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
    PSEUDO_BASE=3000000000
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
                [ -n "$ts" ] && ts=$((ts * 1000000000)) # s -> ns
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
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "- cmd: "*)
                [ -n "$cmd" ] && emit "$ts" "$cmd"
                cmd=${line#"- cmd: "}
                ts=""
                ;;
            "  when: "*)
                ts=${line#"  when: "}
                case "$ts" in *[!0-9]*) ts="" ;; esac
                [ -n "$ts" ] && ts=$((ts * 1000000000)) # fish stores epoch seconds
                ;;
            "  paths:"*)
                : # ignore path lists
                ;;
        esac
    done < "$f"
    [ -n "$cmd" ] && emit "$ts" "$cmd"
}

import_atuin() {
    counter=0
    PSEUDO_BASE=2000000000
    if ! kav_have atuin; then
        echo "skipping atuin: CLI not found (it resolves the store and decrypts v18+ stores)" >&2
        return 0
    fi
    echo "reading atuin history" >&2
    ATUINOUT=$(mktemp "$tmpdir/kavkash-atuin.XXXXXX")
    # The CLI is the only stable reader: the store layout varies by version
    # (plaintext history table, PASETO-encrypted rows, sync-v2 records.db),
    # and the CLI resolves the real db path and key from its own config.
    if atuin history list -r false -f '{time}|{directory}|{duration}|{exit}|{command}' --print0 > "$ATUINOUT" 2> /dev/null; then
        [ -s "$ATUINOUT" ] || return 0   # empty store — nothing to import
        # atuin {time} is LOCAL wall-clock; subtract the local UTC
        # offset from the UTC-interpreted epoch (per unique day, one
        # date call — exact except a few hours on DST-transition
        # days). Without GNU date, fall back to one constant offset.
        DAYS=$(mktemp "$tmpdir/kavkash-atuin-days.XXXXXX")
        OFFS=$(mktemp "$tmpdir/kavkash-atuin-offs.XXXXXX")
        tr '\0' '\n' < "$ATUINOUT" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u > "$DAYS"
        if [ -s "$DAYS" ]; then
            ok=1
            while IFS= read -r d; do
                off=$(date -d "$d 12:00:00" +%z 2>/dev/null) || { ok=0; break; }
                printf '%s %s\n' "$d" "$off"
            done < "$DAYS" > "$OFFS"
            if [ "$ok" = 0 ]; then
                off=$(date +%z 2>/dev/null)
                while IFS= read -r d; do printf '%s %s\n' "$d" "$off"; done < "$DAYS" > "$OFFS"
            fi
        fi
        # Single awk pass (a per-record shell loop took ~16 s per 40k).
        tr '\0' '\n' < "$ATUINOUT" \
            | awk -v PSEUDO="$PSEUDO_BASE" -v OFFMAP="$OFFS" -f "$ATUINPARSE" >> "$ENTRIES"
        rm -f "$ATUINOUT"
        return 0
    fi
    rm -f "$ATUINOUT"
    echo "atuin: CLI failed to read the store" >&2
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
      --atuin         import atuin history (requires the `atuin` CLI: the
                      store layout varies by version and v18+ stores are
                      PASETO-encrypted, so the CLI is the only stable
                      reader — it resolves the store and key itself)
      --all           shorthand for -b -z -f --atuin
  -h, --help          show this help and exit

Idempotent: re-running imports nothing new. Rows deduplicate on
(command, cwd, timestamp) — the same command at different times is kept.
EOF
}

want_bash=0; want_zsh=0; want_fish=0; want_atuin=0
for a in "$@"; do
    case "$a" in
        -b | --bash)        want_bash=1 ;;
        -z | --zsh)         want_zsh=1 ;;
        -f | --fish)        want_fish=1 ;;
        --atuin)            want_atuin=1 ;;
        --atuin=*)
            echo "import.sh: --atuin=PATH was removed — atuin history is read via the atuin CLI" >&2
            exit 2
            ;;
        --all)              want_bash=1; want_zsh=1; want_fish=1; want_atuin=1 ;;
        -h | --help)        usage; exit 0 ;;
        *) echo "import.sh: unknown option: $a" >&2; usage >&2; exit 2 ;;
    esac
done
[ "$want_bash$want_zsh$want_fish$want_atuin" = "0000" ] && { usage; exit 0; }

[ "$want_bash" = 1 ] && import_bash
[ "$want_zsh" = 1 ] && import_zsh
[ "$want_fish" = 1 ] && import_fish
[ "$want_atuin" = 1 ] && import_atuin

[ -s "$ENTRIES" ] || { echo "nothing to import (no history found)"; exit 0; }
total=$(tr -cd '\036' < "$ENTRIES" | wc -c)
echo "parsed $total commands" >&2

# Existing (id, command) rows → the awk's id-ownership map (see AWKPROG):
# a re-import that gained a new same-second entry must not land on an id
# the DB already holds for a different command. The command is SQL-escaped
# and newlines folded to SOH so multi-line commands stay on one map line
# (the awk mirrors both transforms). cwd is excluded: the atuin
# enrichment in the awk rewrites cwd, so it can't be part of the
# id-ownership match. sqlite3 -separator with the 0x1F field separator
# (a plain control char, no quoting worries).
sep=$(printf '\037')
kav_db -noheader -separator "$sep" "$DB" "SELECT id, replace(replace(command, char(39), char(39)||char(39)), char(10), char(1)) FROM history;" > "$DBMAP" 2> /dev/null || true

# Bulk insert in one sqlite3 session, via one awk pass over ENTRIES.
# atuin rows (src=A) first enrich any existing cwd-less row. Rows dedup
# on (command, cwd, id) — id IS the ns timestamp, so re-runs insert
# nothing while the same command at different times keeps every
# occurrence. ORDER BY id DESC == time order (INTEGER PRIMARY KEY = the
# table's rowid).
AWKPROG=$(mktemp "$tmpdir/kavkash-awk.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT" "$AWKPROG" "$ATUINPARSE" "$DBMAP" "$DAYS" "$OFFS"; [ -n "${KAV_TMP_IDX:-}" ] && kav_db "$DB" "DROP INDEX IF EXISTS idx_import_cmd;"' EXIT
cat > "$AWKPROG" <<'EOF'
BEGIN {
    RS = "\n"     # map lines: "id\x1fcommand" — command is SQL-escaped
                  # and newlines folded to SOH (see the dump), so a
                  # multi-line command stays on one line
    if (DBMAP != "") {
        while ((getline l < DBMAP) > 0) {
            split(l, m, "\037")
            dbkey[m[1]] = m[2]
        }
        close(DBMAP)
    }
    RS = "\036"   # 0x1E record separator (matches emit)
    FS = "\037"   # 0x1F field separator
}

# SQL-escape a command/cwd field (doubled quotes) — same rule as
# kav_sql_quote() in includes.sh; this awk runs in its own process and
# can't call the shell helper, so keep the two in sync.
function esc(s) { gsub(/'/, "''", s); return s }

# +1 on a decimal string (19-digit ns exceeds awk's double precision, so
# the bump is done as text; digits-only input, carry handled).
function inc(s,   i, d, c, out) {
    c = 1
    out = ""
    for (i = length(s); i >= 1; i--) {
        d = substr(s, i, 1) + c
        if (d > 9) { d = 0; c = 1 } else c = 0
        out = d out
    }
    if (c) out = "1" out
    return out
}

{
    cmd = esc($2)
    if (cmd == "") next
    cwd = esc($3)
    ts = $1
    dur = $4 + 0
    exitc = $5 + 0
    # The id is the row's timestamp; same-second entries (all sources are
    # second-granular) would collide on the integer PK. Walk up from the
    # timestamp to an id that is free — "occupied" means the DB already
    # holds a DIFFERENT command there, or this stream already used it
    # (keeps same-second duplicates distinct). An id the DB holds for the
    # SAME command is kept: the NOT EXISTS below skips it — so a re-import
    # that gained a new same-second entry shifts the group without
    # disturbing the old placements. Ownership is by command alone: the
    # atuin enrichment below rewrites cwd, and newlines are folded to SOH
    # exactly as the map dump did.
    key = cmd
    gsub(/\n/, "\001", key)
    id = ts
    while ((id in dbkey && dbkey[id] != key) || (id in used)) id = inc(id)
    used[id] = key
    ts = id
    if ($6 == "A")
        printf "UPDATE history SET cwd='%s', duration_ms=%s, exit_code=%s WHERE command='%s' AND cwd='';\n", cwd, dur, exitc, cmd
    # Idempotent: skip when the id already exists — id IS the timestamp,
    # so this is the (command, cwd, ts) dedup. Checking the id alone also
    # keeps the re-import stable when the atuin enrichment above changed a
    # row's cwd — an (id, command, cwd) key would stop matching and
    # re-insert the row. INSERT OR IGNORE: belt for a pathological map
    # collision (e.g. a command containing the field separator) — silently
    # skips instead of failing the import.
    printf "INSERT OR IGNORE INTO history (id, command, cwd, exit_code, duration_ms) SELECT %s, '%s', '%s', %s, %s WHERE NOT EXISTS (SELECT 1 FROM history WHERE id=%s);\n", ts, cmd, cwd, dur, exitc, ts
}
EOF

# atuin parse: the CLI's records -> ENTRIES frames (0x1E record / 0x1F
# field). A record starts with the wall-clock timestamp line; other
# lines continue the previous record (multiline commands). The command
# field is everything after the 4th '|' — commands may contain '|'.
if kav_have pv; then
    pv -N "sql" "$ENTRIES" | awk -v DBMAP="$DBMAP" -f "$AWKPROG" > "$SQLOUT"
else
    awk -v DBMAP="$DBMAP" -f "$AWKPROG" "$ENTRIES" > "$SQLOUT"
fi

echo "inserting $total commands" >&2
# Index hygiene: drop the unused idx_import_dedup (every INSERT would
# maintain it). The atuin enrichment UPDATE probes WHERE
# command='...' — a plain command index turns that from a full scan per
# row into a lookup; dropped after the load so the live daemon pays no
# maintenance, built only when atuin rows are present.
kav_db "$DB" "DROP INDEX IF EXISTS idx_import_dedup;"
if grep -q '^UPDATE history SET' "$SQLOUT"; then
    kav_db "$DB" "CREATE INDEX IF NOT EXISTS idx_import_cmd ON history(command);"
    KAV_TMP_IDX=1
fi
n_before=$(kav_db "$DB" "SELECT count(*) FROM history;")
{
    echo "BEGIN;"
    if kav_have pv; then
        pv -N "insert" "$SQLOUT"
    else
        cat "$SQLOUT"
    fi
    echo "COMMIT;"
} | kav_db "$DB"
if [ -n "${KAV_TMP_IDX:-}" ]; then kav_db "$DB" "DROP INDEX IF EXISTS idx_import_cmd;"; fi
n_after=$(kav_db "$DB" "SELECT count(*) FROM history;")
new=$((n_after - n_before))
printf 'imported %d commands into %s\n' "$new" "$DB"
