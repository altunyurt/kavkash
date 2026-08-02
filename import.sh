#!/bin/sh
# import.sh — import existing history (bash/zsh/fish + atuin) into kavkash DB.
#
# Runs standalone any time (install.sh invokes it when the user opts in) and
# is idempotent: commands already in the DB are skipped (match on text).
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
kav_have base64 || kav_die "base64 required for history import"

# Ensure schema exists (same as server.sh) so import works before first run.
sqlite3 "$DB" << 'EOF'
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    command TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    timestamp INTEGER NOT NULL
);
EOF

tmpdir=${TMPDIR:-/tmp}
ENTRIES=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
SQLOUT=$(mktemp "$tmpdir/kavkash-import.XXXXXX")
trap 'rm -f "$ENTRIES" "$SQLOUT"' EXIT

now=$(date +%s%3N 2> /dev/null || echo "$(date +%s)000")
counter=0

# emit <epoch_ms> <base64(cmd)> [base64(cwd) [dur_ms exit src]]
# src=A marks atuin-sourced rows: their cwd/duration enrich existing rows
# (see INSERT loop). Commands without a real timestamp get sequential values
# just below `now`, so un-timestamped files keep their original order
# (newest last = first Up).
emit() {
    counter=$((counter + 1))
    ts=$1
    b64=$2
    cwd=${3:-}
    dur=${4:-}
    exit=${5:-}
    src=${6:-}
    [ -n "$b64" ] || return 0
    case "$ts" in '' | *[!0-9]*) ts=$((now - counter)) ;; esac
    printf '%s %s %s %s %s %s\n' "$ts" "$b64" "$cwd" "$dur" "$exit" "$src" >> "$ENTRIES"
}

b64() { printf '%s' "$1" | base64 -w0; }

import_bash() {
    f="${HISTFILE:-$HOME/.bash_history}"
    [ -f "$f" ] || return 0
    prev_ts=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*)
                prev_ts=${line#\#}
                case "$prev_ts" in *[!0-9]*) prev_ts="" ;; esac
                ;;
            *)
                [ -z "$line" ] && { prev_ts=""; continue; }
                emit "$prev_ts" "$(b64 "$line")"
                prev_ts=""
                ;;
        esac
    done < "$f"
}

import_zsh() {
    f="${HISTFILE:-$HOME/.zsh_history}"
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
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
        emit "$ts" "$(b64 "$cmd")"
    done < "$f"
}

import_fish() {
    f="${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history"
    [ -f "$f" ] || return 0
    ts=""
    cmd=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "- cmd: "*)
                [ -n "$cmd" ] && emit "$ts" "$(b64 "$cmd")"
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
    [ -n "$cmd" ] && emit "$ts" "$(b64 "$cmd")"
}

import_atuin() {
    # atuin's own CLI is the most robust reader: it honours a custom db_path in
    # config.toml, any schema version, and decrypts PASETO-encrypted stores
    # (v18+). Fall back to direct plaintext SQLite reads only when the CLI is
    # unavailable. Template fields: time|directory|duration|exit|command.
    # Command is LAST so embedded tabs/newlines can't shift earlier fields;
    # --print0 keeps multiline commands intact (tr maps NUL back to newline
    # for the shell reader; continuation lines are re-attached below).
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
                                    emit "$p_ts" "$(b64 "$pending")" "$(b64 "$p_dir")" "$p_dur" "$p_exit" A
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
                    [ -n "$pending" ] && emit "$p_ts" "$(b64 "$pending")" "$(b64 "$p_dir")" "$p_dur" "$p_exit" A
                }
            rm -f "$ATUINOUT"
            return 0
        fi
        rm -f "$ATUINOUT"
    fi
    # No CLI (or it had nothing): read plaintext SQLite directly. Resolve the
    # DB location the same way atuin does: config.toml db_path, else the
    # default under $XDG_DATA_HOME/atuin. Keep the IFS='|' read with the
    # command as the LAST variable: commands may contain '|', and read assigns
    # the remainder to the final variable, so adding fields after it would break.
    data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/atuin"
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/atuin/config.toml"
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
    # pipe-containing commands survive the IFS='|' read.
    sqlite3 -noheader "$f" "SELECT CAST(timestamp/$div AS INTEGER), COALESCE(cwd,''), exit, CAST(COALESCE(duration,0)/$div AS INTEGER), command FROM $table ORDER BY timestamp ASC;" \
        | while IFS='|' read -r ts cwd exit dur cmd || [ -n "$cmd" ]; do
            [ -z "$cmd" ] && continue
            emit "$ts" "$(b64 "$cmd")" "$(b64 "$cwd")" "$dur" "$exit" A
        done
}

import_bash
import_zsh
import_fish
import_atuin

[ -s "$ENTRIES" ] || { echo "nothing to import (no history found)"; exit 0; }

# Bulk insert in a single sqlite3 session; NOT EXISTS skips duplicates.
# atuin rows (src=A) first enrich any existing cwd-less row (a bash/zsh/fish
# import may already hold the same command without a path), then insert if
# the command is still unknown.
while IFS=' ' read -r ts b64cmd b64cwd dur exit src || [ -n "$b64cmd" ]; do
    cmd=$(printf '%s' "$b64cmd" | base64 -d 2> /dev/null || true)
    [ -z "$cmd" ] && continue
    safe=$(printf '%s' "$cmd" | sed "s/'/''/g")
    if [ -n "$b64cwd" ]; then
        cwd=$(printf '%s' "$b64cwd" | base64 -d 2> /dev/null || true)
    else
        cwd=""
    fi
    safe_cwd=$(printf '%s' "$cwd" | sed "s/'/''/g")
    [ -n "$dur" ] || dur=0
    [ -n "$exit" ] || exit=0
    if [ "$src" = A ]; then
        printf "UPDATE history SET cwd='%s', duration_ms=%s, exit_code=%s, timestamp=%s WHERE command='%s' AND cwd='';\n" "$safe_cwd" "$dur" "$exit" "$ts" "$safe" >> "$SQLOUT"
    fi
    printf "INSERT INTO history (command, cwd, exit_code, duration_ms, timestamp) SELECT '%s', '%s', %s, %s, %s WHERE NOT EXISTS (SELECT 1 FROM history WHERE command = '%s');\n" "$safe" "$safe_cwd" "$exit" "$dur" "$ts" "$safe" >> "$SQLOUT"
done < "$ENTRIES"

n_before=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
sqlite3 "$DB" < "$SQLOUT"
n_after=$(sqlite3 "$DB" "SELECT count(*) FROM history;")
new=$((n_after - n_before))
printf 'imported %d new commands (duplicates skipped) into %s\n' "$new" "$DB"
